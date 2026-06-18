import Foundation
import MLXCore

public struct PythonEnvironmentStatus: Sendable, Equatable {
    public var pythonExecutable: URL
    public var packageReport: PythonPackageReport

    public var isReady: Bool {
        packageReport.isReady
    }
}

public enum PythonPackageVersionState: String, Codable, Equatable, Sendable {
    case missing
    case current
    case upgradeAvailable
    case unknown
}

public struct PythonPackageVersionStatus: Codable, Equatable, Identifiable, Sendable {
    public var id: String { packageName }
    public var packageName: String
    public var installedVersion: String?
    public var latestVersion: String?
    public var state: PythonPackageVersionState
    public var message: String?

    public init(
        packageName: String,
        installedVersion: String? = nil,
        latestVersion: String? = nil,
        state: PythonPackageVersionState,
        message: String? = nil
    ) {
        self.packageName = packageName
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.state = state
        self.message = message
    }
}

public struct PythonPackageUpgradeReport: Codable, Equatable, Sendable {
    public var statuses: [PythonPackageVersionStatus]

    public var hasAvailableUpgrades: Bool {
        statuses.contains { $0.state == .upgradeAvailable }
    }

    public init(statuses: [PythonPackageVersionStatus] = []) {
        self.statuses = statuses
    }

    public func status(for packageName: String) -> PythonPackageVersionStatus? {
        statuses.first { $0.packageName == packageName }
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

    public var bundledTextDiffusionRuntimeURL: URL? {
        Bundle.module.url(forResource: "TextDiffusionRuntime", withExtension: nil)
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
        let baseResult = try await runner.run(
            Command(
                executableURL: python,
                arguments: ["-m", "pip", "install", "--upgrade", "mlx", "mlx-lm", "huggingface_hub"]
            )
        )
        guard baseResult.exitCode == 0 else {
            throw PythonEnvironmentError.packageInstallFailed(baseResult.standardError)
        }
        try await installBundledTextDiffusionRuntime(pythonExecutable: python)
    }

    public func installBundledTextDiffusionRuntime(pythonExecutable: URL) async throws {
        guard let packageURL = bundledTextDiffusionRuntimeURL else {
            throw PythonEnvironmentError.runtimePackageResourceMissing
        }
        let result = try await runner.run(
            Command(
                executableURL: pythonExecutable,
                arguments: ["-m", "pip", "install", "--upgrade", packageURL.path]
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
                PythonPackage(importName: "mlx", installName: "mlx"),
                PythonPackage(importName: "mlx_lm", installName: "mlx-lm"),
                PythonPackage(importName: "huggingface_hub", installName: "huggingface_hub"),
                PythonPackage(
                    importName: "mlxdashboard_text_diffusion",
                    installName: "mlxdashboard-text-diffusion"
                )
            ]
        )
        return PythonEnvironmentStatus(pythonExecutable: python, packageReport: report)
    }

    public func runtimePackageUpgradeReport() async throws -> PythonPackageUpgradeReport {
        let python = try await ensureVenv()
        return try await runtimePackageUpgradeReport(pythonExecutable: python)
    }

    public func runtimePackageUpgradeReport(pythonExecutable: URL) async throws -> PythonPackageUpgradeReport {
        let packageNames = ["mlx", "mlx-lm"]
        let installedVersions = try await runtimePackageVersions(
            pythonExecutable: pythonExecutable,
            packageNames: packageNames
        )
        let outdatedResult = try await runner.run(Command(
            executableURL: pythonExecutable,
            arguments: ["-m", "pip", "list", "--outdated", "--format=json"]
        ))

        guard outdatedResult.exitCode == 0 else {
            let message = "Unable to check latest version: \(cleaned(outdatedResult.standardError))"
            return PythonPackageUpgradeReport(statuses: packageNames.map { packageName in
                statusWhenLatestUnknown(
                    packageName: packageName,
                    installedVersion: installedVersions[packageName] ?? nil,
                    message: message
                )
            })
        }

        guard let outdatedPackages = parseOutdatedPackages(from: outdatedResult.standardOutput) else {
            return PythonPackageUpgradeReport(statuses: packageNames.map { packageName in
                statusWhenLatestUnknown(
                    packageName: packageName,
                    installedVersion: installedVersions[packageName] ?? nil,
                    message: "Unable to parse latest version information."
                )
            })
        }

        return PythonPackageUpgradeReport(statuses: packageNames.map { packageName in
            let installedVersion = installedVersions[packageName] ?? nil
            guard let installedVersion else {
                return PythonPackageVersionStatus(packageName: packageName, state: .missing)
            }
            if let latestVersion = outdatedPackages[packageName], latestVersion != installedVersion {
                return PythonPackageVersionStatus(
                    packageName: packageName,
                    installedVersion: installedVersion,
                    latestVersion: latestVersion,
                    state: .upgradeAvailable
                )
            }
            return PythonPackageVersionStatus(
                packageName: packageName,
                installedVersion: installedVersion,
                latestVersion: installedVersion,
                state: .current
            )
        })
    }

    public func upgradeRuntimePackages(pythonExecutable: URL) async throws {
        let result = try await runner.run(Command(
            executableURL: pythonExecutable,
            arguments: ["-m", "pip", "install", "--upgrade", "mlx", "mlx-lm"]
        ))
        guard result.exitCode == 0 else {
            throw PythonEnvironmentError.packageInstallFailed(result.standardError)
        }
        try await installBundledTextDiffusionRuntime(pythonExecutable: pythonExecutable)
    }

    public func mlxLMRuntimeCapabilities(pythonExecutable: URL) async throws -> MLXModelRuntimeCapabilities {
        let script = """
import importlib.metadata as metadata
import json

try:
    dist = metadata.distribution("mlx-lm")
    print(json.dumps({
        "site_packages": str(dist.locate_file("")),
        "version": metadata.version("mlx-lm"),
    }))
except Exception as exc:
    raise SystemExit(str(exc))
"""
        let result = try await runner.run(
            Command(executableURL: pythonExecutable, arguments: ["-c", script])
        )
        guard result.exitCode == 0 else {
            throw PythonEnvironmentError.runtimeCapabilityInspectionFailed(
                runtimeCapabilityFailureMessage(from: result)
            )
        }
        guard let data = result.standardOutput.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sitePackagesPath = object["site_packages"] as? String,
              !sitePackagesPath.isEmpty
        else {
            throw PythonEnvironmentError.runtimeCapabilityInspectionFailed(
                cleaned(result.standardOutput)
            )
        }
        return MLXModelRuntimeCapabilities.inspectingInstalledPackage(
            sitePackagesURL: URL(filePath: sitePackagesPath),
            mlxLMVersion: object["version"] as? String
        )
    }

    private func runtimePackageVersions(
        pythonExecutable: URL,
        packageNames: [String]
    ) async throws -> [String: String?] {
        let script = """
import importlib.metadata as metadata
import json
import sys

packages = sys.argv[1:]
versions = {}
for package in packages:
    try:
        versions[package] = metadata.version(package)
    except Exception:
        versions[package] = None
print(json.dumps(versions))
"""
        let result = try await runner.run(Command(
            executableURL: pythonExecutable,
            arguments: ["-c", script] + packageNames
        ))
        guard result.exitCode == 0 else {
            return Dictionary(uniqueKeysWithValues: packageNames.map { ($0, nil) })
        }
        guard let data = result.standardOutput.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Dictionary(uniqueKeysWithValues: packageNames.map { ($0, nil) })
        }
        return Dictionary(uniqueKeysWithValues: packageNames.map { packageName in
            (packageName, object[packageName] as? String)
        })
    }

    private func parseOutdatedPackages(from output: String) -> [String: String]? {
        guard let data = output.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return Dictionary(uniqueKeysWithValues: array.compactMap { package -> (String, String)? in
            guard let name = package["name"] as? String,
                  let latestVersion = package["latest_version"] as? String
            else { return nil }
            return (name, latestVersion)
        })
    }

    private func statusWhenLatestUnknown(
        packageName: String,
        installedVersion: String?,
        message: String
    ) -> PythonPackageVersionStatus {
        guard let installedVersion else {
            return PythonPackageVersionStatus(packageName: packageName, state: .missing)
        }
        return PythonPackageVersionStatus(
            packageName: packageName,
            installedVersion: installedVersion,
            state: .unknown,
            message: message
        )
    }

    private func cleaned(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown error" : trimmed
    }

    private func runtimeCapabilityFailureMessage(from result: CommandResult) -> String {
        let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            return stderr
        }
        let stdout = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            return stdout
        }
        return "python exited with code \(result.exitCode) without diagnostic output"
    }
}

public enum PythonEnvironmentError: Error, Equatable, CustomStringConvertible {
    case pythonNotFound(String)
    case venvCreationFailed(String)
    case packageInstallFailed(String)
    case runtimeCapabilityInspectionFailed(String)
    case runtimePackageResourceMissing

    public var description: String {
        switch self {
        case .pythonNotFound(let message):
            return "Python not found: \(message)"
        case .venvCreationFailed(let message):
            return "Virtual environment creation failed: \(message)"
        case .packageInstallFailed(let message):
            return "Package installation failed: \(message)"
        case .runtimeCapabilityInspectionFailed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Runtime capability inspection failed: \(trimmed.isEmpty ? "unknown error" : trimmed)"
        case .runtimePackageResourceMissing:
            return "Bundled text diffusion runtime package was not found in the application resources."
        }
    }
}
