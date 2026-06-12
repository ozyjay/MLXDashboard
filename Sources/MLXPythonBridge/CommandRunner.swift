import Darwin
import Foundation

public struct Command: Sendable, Equatable {
    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL?

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public typealias CommandOutputHandler = @Sendable (String) -> Void

public protocol CommandRunning: Sendable {
    func run(_ command: Command) async throws -> CommandResult
    func run(_ command: Command, outputHandler: CommandOutputHandler?) async throws -> CommandResult
}

public extension CommandRunning {
    func run(_ command: Command, outputHandler: CommandOutputHandler?) async throws -> CommandResult {
        let result = try await run(command)
        if let outputHandler {
            if !result.standardOutput.isEmpty {
                outputHandler(result.standardOutput)
            }
            if !result.standardError.isEmpty {
                outputHandler(result.standardError)
            }
        }
        return result
    }
}

public struct ShellCommandRunner: CommandRunning {
    public init() {}

    public func run(_ command: Command) async throws -> CommandResult {
        try await run(command, outputHandler: nil)
    }

    public func run(_ command: Command, outputHandler: CommandOutputHandler?) async throws -> CommandResult {
        let processBox = RunningProcessBox()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .utility) {
                let process = Process()
                processBox.set(process)
                defer { processBox.clear(process) }

                process.executableURL = command.executableURL
                process.arguments = command.arguments
                if !command.environment.isEmpty {
                    process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
                }
                if let workingDirectory = command.workingDirectory {
                    process.currentDirectoryURL = workingDirectory
                }

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                let outputBuffer = CommandOutputBuffer()
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    outputBuffer.appendStandardOutput(data)
                    if let chunk = String(data: data, encoding: .utf8) {
                        outputHandler?(chunk)
                    }
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    outputBuffer.appendStandardError(data)
                    if let chunk = String(data: data, encoding: .utf8) {
                        outputHandler?(chunk)
                    }
                }

                try process.run()
                process.waitUntilExit()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil

                let output = outputBuffer.standardOutputString
                let error = outputBuffer.standardErrorString
                return CommandResult(exitCode: process.terminationStatus, standardOutput: output, standardError: error)
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            processBox.terminate()
        }
    }
}

private final class CommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardError = Data()

    var standardOutputString: String {
        lock.withLock {
            String(data: standardOutput, encoding: .utf8) ?? ""
        }
    }

    var standardErrorString: String {
        lock.withLock {
            String(data: standardError, encoding: .utf8) ?? ""
        }
    }

    func appendStandardOutput(_ data: Data) {
        lock.withLock {
            standardOutput.append(data)
        }
    }

    func appendStandardError(_ data: Data) {
        lock.withLock {
            standardError.append(data)
        }
    }
}

private final class RunningProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.withLock {
            self.process = process
        }
    }

    func clear(_ process: Process) {
        lock.withLock {
            if self.process === process {
                self.process = nil
            }
        }
    }

    func terminate() {
        let target = lock.withLock {
            process
        }
        guard let target else { return }
        if target.isRunning {
            target.terminate()
        }
        let processIdentifier = target.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            let shouldForceKill = self?.lock.withLock {
                self?.process === target && target.isRunning
            } ?? false
            if shouldForceKill {
                kill(processIdentifier, SIGKILL)
            }
        }
    }
}
