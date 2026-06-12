import XCTest
import MLXCore
import MLXPythonBridge
@testable import MLXDashboardApp

@MainActor
final class DashboardViewModelTests: XCTestCase {
    func testSearchModelsWithMissingPythonPackagesPromptsInstallInsteadOfSearching() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 1, standardOutput: "", standardError: "No module named mlx_lm"),
            "import huggingface_hub": CommandResult(exitCode: 1, standardOutput: "", standardError: "No module named huggingface_hub")
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            tokenStore: StubTokenStore(),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner)
        )

        await viewModel.searchModels()

        XCTAssertEqual(viewModel.searchResults, [])
        XCTAssertEqual(viewModel.modelSearchMessage, "Python packages are required before searching: mlx-lm, huggingface_hub.")
        XCTAssertTrue(viewModel.shouldOfferPythonPackageInstall)
        XCTAssertEqual(runner.commands.count, 2)
    }

    func testInstallPythonPackagesInstallsRequiredPackagesWhenPrompted() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "huggingface_hub": CommandResult(exitCode: 0, standardOutput: "installed", standardError: "")
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            tokenStore: StubTokenStore(),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner)
        )
        viewModel.shouldOfferPythonPackageInstall = true
        viewModel.modelSearchMessage = "Python packages are required before searching: mlx-lm, huggingface_hub."

        await viewModel.installPythonPackages()

        XCTAssertEqual(runner.commands.map(\.arguments), [
            ["-m", "pip", "install", "--upgrade", "mlx-lm", "huggingface_hub"]
        ])
        XCTAssertEqual(viewModel.pythonStatus, "Ready")
        XCTAssertFalse(viewModel.shouldOfferPythonPackageInstall)
        XCTAssertEqual(viewModel.modelSearchMessage, "Python packages installed. Search is ready.")
    }

    func testInstallSelectedModelWithMissingPythonPackagesPromptsInstallInsteadOfStartingDownload() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 1, standardOutput: "", standardError: "No module named mlx_lm"),
            "import huggingface_hub": CommandResult(exitCode: 1, standardOutput: "", standardError: "No module named huggingface_hub")
        ])
        let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            tokenStore: StubTokenStore(),
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner)
        )
        viewModel.searchResults = [HuggingFaceModelSummary(id: "mlx-community/Tiny", downloads: 42, likes: 7)]
        viewModel.selectedSearchModelID = "mlx-community/Tiny"

        await viewModel.installSelectedModel()

        XCTAssertEqual(viewModel.modelInstallMessage, "Install needs Python packages first: mlx-lm, huggingface_hub. Use Install Packages, then try again.")
        XCTAssertTrue(viewModel.shouldOfferPythonPackageInstall)
        XCTAssertNil(registry.record(id: "mlx-community/Tiny"))
    }

    func testInstallSelectedModelInstallsChosenSearchResultAndStoresLocalPath() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "whoami": CommandResult(exitCode: 0, standardOutput: #"{"name":"octocat"}"#, standardError: ""),
            "install": CommandResult(
                exitCode: 0,
                standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
                standardError: ""
            )
        ])
        let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            tokenStore: StubTokenStore(),
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelInstaller: HuggingFaceModelInstaller(runner: runner),
            authChecker: HuggingFaceAuthChecker(runner: runner)
        )
        viewModel.searchResults = [
            HuggingFaceModelSummary(id: "mlx-community/Other"),
            HuggingFaceModelSummary(id: "mlx-community/Tiny")
        ]
        viewModel.selectedSearchModelID = "mlx-community/Tiny"

        await viewModel.installSelectedModel()

        let record = registry.record(id: "mlx-community/Tiny")
        XCTAssertEqual(record?.status, .installed)
        XCTAssertEqual(record?.localPath, "/tmp/cache/models--mlx-community--Tiny/snapshots/abc")
        XCTAssertEqual(viewModel.huggingFaceAuthMessage, "Hugging Face: logged in as octocat")
        XCTAssertEqual(viewModel.modelInstallMessage, "Installed mlx-community/Tiny at /tmp/cache/models--mlx-community--Tiny/snapshots/abc")
        XCTAssertNil(registry.record(id: "mlx-community/Other"))
    }

    func testSetSelectedInstalledModelActiveSavesSettings() throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            tokenStore: StubTokenStore(),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )
        viewModel.installedModels = [
            ModelRecord(id: "mlx-community/Tiny", status: .installed, localPath: "/tmp/tiny")
        ]
        viewModel.selectedInstalledModelID = "mlx-community/Tiny"

        viewModel.setSelectedInstalledModelActive()

        XCTAssertEqual(viewModel.settings.activeModel, "mlx-community/Tiny")
        XCTAssertEqual(try SettingsStore(fileURL: paths.settingsFile).load().activeModel, "mlx-community/Tiny")
    }

    func testDeleteSelectedInstalledModelRemovesWholeRepoCacheFolderAndMarksRemoved() throws {
        let paths = try temporaryAppPaths()
        let cacheRoot = try temporaryDirectory()
        let snapshot = cacheRoot.appending(path: "models--mlx-community--Tiny/snapshots/abc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: snapshot.appending(path: "config.json").path, contents: Data())

        let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
        registry.upsert(ModelRecord(id: "mlx-community/Tiny", status: .installed, localPath: snapshot.path))
        try registry.save()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            tokenStore: StubTokenStore(),
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:])),
            huggingFaceCacheRoot: cacheRoot
        )
        viewModel.selectedInstalledModelID = "mlx-community/Tiny"

        viewModel.deleteSelectedInstalledModelFromCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appending(path: "models--mlx-community--Tiny").path))
        XCTAssertEqual(registry.record(id: "mlx-community/Tiny")?.status, .removed)
        XCTAssertEqual(viewModel.modelInstallMessage, "Deleted cache for mlx-community/Tiny.")
    }

    private func temporaryAppPaths() throws -> AppPaths {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MLXDashboardAppTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AppPaths(applicationSupport: root)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MLXDashboardAppTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    private(set) var commands: [Command] = []
    let results: [String: CommandResult]

    init(results: [String: CommandResult]) {
        self.results = results
    }

    func run(_ command: Command) async throws -> CommandResult {
        commands.append(command)
        let script = command.arguments.last ?? ""
        let key: String
        if script.contains("snapshot_download") {
            key = "install"
        } else if script.contains("whoami") {
            key = "whoami"
        } else {
            key = script
        }
        return results[key] ?? CommandResult(exitCode: 127, standardOutput: "", standardError: "unexpected command \(key)")
    }
}

private struct StubTokenStore: ProviderTokenStoring {
    func token() throws -> String {
        "test-token"
    }

    func regenerateToken() throws -> String {
        "new-test-token"
    }
}
