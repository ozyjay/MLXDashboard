import XCTest
import MLXCore
@testable import MLXPythonBridge

final class PythonBridgeTests: XCTestCase {
    func testPackageCheckerReportsMissingPackages() async throws {
        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 1, standardOutput: "", standardError: "No module named mlx_lm"),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ])
        let checker = PythonPackageChecker(runner: runner)

        let report = try await checker.checkPackages(
            pythonExecutable: URL(filePath: "/tmp/python"),
            packages: [
                PythonPackage(importName: "mlx_lm", installName: "mlx-lm"),
                PythonPackage(importName: "huggingface_hub", installName: "huggingface_hub")
            ]
        )

        XCTAssertEqual(report.missingInstallNames, ["mlx-lm"])
        XCTAssertFalse(report.isReady)
    }

    func testCacheScannerFindsMLXCompatibleModelDirectories() throws {
        let root = try temporaryDirectory()
        let good = root.appending(path: "models--mlx-community--Tiny/snapshots/abc123", directoryHint: .isDirectory)
        let bad = root.appending(path: "models--mlx-community--Broken/snapshots/def456", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        for name in ["config.json", "model.safetensors.index.json", "tokenizer_config.json"] {
            FileManager.default.createFile(atPath: good.appending(path: name).path, contents: Data())
        }
        FileManager.default.createFile(atPath: bad.appending(path: "config.json").path, contents: Data())

        let scanner = MLXModelCacheScanner()
        let models = try scanner.scan(cacheRoot: root)

        XCTAssertEqual(models.map(\.id), ["mlx-community/Tiny"])
        XCTAssertEqual(models.first?.localPath, good.path)
    }

    func testRuntimeCompatibilityRejectsUnsupportedGemma4UnifiedModelType() throws {
        let root = try temporaryDirectory()
        let snapshot = root.appending(path: "models--mlx-community--Gemma4/snapshots/abc123", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try #"{"model_type":"gemma4_unified"}"#
            .write(to: snapshot.appending(path: "config.json"), atomically: true, encoding: .utf8)

        let compatibility = MLXModelRuntimeCompatibilityChecker().compatibility(localPath: snapshot.path)

        XCTAssertEqual(
            compatibility,
            .unsupported(modelType: "gemma4_unified", reason: "Unsupported by installed mlx-lm: gemma4_unified")
        )
    }

    func testRuntimeCompatibilityAllowsKnownModelTypes() throws {
        let root = try temporaryDirectory()
        let snapshot = root.appending(path: "models--mlx-community--Devstral/snapshots/abc123", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try #"{"model_type":"mistral"}"#
            .write(to: snapshot.appending(path: "config.json"), atomically: true, encoding: .utf8)

        let compatibility = MLXModelRuntimeCompatibilityChecker().compatibility(localPath: snapshot.path)

        XCTAssertEqual(compatibility, .runnable(modelType: "mistral"))
    }

    func testRuntimeCompatibilityRejectsUnsupportedModelTypeWithoutLocalSnapshot() throws {
        let compatibility = MLXModelRuntimeCompatibilityChecker().compatibility(modelType: "gemma4_unified")

        XCTAssertEqual(
            compatibility,
            .unsupported(modelType: "gemma4_unified", reason: "Unsupported by installed mlx-lm: gemma4_unified")
        )
    }

    func testRuntimeCompatibilityRejectsDiffusionGemmaModelTypeWithoutRuntimeCapability() throws {
        let compatibility = MLXModelRuntimeCompatibilityChecker().compatibility(modelType: "diffusion_gemma")

        XCTAssertEqual(
            compatibility,
            .unsupported(modelType: "diffusion_gemma", reason: "Unsupported by installed mlx-lm: diffusion_gemma")
        )
    }

    func testRuntimeCompatibilityAllowsDiffusionGemmaWhenRuntimeCapabilityIsKnown() throws {
        let checker = MLXModelRuntimeCompatibilityChecker(
            runtimeCapabilities: MLXModelRuntimeCapabilities(supportedModelTypes: ["diffusion_gemma"])
        )

        let compatibility = checker.compatibility(modelType: "diffusion_gemma")

        XCTAssertEqual(compatibility, .runnable(modelType: "diffusion_gemma"))
    }

    func testRuntimeCapabilitiesDetectInstalledModelModulesFromPackageRoot() throws {
        let root = try temporaryDirectory()
        let models = root.appending(path: "mlx_lm/models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: models.appending(path: "nemotron_labs_diffusion.py").path, contents: Data())

        let capabilities = MLXModelRuntimeCapabilities.inspectingInstalledPackage(
            sitePackagesURL: root,
            mlxLMVersion: "0.31.3"
        )

        XCTAssertEqual(capabilities.mlxLMVersion, "0.31.3")
        XCTAssertTrue(capabilities.supports(modelType: "nemotron_labs_diffusion"))
    }

    func testRuntimeCompatibilityRejectsNemotronDiffusionWhenRuntimeModuleIsMissing() throws {
        let compatibility = MLXModelRuntimeCompatibilityChecker(
            runtimeCapabilities: MLXModelRuntimeCapabilities(mlxLMVersion: "0.31.3")
        ).compatibility(modelType: "nemotron_labs_diffusion")

        XCTAssertEqual(
            compatibility,
            .unsupported(
                modelType: "nemotron_labs_diffusion",
                reason: "Installed mlx-lm 0.31.3 does not support model_type nemotron_labs_diffusion"
            )
        )
    }

    func testPythonEnvironmentManagerInspectsMLXLMRuntimeCapabilitiesWithoutImportingMLXLM() async throws {
        let root = try temporaryDirectory()
        let models = root.appending(path: "mlx_lm/models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: models.appending(path: "nemotron_labs_diffusion.py").path, contents: Data())
        let runner = FakeCommandRunner(results: [
            "runtime-capabilities": CommandResult(
                exitCode: 0,
                standardOutput: #"{"site_packages": "\#(root.path)", "version": "0.31.3"}"#,
                standardError: ""
            )
        ])
        let manager = PythonEnvironmentManager(runner: runner)

        let capabilities = try await manager.mlxLMRuntimeCapabilities(
            pythonExecutable: URL(filePath: "/tmp/python")
        )

        XCTAssertEqual(capabilities.mlxLMVersion, "0.31.3")
        XCTAssertTrue(capabilities.supports(modelType: "nemotron_labs_diffusion"))
    }

    func testRuntimePackageUpgradeReportShowsCurrentPackagesWhenNothingIsOutdated() async throws {
        let runner = FakeCommandRunner(results: [
            "runtime-package-versions": CommandResult(
                exitCode: 0,
                standardOutput: #"{"mlx":"0.29.0","mlx-lm":"0.31.3"}"#,
                standardError: ""
            ),
            "pip-outdated": CommandResult(exitCode: 0, standardOutput: #"[]"#, standardError: "")
        ])
        let manager = PythonEnvironmentManager(runner: runner)

        let report = try await manager.runtimePackageUpgradeReport(
            pythonExecutable: URL(filePath: "/tmp/python")
        )

        XCTAssertFalse(report.hasAvailableUpgrades)
        XCTAssertEqual(report.status(for: "mlx")?.state, .current)
        XCTAssertEqual(report.status(for: "mlx")?.installedVersion, "0.29.0")
        XCTAssertEqual(report.status(for: "mlx")?.latestVersion, "0.29.0")
        XCTAssertEqual(report.status(for: "mlx-lm")?.state, .current)
    }

    func testRuntimePackageUpgradeReportShowsAvailableUpgradesFromPipOutdatedJSON() async throws {
        let runner = FakeCommandRunner(results: [
            "runtime-package-versions": CommandResult(
                exitCode: 0,
                standardOutput: #"{"mlx":"0.29.0","mlx-lm":"0.31.3"}"#,
                standardError: ""
            ),
            "pip-outdated": CommandResult(
                exitCode: 0,
                standardOutput: #"[{"name":"mlx","version":"0.29.0","latest_version":"0.30.0"},{"name":"mlx-lm","version":"0.31.3","latest_version":"0.32.0"},{"name":"huggingface_hub","version":"0.1","latest_version":"0.2"}]"#,
                standardError: ""
            )
        ])
        let manager = PythonEnvironmentManager(runner: runner)

        let report = try await manager.runtimePackageUpgradeReport(
            pythonExecutable: URL(filePath: "/tmp/python")
        )

        XCTAssertTrue(report.hasAvailableUpgrades)
        XCTAssertEqual(report.status(for: "mlx")?.state, .upgradeAvailable)
        XCTAssertEqual(report.status(for: "mlx")?.latestVersion, "0.30.0")
        XCTAssertEqual(report.status(for: "mlx-lm")?.state, .upgradeAvailable)
        XCTAssertEqual(report.status(for: "mlx-lm")?.latestVersion, "0.32.0")
        XCTAssertNil(report.status(for: "huggingface_hub"))
    }

    func testRuntimePackageUpgradeReportMarksMissingPackageFromVersionMetadata() async throws {
        let runner = FakeCommandRunner(results: [
            "runtime-package-versions": CommandResult(
                exitCode: 0,
                standardOutput: #"{"mlx":"0.29.0","mlx-lm":null}"#,
                standardError: ""
            ),
            "pip-outdated": CommandResult(exitCode: 0, standardOutput: #"[]"#, standardError: "")
        ])
        let manager = PythonEnvironmentManager(runner: runner)

        let report = try await manager.runtimePackageUpgradeReport(
            pythonExecutable: URL(filePath: "/tmp/python")
        )

        XCTAssertEqual(report.status(for: "mlx")?.state, .current)
        XCTAssertEqual(report.status(for: "mlx-lm")?.state, .missing)
        XCTAssertNil(report.status(for: "mlx-lm")?.installedVersion)
        XCTAssertFalse(report.hasAvailableUpgrades)
    }

    func testRuntimePackageUpgradeReportKeepsInstalledVersionsWhenPipOutdatedFails() async throws {
        let runner = FakeCommandRunner(results: [
            "runtime-package-versions": CommandResult(
                exitCode: 0,
                standardOutput: #"{"mlx":"0.29.0","mlx-lm":"0.31.3"}"#,
                standardError: ""
            ),
            "pip-outdated": CommandResult(exitCode: 1, standardOutput: "", standardError: "network unavailable")
        ])
        let manager = PythonEnvironmentManager(runner: runner)

        let report = try await manager.runtimePackageUpgradeReport(
            pythonExecutable: URL(filePath: "/tmp/python")
        )

        XCTAssertFalse(report.hasAvailableUpgrades)
        XCTAssertEqual(report.status(for: "mlx")?.state, .unknown)
        XCTAssertEqual(report.status(for: "mlx")?.installedVersion, "0.29.0")
        XCTAssertEqual(report.status(for: "mlx")?.message, "Unable to check latest version: network unavailable")
        XCTAssertEqual(report.status(for: "mlx-lm")?.state, .unknown)
        XCTAssertEqual(report.status(for: "mlx-lm")?.installedVersion, "0.31.3")
    }

    func testRuntimePackageUpgradeReportKeepsInstalledVersionsWhenPipOutdatedJSONIsMalformed() async throws {
        let runner = FakeCommandRunner(results: [
            "runtime-package-versions": CommandResult(
                exitCode: 0,
                standardOutput: #"{"mlx":"0.29.0","mlx-lm":"0.31.3"}"#,
                standardError: ""
            ),
            "pip-outdated": CommandResult(exitCode: 0, standardOutput: #"not json"#, standardError: "")
        ])
        let manager = PythonEnvironmentManager(runner: runner)

        let report = try await manager.runtimePackageUpgradeReport(
            pythonExecutable: URL(filePath: "/tmp/python")
        )

        XCTAssertEqual(report.status(for: "mlx")?.state, .unknown)
        XCTAssertEqual(report.status(for: "mlx")?.installedVersion, "0.29.0")
        XCTAssertEqual(report.status(for: "mlx-lm")?.state, .unknown)
    }

    func testPythonEnvironmentManagerUpgradesRuntimePackagesWithPip() async throws {
        let runner = RecordingCommandRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: ""))
        let manager = PythonEnvironmentManager(runner: runner)

        try await manager.upgradeRuntimePackages(pythonExecutable: URL(filePath: "/tmp/python"))

        XCTAssertEqual(
            runner.commands.map(\.arguments),
            [["-m", "pip", "install", "--upgrade", "mlx", "mlx-lm"]]
        )
    }

    func testCacheManagerDeletesWholeRepoCacheFolderForModel() throws {
        let root = try temporaryDirectory()
        let snapshot = root.appending(path: "models--mlx-community--Tiny/snapshots/abc123", directoryHint: .isDirectory)
        let siblingSnapshot = root.appending(path: "models--mlx-community--Tiny/snapshots/def456", directoryHint: .isDirectory)
        let lockDirectory = root.appending(path: ".locks/models--mlx-community--Tiny", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingSnapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: snapshot.appending(path: "config.json").path, contents: Data())
        FileManager.default.createFile(atPath: siblingSnapshot.appending(path: "config.json").path, contents: Data())
        FileManager.default.createFile(atPath: lockDirectory.appending(path: "download.lock").path, contents: Data())

        let manager = MLXModelCacheManager()
        let deleted = try manager.deleteModelCache(
            modelID: "mlx-community/Tiny",
            localPath: snapshot.path,
            cacheRoot: root
        )

        XCTAssertEqual(deleted.lastPathComponent, "models--mlx-community--Tiny")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "models--mlx-community--Tiny").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDirectory.path))
    }

    func testCacheManagerDeletesRepoCacheFolderFromRecordedSnapshotPathOutsideDefaultRoot() throws {
        let defaultRoot = try temporaryDirectory()
        let actualRoot = try temporaryDirectory()
        let actualRepo = actualRoot.appending(path: "models--mlx-community--Tiny", directoryHint: .isDirectory)
        let snapshot = actualRepo.appending(path: "snapshots/abc123", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: snapshot.appending(path: "config.json").path, contents: Data())

        let manager = MLXModelCacheManager()
        let deleted = try manager.deleteModelCache(
            modelID: "mlx-community/Tiny",
            localPath: snapshot.path,
            cacheRoot: defaultRoot
        )

        XCTAssertEqual(deleted.standardizedFileURL.path, actualRepo.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: actualRepo.path))
    }

    func testCacheManagerRejectsUnsafeModelIDWithoutDeletingCacheRoot() throws {
        let root = try temporaryDirectory()
        let keep = root.appending(path: "models--mlx-community--Tiny", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)

        let manager = MLXModelCacheManager()

        XCTAssertThrowsError(
            try manager.deleteModelCache(modelID: "../Tiny", localPath: nil, cacheRoot: root)
        ) { error in
            XCTAssertEqual(error as? MLXModelCacheError, .unsafeModelID("../Tiny"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    }

    func testHuggingFaceSearcherDecodesModelSummaries() async throws {
        let runner = FakeCommandRunner(results: [
            "search": CommandResult(
                exitCode: 0,
                standardOutput: #"[{"id":"mlx-community/Tiny","downloads":42,"likes":7,"model_type":"mistral"}]"#,
                standardError: ""
            )
        ])
        let searcher = HuggingFaceModelSearcher(runner: runner)

        let results = try await searcher.search(query: "tiny", pythonExecutable: URL(filePath: "/tmp/python"), limit: 5)

        XCTAssertEqual(results, [HuggingFaceModelSummary(id: "mlx-community/Tiny", downloads: 42, likes: 7, modelType: "mistral")])
    }

    func testHuggingFaceSearcherScopesToMLXCommunityAndSortsByDownloads() async throws {
        let runner = RecordingCommandRunner(result: CommandResult(
            exitCode: 0,
            standardOutput: #"[]"#,
            standardError: ""
        ))
        let searcher = HuggingFaceModelSearcher(runner: runner)

        _ = try await searcher.search(query: "Devstral", pythonExecutable: URL(filePath: "/tmp/python"), limit: 50)

        let command = try XCTUnwrap(runner.commands.last)
        let script = try XCTUnwrap(command.pythonScript)
        XCTAssertEqual(command.arguments.suffix(4), ["Devstral", "mlx-community", "downloads", "50"])
        XCTAssertTrue(script.contains("author=author"))
        XCTAssertTrue(script.contains("filter='mlx'"))
        XCTAssertTrue(script.contains("sort=sort"))
        XCTAssertFalse(script.contains("direction="))
        XCTAssertTrue(script.contains("limit=limit"))
        XCTAssertTrue(script.contains("hf_hub_download"))
        XCTAssertTrue(script.contains("TemporaryDirectory"))
        XCTAssertTrue(script.contains("cache_dir=config_cache"))
        XCTAssertTrue(script.contains("model_type"))
        XCTAssertTrue(script.contains("ThreadPoolExecutor(max_workers=8)"))
        XCTAssertTrue(script.contains("executor.map"))
    }

    func testHuggingFaceSearcherPassesDynamicValuesAsArguments() async throws {
        let runner = RecordingCommandRunner(result: CommandResult(
            exitCode: 0,
            standardOutput: #"[]"#,
            standardError: ""
        ))
        let searcher = HuggingFaceModelSearcher(runner: runner)
        let query = #"""
        tiny\model
        'quoted'
        """#

        _ = try await searcher.search(
            query: query,
            pythonExecutable: URL(filePath: "/tmp/python"),
            author: "mlx-community",
            sort: "downloads",
            limit: 7
        )

        let command = try XCTUnwrap(runner.commands.last)
        XCTAssertEqual(command.arguments.suffix(4), [query, "mlx-community", "downloads", "7"])
        XCTAssertFalse(command.arguments[1].contains(query))
    }

    func testHuggingFaceAuthCheckerReportsLoggedInAndLoggedOutStates() async throws {
        let loggedInRunner = FakeCommandRunner(results: [
            "whoami": CommandResult(exitCode: 0, standardOutput: #"{"name":"octocat"}"#, standardError: "")
        ])
        let loggedOutRunner = FakeCommandRunner(results: [
            "whoami": CommandResult(exitCode: 1, standardOutput: "", standardError: "Invalid user token")
        ])
        let unavailableRunner = FakeCommandRunner(results: [
            "whoami": CommandResult(exitCode: 1, standardOutput: "", standardError: "No module named huggingface_hub")
        ])

        let python = URL(filePath: "/tmp/python")
        let loggedIn = try await HuggingFaceAuthChecker(runner: loggedInRunner).status(pythonExecutable: python)
        let loggedOut = try await HuggingFaceAuthChecker(runner: loggedOutRunner).status(pythonExecutable: python)
        let unavailable = try await HuggingFaceAuthChecker(runner: unavailableRunner).status(pythonExecutable: python)

        XCTAssertEqual(loggedIn, .loggedIn(username: "octocat"))
        XCTAssertEqual(loggedOut, .loggedOut("Invalid user token"))
        XCTAssertEqual(unavailable, .unavailable("No module named huggingface_hub"))
    }

    func testHuggingFaceInstallerReturnsDownloadedSnapshotPath() async throws {
        let runner = FakeCommandRunner(results: [
            "install": CommandResult(
                exitCode: 0,
                standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
                standardError: ""
            )
        ])
        let installer = HuggingFaceModelInstaller(runner: runner)

        let result = try await installer.install(
            modelID: "mlx-community/Tiny",
            pythonExecutable: URL(filePath: "/tmp/python")
        )

        XCTAssertEqual(result.localPath, "/tmp/cache/models--mlx-community--Tiny/snapshots/abc")
    }

    func testHuggingFaceDownloadProgressParsesTqdmETA() throws {
        let line = "model.safetensors:  42%|####      | 4.20G/10.0G [05:10<07:12, 13.4MB/s]"

        let progress = try XCTUnwrap(HuggingFaceDownloadProgress.parse(from: line))

        XCTAssertEqual(progress.fractionCompleted, 0.42, accuracy: 0.001)
        XCTAssertEqual(progress.percentText, "42%")
        XCTAssertEqual(progress.etaText, "7m 12s")
        XCTAssertEqual(progress.rateText, "13.4MB/s")
    }

    func testHuggingFaceDownloadProgressParsesCommonByteRateUnits() throws {
        let units = ["B/s", "KB/s", "KiB/s", "MB/s", "MiB/s", "GB/s", "GiB/s"]

        for unit in units {
            let line = "model.safetensors:  8%|8         | 80M/1.00G [00:02<00:23, 4.0\(unit)]"

            let progress = try XCTUnwrap(HuggingFaceDownloadProgress.parse(from: line))

            XCTAssertEqual(progress.etaText, "23s")
            XCTAssertEqual(progress.rateText, "4.0\(unit)")
        }
    }

    func testHuggingFaceDownloadProgressHandlesCarriageReturnUpdates() throws {
        let output = "Fetching 14 files:   7%|7         | 1/14 [00:12<00:06, 2.27it/s]\rmodel.safetensors:  42%|####      | 4.20G/10.0G [05:10<07:12, 13.4MiB/s]"

        let progress = try XCTUnwrap(HuggingFaceDownloadProgress.parse(from: output))

        XCTAssertEqual(progress.percentText, "42%")
        XCTAssertEqual(progress.etaText, "7m 12s")
        XCTAssertEqual(progress.rateText, "13.4MiB/s")
    }

    func testHuggingFaceDownloadProgressIgnoresItemCounterETA() throws {
        let line = "Fetching 14 files:   7%|7         | 1/14 [00:12<00:06, 2.27it/s]"

        XCTAssertNil(HuggingFaceDownloadProgress.parse(from: line))
    }

    func testHuggingFaceDownloadProgressPrefersByteProgressOverFileCounter() throws {
        let output = """
        model.safetensors:  42%|####      | 4.20G/10.0G [05:10<07:12, 13.4MB/s]
        Fetching 14 files:   7%|7         | 1/14 [00:12<00:06, 2.27it/s]
        """

        let progress = try XCTUnwrap(HuggingFaceDownloadProgress.parse(from: output))

        XCTAssertEqual(progress.percentText, "42%")
        XCTAssertEqual(progress.etaText, "7m 12s")
        XCTAssertEqual(progress.rateText, "13.4MB/s")
    }

    func testHuggingFaceDownloadActivityParsesXetConnectionStrugglingJSON() throws {
        let line = #"{"timestamp":"2026-06-12T14:00:45Z","level":"INFO","fields":{"message":"Concurrency control for download: Decreased concurrency from 1 to 1; reason: success ratio below threshold (connection struggling) (success_ratio = 1.000, threshold = 0.500)"}}"#

        let activities = HuggingFaceDownloadActivity.parse(from: line)

        XCTAssertEqual(activities, [
            HuggingFaceDownloadActivity(
                message: "Xet transfer: connection struggling, concurrency reduced",
                tone: .warning,
                source: .xetLog
            )
        ])
    }

    func testHuggingFaceDownloadActivityParsesSnapshotStartMarker() throws {
        let output = "MLXDashboard: Started Hugging Face snapshot download for mlx-community/Tiny\n"

        let activities = HuggingFaceDownloadActivity.parse(from: output)

        XCTAssertEqual(activities, [
            HuggingFaceDownloadActivity(
                message: "Started Hugging Face snapshot download for mlx-community/Tiny",
                tone: .info,
                source: .commandOutput
            )
        ])
    }

    func testHuggingFaceInstallerReportsDownloadProgressFromCommandOutput() async throws {
        let runner = FakeCommandRunner(results: [
            "install": CommandResult(
                exitCode: 0,
                standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
                standardError: "model.safetensors:  42%|####      | 4.20G/10.0G [05:10<07:12, 13.4MB/s]"
            )
        ])
        let installer = HuggingFaceModelInstaller(runner: runner)
        let recorder = DownloadProgressRecorder()

        _ = try await installer.install(
            modelID: "mlx-community/Tiny",
            pythonExecutable: URL(filePath: "/tmp/python"),
            progressHandler: { recorder.append($0) }
        )

        XCTAssertEqual(recorder.last?.etaText, "7m 12s")
        XCTAssertEqual(recorder.last?.fractionCompleted ?? 0, 0.42, accuracy: 0.001)
    }

    func testHuggingFaceInstallerReportsDownloadActivityFromCommandOutput() async throws {
        let runner = FakeCommandRunner(results: [
            "install": CommandResult(
                exitCode: 0,
                standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
                standardError: "MLXDashboard: Started Hugging Face snapshot download for mlx-community/Tiny"
            )
        ])
        let installer = HuggingFaceModelInstaller(runner: runner)
        let recorder = DownloadActivityRecorder()

        _ = try await installer.install(
            modelID: "mlx-community/Tiny",
            pythonExecutable: URL(filePath: "/tmp/python"),
            activityHandler: { recorder.append($0) }
        )

        XCTAssertEqual(recorder.events, [
            HuggingFaceDownloadActivity(
                message: "Started Hugging Face snapshot download for mlx-community/Tiny",
                tone: .info,
                source: .commandOutput
            )
        ])
    }

    func testHuggingFaceInstallerAppliesProvidedDownloadEnvironment() async throws {
        let runner = RecordingCommandRunner(result: CommandResult(
            exitCode: 0,
            standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
            standardError: ""
        ))
        let installer = HuggingFaceModelInstaller(runner: runner)

        _ = try await installer.install(
            modelID: "mlx-community/Tiny",
            pythonExecutable: URL(filePath: "/tmp/python"),
            downloadEnvironment: [
                "HF_XET_NUM_CONCURRENT_RANGE_GETS": "2",
                "HF_HUB_DOWNLOAD_TIMEOUT": "90"
            ]
        )

        XCTAssertEqual(runner.commands.last?.environment["HF_XET_NUM_CONCURRENT_RANGE_GETS"], "2")
        XCTAssertEqual(runner.commands.last?.environment["HF_HUB_DOWNLOAD_TIMEOUT"], "90")
        XCTAssertNil(runner.commands.last?.environment["HF_HUB_DISABLE_XET"])
    }

    func testHuggingFaceInstallerAppliesProvidedDownloadEnvironmentRemovals() async throws {
        let runner = RecordingCommandRunner(result: CommandResult(
            exitCode: 0,
            standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
            standardError: ""
        ))
        let installer = HuggingFaceModelInstaller(runner: runner)

        _ = try await installer.install(
            modelID: "mlx-community/Tiny",
            pythonExecutable: URL(filePath: "/tmp/python"),
            downloadEnvironment: ["HF_XET_NUM_CONCURRENT_RANGE_GETS": "2"],
            downloadEnvironmentRemovals: ["HF_HUB_DISABLE_XET"]
        )

        XCTAssertEqual(runner.commands.last?.environment["HF_XET_NUM_CONCURRENT_RANGE_GETS"], "2")
        XCTAssertEqual(runner.commands.last?.environmentRemovals, ["HF_HUB_DISABLE_XET"])
    }

    func testHuggingFaceInstallerPassesModelIDAsArgument() async throws {
        let runner = RecordingCommandRunner(result: CommandResult(
            exitCode: 0,
            standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
            standardError: ""
        ))
        let installer = HuggingFaceModelInstaller(runner: runner)
        let modelID = #"""
        mlx-community/Tiny\Odd
        'quoted'
        """#

        _ = try await installer.install(
            modelID: modelID,
            pythonExecutable: URL(filePath: "/tmp/python")
        )

        let command = try XCTUnwrap(runner.commands.last)
        XCTAssertEqual(command.arguments.last, modelID)
        XCTAssertFalse(command.arguments[1].contains(modelID))
    }

    func testCommandResolvedEnvironmentRemovesInheritedValues() {
        let command = Command(
            executableURL: URL(filePath: "/tmp/python"),
            arguments: ["-c", "print('ok')"],
            environment: ["HF_XET_NUM_CONCURRENT_RANGE_GETS": "2"],
            environmentRemovals: ["HF_HUB_DISABLE_XET"]
        )

        let environment = command.resolvedEnvironment(base: [
            "HF_HUB_DISABLE_XET": "1",
            "PATH": "/usr/bin"
        ])

        XCTAssertNil(environment["HF_HUB_DISABLE_XET"])
        XCTAssertEqual(environment["HF_XET_NUM_CONCURRENT_RANGE_GETS"], "2")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
    }

    func testHuggingFaceInstallerDisablesXetWhenRequested() async throws {
        let runner = RecordingCommandRunner(result: CommandResult(
            exitCode: 0,
            standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
            standardError: ""
        ))
        let installer = HuggingFaceModelInstaller(runner: runner)

        _ = try await installer.install(
            modelID: "mlx-community/Tiny",
            pythonExecutable: URL(filePath: "/tmp/python"),
            downloadEnvironment: ["HF_HUB_DISABLE_XET": "1"]
        )

        XCTAssertEqual(runner.commands.last?.environment["HF_HUB_DISABLE_XET"], "1")
    }

    func testHuggingFaceInstallerDoesNotReplaceReliableProgressWithFileCounterOnlyOutput() async throws {
        let runner = FakeCommandRunner(results: [
            "install": CommandResult(
                exitCode: 0,
                standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
                standardError: """
                model.safetensors:  42%|####      | 4.20G/10.0G [05:10<07:12, 13.4MB/s]
                Fetching 14 files:   7%|7         | 1/14 [00:12<00:06, 2.27it/s]
                """
            )
        ])
        let installer = HuggingFaceModelInstaller(runner: runner)
        let recorder = DownloadProgressRecorder()

        _ = try await installer.install(
            modelID: "mlx-community/Tiny",
            pythonExecutable: URL(filePath: "/tmp/python"),
            progressHandler: { recorder.append($0) }
        )

        XCTAssertEqual(recorder.eventCount, 1)
        XCTAssertEqual(recorder.last?.etaText, "7m 12s")
    }

    func testHuggingFaceInstallerReportsDownloadActivityFromSplitCommandOutputChunks() async throws {
        let runner = SplitOutputCommandRunner(
            chunks: [
                "MLXDash",
                "board: Started Hugging Face snapshot ",
                "download for mlx-community/Tiny"
            ],
            result: CommandResult(
                exitCode: 0,
                standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
                standardError: ""
            )
        )
        let installer = HuggingFaceModelInstaller(runner: runner)
        let recorder = DownloadActivityRecorder()

        _ = try await installer.install(
            modelID: "mlx-community/Tiny",
            pythonExecutable: URL(filePath: "/tmp/python"),
            activityHandler: { recorder.append($0) }
        )

        XCTAssertEqual(recorder.events, [
            HuggingFaceDownloadActivity(
                message: "Started Hugging Face snapshot download for mlx-community/Tiny",
                tone: .info,
                source: .commandOutput
            )
        ])
    }

    func testHuggingFaceInstallerReportsInstallFailure() async throws {
        let runner = FakeCommandRunner(results: [
            "install": CommandResult(exitCode: 1, standardOutput: "", standardError: "download failed")
        ])
        let installer = HuggingFaceModelInstaller(runner: runner)

        do {
            _ = try await installer.install(modelID: "mlx-community/Tiny", pythonExecutable: URL(filePath: "/tmp/python"))
            XCTFail("Expected install to fail")
        } catch let error as HuggingFaceError {
            XCTAssertEqual(error, .installFailed("download failed"))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MLXPythonBridgeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class RecordingCommandRunner: CommandRunning, @unchecked Sendable {
    private(set) var commands: [Command] = []
    let result: CommandResult

    init(result: CommandResult) {
        self.result = result
    }

    func run(_ command: Command) async throws -> CommandResult {
        commands.append(command)
        return result
    }
}

private struct FakeCommandRunner: CommandRunning {
    let results: [String: CommandResult]

    func run(_ command: Command) async throws -> CommandResult {
        let script = command.pythonScript ?? ""
        let key: String
        if script.contains("list_models") {
            key = "search"
        } else if script.contains("snapshot_download") {
            key = "install"
        } else if script.contains("whoami") {
            key = "whoami"
        } else if script.contains("MLXDashboard runtime package versions") {
            key = "runtime-package-versions"
        } else if script.contains("metadata.distribution(\"mlx-lm\")") {
            key = "runtime-capabilities"
        } else if command.arguments == ["-m", "pip", "list", "--outdated", "--format=json"] {
            key = "pip-outdated"
        } else if command.arguments == ["-m", "pip", "install", "--upgrade", "mlx", "mlx-lm"] {
            key = "runtime-upgrade"
        } else {
            key = script
        }
        return results[key] ?? CommandResult(exitCode: 127, standardOutput: "", standardError: "unexpected command \(key)")
    }
}

private extension Command {
    var pythonScript: String? {
        guard let commandIndex = arguments.firstIndex(of: "-c"),
              arguments.indices.contains(commandIndex + 1)
        else { return nil }
        return arguments[commandIndex + 1]
    }
}

private struct SplitOutputCommandRunner: CommandRunning {
    let chunks: [String]
    let result: CommandResult

    func run(_ command: Command) async throws -> CommandResult {
        result
    }

    func run(_ command: Command, outputHandler: CommandOutputHandler?) async throws -> CommandResult {
        for chunk in chunks {
            outputHandler?(chunk)
        }
        return result
    }
}

private final class DownloadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HuggingFaceDownloadProgress] = []

    var last: HuggingFaceDownloadProgress? {
        lock.withLock {
            events.last
        }
    }

    var eventCount: Int {
        lock.withLock {
            events.count
        }
    }

    func append(_ progress: HuggingFaceDownloadProgress) {
        lock.withLock {
            events.append(progress)
        }
    }
}

private final class DownloadActivityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [HuggingFaceDownloadActivity] = []

    var events: [HuggingFaceDownloadActivity] {
        lock.withLock { recordedEvents }
    }

    func append(_ activity: HuggingFaceDownloadActivity) {
        lock.withLock {
            recordedEvents.append(activity)
        }
    }
}
