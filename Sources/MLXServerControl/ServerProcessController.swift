import Foundation
import Combine
import MLXCore

public enum ServerState: String, Equatable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case failed
}

public final class ServerProcessController: ObservableObject, @unchecked Sendable {
    @Published public private(set) var state: ServerState
    @Published public private(set) var lastError: String?
    private let processLauncher: ProcessLaunching
    private let portChecker: ServerPortChecking
    private let healthChecker: ServerHealthChecking
    private var process: ManagedProcess?

    public init(
        processLauncher: ProcessLaunching = FoundationProcessLauncher(),
        portChecker: ServerPortChecking = TCPServerPortChecker(),
        healthChecker: ServerHealthChecking = MLXHealthClient()
    ) {
        self.processLauncher = processLauncher
        self.portChecker = portChecker
        self.healthChecker = healthChecker
        self.state = .stopped
    }

    public func start(settings: DashboardSettings, pythonExecutable: URL) throws {
        try start(
            modelID: settings.activeModel,
            port: settings.mlxPort,
            serverFlags: settings.serverFlags,
            runtime: settings.activeModel.map {
                settings.runtimeConfiguration(modelID: $0).runtime
            },
            pythonExecutable: pythonExecutable
        )
    }

    public func start(
        modelID: String?,
        port: Int,
        serverFlags: [String],
        runtime: ModelRuntimeKind? = nil,
        pythonExecutable: URL
    ) throws {
        guard process?.isRunning != true else { return }
        state = .starting
        lastError = nil

        guard portChecker.isPortAvailable(host: DashboardSettings.localMLXHost, port: port) else {
            let error = ServerProcessControllerError.portUnavailable(
                host: DashboardSettings.localMLXHost,
                port: port
            )
            state = .failed
            lastError = error.localizedDescription
            throw error
        }

        let nextProcess = processLauncher.makeProcess()
        nextProcess.executableURL = pythonExecutable
        nextProcess.arguments = makeArguments(
            modelID: modelID,
            port: port,
            serverFlags: serverFlags,
            runtime: runtime
        )
        nextProcess.environment = ProcessInfo.processInfo.environment
        nextProcess.terminationHandler = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                if self.state != .stopping && self.state != .stopped {
                    self.state = status == 0 ? .stopped : .failed
                    if status != 0 {
                        self.lastError = "Managed model runtime exited with status \(status)."
                    }
                }
            }
        }

        do {
            try nextProcess.launch()
            process = nextProcess
        } catch {
            state = .failed
            lastError = String(describing: error)
            throw error
        }
    }

    @discardableResult
    public func waitUntilReady(
        baseURL: URL,
        timeout: TimeInterval = 180,
        pollInterval: TimeInterval = 0.5
    ) async -> Bool {
        let ready = await healthChecker.waitUntilHealthy(
            baseURL: baseURL,
            timeout: timeout,
            pollInterval: pollInterval
        )
        await MainActor.run {
            if ready {
                state = .running
                lastError = nil
            } else if process?.isRunning == true {
                state = .failed
                lastError = "Managed model runtime did not become healthy within \(Int(timeout)) seconds."
            }
        }
        return ready
    }

    public func stop() {
        guard let process else {
            state = .stopped
            return
        }
        state = .stopping
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        state = .stopped
    }

    public func restart(settings: DashboardSettings, pythonExecutable: URL) throws {
        stop()
        try start(settings: settings, pythonExecutable: pythonExecutable)
    }

    public func makeArguments(settings: DashboardSettings) -> [String] {
        makeArguments(
            modelID: settings.activeModel,
            port: settings.mlxPort,
            serverFlags: settings.serverFlags,
            runtime: settings.activeModel.map {
                settings.runtimeConfiguration(modelID: $0).runtime
            }
        )
    }

    public func makeArguments(
        modelID: String?,
        port: Int,
        serverFlags: [String],
        runtime: ModelRuntimeKind? = nil
    ) -> [String] {
        let resolvedRuntime = runtime
            ?? modelID.map { ModelRuntimeResolver.inferred(modelID: $0).runtime }
            ?? .mlxLM
        var arguments: [String]
        switch resolvedRuntime {
        case .mlxLM:
            arguments = ["-m", "mlx_lm", "server"]
        case .textDiffusion:
            arguments = ["-m", "mlxdashboard_text_diffusion.server"]
        }
        arguments += [
            "--host", DashboardSettings.localMLXHost,
            "--port", String(port)
        ]
        if let modelID, !modelID.isEmpty {
            arguments += ["--model", modelID]
        }
        arguments += sanitizedServerFlags(serverFlags)
        return arguments
    }

    private func sanitizedServerFlags(_ flags: [String]) -> [String] {
        let reservedWithValue: Set<String> = [
            "--host",
            "--port",
            "--model",
            "--model-path",
            "--runtime"
        ]
        var sanitized: [String] = []
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            if reservedWithValue.contains(flag) {
                index += min(2, flags.count - index)
                continue
            }
            if reservedWithValue.contains(where: { flag.hasPrefix("\($0)=") }) {
                index += 1
                continue
            }
            sanitized.append(flag)
            index += 1
        }
        return sanitized
    }
}

public enum ServerProcessControllerError: LocalizedError, Equatable {
    case portUnavailable(host: String, port: Int)

    public var errorDescription: String? {
        switch self {
        case let .portUnavailable(host, port):
            return "Cannot start the model runtime because \(host):\(port) is already in use."
        }
    }
}

public struct MLXHealthStatus: Equatable, Sendable {
    public var isHealthy: Bool
    public var statusCode: Int?

    public init(isHealthy: Bool, statusCode: Int?) {
        self.isHealthy = isHealthy
        self.statusCode = statusCode
    }
}

public struct MLXHealthClient: Sendable {
    public init() {}

    public func health(baseURL: URL) async -> MLXHealthStatus {
        let url = baseURL.appending(path: "health")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            return MLXHealthStatus(isHealthy: status == 200, statusCode: status)
        } catch {
            return MLXHealthStatus(isHealthy: false, statusCode: nil)
        }
    }

    public func waitUntilHealthy(
        baseURL: URL,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if await health(baseURL: baseURL).isHealthy {
                return true
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0.05, pollInterval) * 1_000_000_000))
            } catch {
                return false
            }
        } while Date() < deadline && !Task.isCancelled
        return false
    }
}

public protocol ServerHealthChecking: Sendable {
    func waitUntilHealthy(
        baseURL: URL,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async -> Bool
}

extension MLXHealthClient: ServerHealthChecking {}
