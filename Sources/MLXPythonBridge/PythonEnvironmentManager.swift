import Foundation
import MLXCore

public struct PythonEnvironmentStatus: Sendable, Equatable {
    public var pythonExecutable: URL
    public var packageReport: PythonPackageReport

    public var isReady: Bool {
        packageReport.isReady
    }
}

public struct PythonEnvironmentManager: Sendable {
    public let paths: AppPaths
    private let runner: any CommandRunning
    private let checker: PythonPackageChecker

    public init(paths: AppPaths = .default, runner: any CommandRunning = ShellCommandRunner()) {
        self.paths = paths
        self.runner = runner
        self.checker = PythonPackageChecker(runner: runner)
    }

    public var venvPython: URL {
        paths.venvDirectory.appending(path: "bin/python")
    }

    public func discoverPyenvPython() async throws -> URL {
        let result = try await runner.run(
            Command(
                executableURL: URL(filePath: "/bin/bash"),
                arguments: ["-lc", "command -v python3"]
            )
        )
        guard result.exitCode == 0 else {
            throw PythonEnvironmentError.pythonNotFound(result.standardError)
        }
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw PythonEnvironmentError.pythonNotFound("python3 was not found in the active shell")
        }
        return URL(filePath: path)
    }

    public func ensureVenv() async throws -> URL {
        if FileManager.default.fileExists(atPath: venvPython.path) {
            return venvPython
        }
        let python = try await discoverPyenvPython()
        try FileManager.default.createDirectory(at: paths.applicationSupport, withIntermediateDirectories: true)
        let result = try await runner.run(
            Command(executableURL: python, arguments: ["-m", "venv", paths.venvDirectory.path])
        )
        guard result.exitCode == 0 else {
            throw PythonEnvironmentError.venvCreationFailed(result.standardError)
        }
        return venvPython
    }

    public func installRequiredPackages() async throws {
        let python = try await ensureVenv()
        let result = try await runner.run(
            Command(
                executableURL: python,
                arguments: ["-m", "pip", "install", "--upgrade", "mlx-lm", "huggingface_hub"]
            )
        )
        guard result.exitCode == 0 else {
            throw PythonEnvironmentError.packageInstallFailed(result.standardError)
        }
    }

    public func status() async throws -> PythonEnvironmentStatus {
        let python = try await ensureVenv()
        let report = try await checker.checkPackages(
            pythonExecutable: python,
            packages: [
                PythonPackage(importName: "mlx_lm", installName: "mlx-lm"),
                PythonPackage(importName: "huggingface_hub", installName: "huggingface_hub")
            ]
        )
        return PythonEnvironmentStatus(pythonExecutable: python, packageReport: report)
    }
}

public enum PythonEnvironmentError: Error, Equatable, CustomStringConvertible {
    case pythonNotFound(String)
    case venvCreationFailed(String)
    case packageInstallFailed(String)

    public var description: String {
        switch self {
        case .pythonNotFound(let message):
            return "Python not found: \(message)"
        case .venvCreationFailed(let message):
            return "Virtual environment creation failed: \(message)"
        case .packageInstallFailed(let message):
            return "Package installation failed: \(message)"
        }
    }
}
