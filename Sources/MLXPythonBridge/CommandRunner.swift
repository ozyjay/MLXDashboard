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

public protocol CommandRunning: Sendable {
    func run(_ command: Command) async throws -> CommandResult
}

public struct ShellCommandRunner: CommandRunning {
    public init() {}

    public func run(_ command: Command) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
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

            try process.run()
            process.waitUntilExit()

            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return CommandResult(exitCode: process.terminationStatus, standardOutput: output, standardError: error)
        }.value
    }
}
