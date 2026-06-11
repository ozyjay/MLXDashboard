import Foundation

public struct PythonPackage: Sendable, Equatable {
    public var importName: String
    public var installName: String

    public init(importName: String, installName: String) {
        self.importName = importName
        self.installName = installName
    }
}

public struct PythonPackageReport: Sendable, Equatable {
    public var missingInstallNames: [String]

    public var isReady: Bool {
        missingInstallNames.isEmpty
    }

    public init(missingInstallNames: [String]) {
        self.missingInstallNames = missingInstallNames
    }
}

public struct PythonPackageChecker: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ShellCommandRunner()) {
        self.runner = runner
    }

    public func checkPackages(pythonExecutable: URL, packages: [PythonPackage]) async throws -> PythonPackageReport {
        var missing: [String] = []
        for package in packages {
            let result = try await runner.run(
                Command(executableURL: pythonExecutable, arguments: ["-c", "import \(package.importName)"])
            )
            if result.exitCode != 0 {
                missing.append(package.installName)
            }
        }
        return PythonPackageReport(missingInstallNames: missing)
    }
}
