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

public final class ServerProcessController: ObservableObject {
    @Published public private(set) var state: ServerState
    @Published public private(set) var lastError: String?
    private let processLauncher: ProcessLaunching
    private var process: ManagedProcess?

    public init(processLauncher: ProcessLaunching = FoundationProcessLauncher()) {
        self.processLauncher = processLauncher
        self.state = .stopped
    }

    public func start(settings: DashboardSettings, pythonExecutable: URL) throws {
        guard process?.isRunning != true else {
            return
        }
        state = .starting
        lastError = nil

        let nextProcess = processLauncher.makeProcess()
        nextProcess.executableURL = pythonExecutable
        nextProcess.arguments = makeArguments(settings: settings)
        nextProcess.environment = ProcessInfo.processInfo.environment

        do {
            try nextProcess.launch()
            process = nextProcess
            state = .running
        } catch {
            state = .failed
            lastError = String(describing: error)
            throw error
        }
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
        var arguments = [
            "-m", "mlx_lm.server",
            "--host", DashboardSettings.localMLXHost,
            "--port", String(settings.mlxPort)
        ]
        if let activeModel = settings.activeModel, !activeModel.isEmpty {
            arguments += ["--model", activeModel]
        }
        arguments += sanitizedServerFlags(settings.serverFlags)
        return arguments
    }

    private func sanitizedServerFlags(_ flags: [String]) -> [String] {
        var sanitized: [String] = []
        var skipNext = false
        for flag in flags {
            if skipNext {
                skipNext = false
                continue
            }
            if flag == "--host" {
                skipNext = true
                continue
            }
            if flag.hasPrefix("--host=") {
                continue
            }
            sanitized.append(flag)
        }
        return sanitized
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
}
