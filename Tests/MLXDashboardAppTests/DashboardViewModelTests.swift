import XCTest
import Combine
import MLXCore
import MLXPythonBridge
import MLXServerControl
@testable import MLXDashboardApp

@MainActor
final class DashboardViewModelTests: XCTestCase {
    func testAppLaunchOptionsEnableAutostartProvider() {
        XCTAssertTrue(AppLaunchOptions(arguments: ["MLXDashboard", "--autostart-provider"]).autostartProvider)
        XCTAssertTrue(AppLaunchOptions(arguments: ["MLXDashboard", "--autostart"]).autostartProvider)
        XCTAssertFalse(AppLaunchOptions(arguments: ["MLXDashboard"]).autostartProvider)
    }

    func testDashboardLowerSectionsUseSharedMinimumHeight() {
        XCTAssertEqual(DashboardLayoutPolicy.activeModelMinHeight, DashboardLayoutPolicy.recentLogsMinHeight)
        XCTAssertEqual(DashboardLayoutPolicy.activeModelMinHeight, 240)
    }

    func testControllerButtonPolicyFollowsServerState() {
        XCTAssertTrue(ControllerButtonPolicy.canStartServer(state: .stopped))
        XCTAssertTrue(ControllerButtonPolicy.canStartServer(state: .failed))
        XCTAssertFalse(ControllerButtonPolicy.canStartServer(state: .starting))
        XCTAssertFalse(ControllerButtonPolicy.canStartServer(state: .running))
        XCTAssertFalse(ControllerButtonPolicy.canStartServer(state: .stopping))

        XCTAssertTrue(ControllerButtonPolicy.canStopServer(state: .starting))
        XCTAssertTrue(ControllerButtonPolicy.canStopServer(state: .running))
        XCTAssertFalse(ControllerButtonPolicy.canStopServer(state: .stopped))
        XCTAssertFalse(ControllerButtonPolicy.canStopServer(state: .failed))
        XCTAssertFalse(ControllerButtonPolicy.canStopServer(state: .stopping))

        XCTAssertTrue(ControllerButtonPolicy.canRestartServer(state: .running))
        XCTAssertFalse(ControllerButtonPolicy.canRestartServer(state: .stopped))
        XCTAssertFalse(ControllerButtonPolicy.canRestartServer(state: .starting))
        XCTAssertFalse(ControllerButtonPolicy.canRestartServer(state: .stopping))
        XCTAssertFalse(ControllerButtonPolicy.canRestartServer(state: .failed))
    }

    func testControllerAvailabilityRefreshesWhenServerStateChanges() throws {
        let paths = try temporaryAppPaths()
        let process = FakeManagedProcess()
        let serverController = ServerProcessController(
            processLauncher: FakeProcessLauncher(processes: [process]),
            portChecker: FakePortChecker(isAvailable: true)
        )
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:])),
            serverController: serverController
        )
        var refreshCount = 0
        let cancellable = viewModel.objectWillChange.sink {
            refreshCount += 1
        }

        XCTAssertTrue(viewModel.canStartServer)
        XCTAssertFalse(viewModel.canStopServer)
        XCTAssertFalse(viewModel.canRestartServer)

        try serverController.start(settings: DashboardSettings(), pythonExecutable: URL(filePath: "/venv/bin/python"))

        XCTAssertFalse(viewModel.canStartServer)
        XCTAssertTrue(viewModel.canStopServer)
        XCTAssertTrue(viewModel.canRestartServer)
        XCTAssertGreaterThan(refreshCount, 0)
        cancellable.cancel()
    }

    func testDashboardTelemetryUsesEnvironmentLogPath() throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )

        viewModel.telemetry.appendLog("Temp-path telemetry check")

        let logText = try String(contentsOf: paths.logsDirectory.appending(path: "mlxdashboard.log"), encoding: .utf8)
        XCTAssertTrue(logText.contains("Temp-path telemetry check"))
    }

    func testRestartServerRestartsRunningController() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())
        let originalProcess = FakeManagedProcess()
        let restartedProcess = FakeManagedProcess()
        let serverController = ServerProcessController(
            processLauncher: FakeProcessLauncher(processes: [originalProcess, restartedProcess]),
            portChecker: FakePortChecker(isAvailable: true)
        )
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [
                "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
                "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            ])),
            serverController: serverController
        )

        try serverController.start(settings: DashboardSettings(), pythonExecutable: python)
        await viewModel.restartServer()

        XCTAssertTrue(originalProcess.wasTerminated)
        XCTAssertTrue(restartedProcess.wasLaunched)
        XCTAssertEqual(serverController.state, .running)
    }

    func testStartServerLogsFriendlyMessageWhenMLXPortIsUnavailable() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())
        let process = FakeManagedProcess()
        let serverController = ServerProcessController(
            processLauncher: FakeProcessLauncher(processes: [process]),
            portChecker: FakePortChecker(isAvailable: false)
        )
        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            serverController: serverController
        )

        await viewModel.startServer()

        XCTAssertEqual(serverController.state, .failed)
        XCTAssertFalse(process.wasLaunched)
        let logText = try String(contentsOf: paths.logsDirectory.appending(path: "mlxdashboard.log"), encoding: .utf8)
        XCTAssertTrue(logText.contains("Failed to start server: Cannot start mlx-lm because 127.0.0.1:8080 is already in use."))
    }

    func testProviderStartStopAvailabilityFollowsProviderState() throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )
        viewModel.settings.providerPort = 0

        XCTAssertTrue(viewModel.canStartProvider)
        XCTAssertFalse(viewModel.canStopProvider)

        try viewModel.startProvider()
        defer { viewModel.stopProvider() }

        XCTAssertFalse(viewModel.canStartProvider)
        XCTAssertTrue(viewModel.canStopProvider)
    }

    func testRunningProviderUsesActiveModelSelectedAfterProviderStart() async throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )
        viewModel.settings.providerPort = 18123
        viewModel.installedModels = [
            ModelRecord(id: "mlx-community/Tiny", status: .installed, localPath: "/tmp/tiny")
        ]

        do {
            try viewModel.startProvider()
        } catch {
            throw XCTSkip("Loopback listener unavailable in this sandbox: \(error)")
        }
        defer { viewModel.stopProvider() }

        viewModel.selectedInstalledModelID = "mlx-community/Tiny"
        viewModel.setSelectedInstalledModelActive()

        let url = URL(string: "http://127.0.0.1:18123/v1/models")!
        let (data, response) = try await URLSession.shared.data(from: url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try Self.modelIDs(in: data), ["mlx-ask", "mlx-plan", "mlx-fast", "mlx-community/Tiny"])
    }

    func testDefaultsModelQueryToDevstralSmall() throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )

        XCTAssertEqual(viewModel.modelQuery, "Devstral-Small")
    }

    func testSearchDefaultModelsIfReadyRunsSearchWhenPackagesAreReady() async throws {
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
            "search": CommandResult(
                exitCode: 0,
                standardOutput: #"[{"id":"lmstudio-community/Devstral-Small-2505-MLX-4bit","downloads":10036,"likes":7}]"#,
                standardError: ""
            )
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelSearcher: HuggingFaceModelSearcher(runner: runner)
        )

        await viewModel.searchDefaultModelsIfReady()

        XCTAssertEqual(viewModel.searchResults.map(\.id), ["lmstudio-community/Devstral-Small-2505-MLX-4bit"])
        XCTAssertEqual(viewModel.modelSearchMessage, "Showing 1 mlx-community result sorted by downloads.")
        XCTAssertFalse(viewModel.shouldOfferPythonPackageInstall)
    }

    func testSearchModelsRequestsInitialMLXCommunityPageAndCanLoadMoreWhenPageIsFull() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "search-limit-50": CommandResult(exitCode: 0, standardOutput: Self.modelListJSON(count: 50), standardError: "")
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelSearcher: HuggingFaceModelSearcher(runner: runner)
        )

        await viewModel.searchModels()

        XCTAssertEqual(viewModel.searchResults.count, 50)
        XCTAssertTrue(viewModel.canLoadMoreSearchResults)
        XCTAssertFalse(viewModel.isLoadingMoreSearchResults)
        XCTAssertTrue(runner.commands.contains { ($0.arguments.last ?? "").contains("limit=50") })
        XCTAssertEqual(viewModel.modelSearchMessage, "Showing 50 mlx-community results sorted by downloads.")
    }

    func testLoadMoreSearchResultsRefetchesWithNextLimit() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "search-limit-50": CommandResult(exitCode: 0, standardOutput: Self.modelListJSON(count: 50), standardError: ""),
            "search-limit-100": CommandResult(exitCode: 0, standardOutput: Self.modelListJSON(count: 100), standardError: "")
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelSearcher: HuggingFaceModelSearcher(runner: runner)
        )

        await viewModel.searchModels()
        await viewModel.loadMoreSearchResults()

        XCTAssertEqual(viewModel.searchResults.count, 100)
        XCTAssertTrue(viewModel.canLoadMoreSearchResults)
        XCTAssertTrue(runner.commands.contains { ($0.arguments.last ?? "").contains("limit=100") })
        XCTAssertEqual(viewModel.modelSearchMessage, "Showing 100 mlx-community results sorted by downloads.")
    }

    func testLoadMoreSearchResultsStopsWhenFewerResultsReturn() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "search-limit-50": CommandResult(exitCode: 0, standardOutput: Self.modelListJSON(count: 50), standardError: ""),
            "search-limit-100": CommandResult(exitCode: 0, standardOutput: Self.modelListJSON(count: 64), standardError: "")
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelSearcher: HuggingFaceModelSearcher(runner: runner)
        )

        await viewModel.searchModels()
        await viewModel.loadMoreSearchResults()

        XCTAssertEqual(viewModel.searchResults.count, 64)
        XCTAssertFalse(viewModel.canLoadMoreSearchResults)
        XCTAssertEqual(viewModel.modelSearchMessage, "Showing 64 mlx-community results sorted by downloads.")
    }

    func testSearchModelsResetsLimitForNewQuery() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "search-limit-50": CommandResult(exitCode: 0, standardOutput: Self.modelListJSON(count: 50), standardError: ""),
            "search-limit-100": CommandResult(exitCode: 0, standardOutput: Self.modelListJSON(count: 100), standardError: "")
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelSearcher: HuggingFaceModelSearcher(runner: runner)
        )

        await viewModel.searchModels()
        await viewModel.loadMoreSearchResults()
        viewModel.modelQuery = "Qwen"
        await viewModel.searchModels()

        let searchScripts = runner.commands
            .compactMap { $0.arguments.last }
            .filter { $0.contains("list_models") }
        XCTAssertTrue(searchScripts.suffix(1).allSatisfy { $0.contains("limit=50") })
        XCTAssertEqual(viewModel.searchResults.count, 50)
    }

    func testSearchDefaultModelsIfReadyPromptsForPackagesWithoutSearchingWhenMissing() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 1, standardOutput: "", standardError: "No module named mlx_lm"),
            "import huggingface_hub": CommandResult(exitCode: 1, standardOutput: "", standardError: "No module named huggingface_hub"),
            "search": CommandResult(
                exitCode: 0,
                standardOutput: #"[{"id":"should-not-search","downloads":1,"likes":1}]"#,
                standardError: ""
            )
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelSearcher: HuggingFaceModelSearcher(runner: runner)
        )

        await viewModel.searchDefaultModelsIfReady()

        XCTAssertEqual(viewModel.searchResults, [])
        XCTAssertEqual(viewModel.modelSearchMessage, "Install Python packages to search default MLX models: mlx-lm, huggingface_hub.")
        XCTAssertTrue(viewModel.shouldOfferPythonPackageInstall)
        XCTAssertFalse(runner.commands.contains { ($0.arguments.last ?? "").contains("list_models") })
    }

    func testSearchDefaultModelsIfReadyShowsFriendlyCancellationMessage() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(
            results: [
                "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
                "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            ],
            thrownErrors: [
                "search": CancellationError()
            ]
        )
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelSearcher: HuggingFaceModelSearcher(runner: runner)
        )

        await viewModel.searchDefaultModelsIfReady()

        XCTAssertEqual(viewModel.modelSearchMessage, "Default model search cancelled.")
        let logText = try String(contentsOf: paths.logsDirectory.appending(path: "mlxdashboard.log"), encoding: .utf8)
        XCTAssertTrue(logText.contains("Default model search cancelled."))
        XCTAssertFalse(logText.contains("Default model search failed"))
    }

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

    func testInstallSelectedModelUsesStandardDownloadEnvironmentByDefault() async throws {
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
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelInstaller: HuggingFaceModelInstaller(runner: runner),
            authChecker: HuggingFaceAuthChecker(runner: runner)
        )
        viewModel.searchResults = [HuggingFaceModelSummary(id: "mlx-community/Tiny")]
        viewModel.selectedSearchModelID = "mlx-community/Tiny"

        await viewModel.installSelectedModel()

        let installCommands = runner.commands.filter { ($0.arguments.last ?? "").contains("snapshot_download") }
        XCTAssertEqual(installCommands.last?.environment["HF_HUB_DISABLE_XET"], "1")
        XCTAssertNil(installCommands.last?.environment["HF_XET_NUM_CONCURRENT_RANGE_GETS"])
    }

    func testInstallSelectedModelUsesConservativeXetEnvironmentWhenConfigured() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let settingsStore = SettingsStore(fileURL: paths.settingsFile)
        try settingsStore.save(DashboardSettings(downloadSettings: .conservativeDefault))
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
        let viewModel = DashboardViewModel(
            settingsStore: settingsStore,
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelInstaller: HuggingFaceModelInstaller(runner: runner),
            authChecker: HuggingFaceAuthChecker(runner: runner)
        )
        viewModel.searchResults = [HuggingFaceModelSummary(id: "mlx-community/Tiny")]
        viewModel.selectedSearchModelID = "mlx-community/Tiny"

        await viewModel.installSelectedModel()

        let installCommands = runner.commands.filter { ($0.arguments.last ?? "").contains("snapshot_download") }
        XCTAssertNil(installCommands.last?.environment["HF_HUB_DISABLE_XET"])
        XCTAssertEqual(installCommands.last?.environment["HF_XET_NUM_CONCURRENT_RANGE_GETS"], "4")
        XCTAssertEqual(installCommands.last?.environment["HF_HUB_DOWNLOAD_TIMEOUT"], "60")
        XCTAssertEqual(installCommands.last?.environment["HF_HUB_ETAG_TIMEOUT"], "30")
    }

    func testInstallSelectedModelFinishesWithCompletedProgress() async throws {
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
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelInstaller: HuggingFaceModelInstaller(runner: runner),
            authChecker: HuggingFaceAuthChecker(runner: runner)
        )
        viewModel.searchResults = [HuggingFaceModelSummary(id: "mlx-community/Tiny")]
        viewModel.selectedSearchModelID = "mlx-community/Tiny"

        await viewModel.installSelectedModel()

        XCTAssertEqual(viewModel.modelInstallProgress?.modelID, "mlx-community/Tiny")
        XCTAssertEqual(viewModel.modelInstallProgress?.phase, .installed)
        XCTAssertEqual(viewModel.modelInstallProgress?.fractionCompleted, 1.0)
        XCTAssertEqual(viewModel.modelInstallProgress?.stepText, "Step 5 of 5")
    }

    func testInstallSelectedModelShowsDownloadActivityFromInstaller() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "whoami": CommandResult(exitCode: 0, standardOutput: #"{"name":"octocat"}"#, standardError: ""),
            "install": CommandResult(
                exitCode: 0,
                standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
                standardError: "MLXDashboard: Started Hugging Face snapshot download for mlx-community/Tiny"
            )
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelInstaller: HuggingFaceModelInstaller(runner: runner),
            authChecker: HuggingFaceAuthChecker(runner: runner),
            huggingFaceCacheRoot: paths.applicationSupport.appending(path: "hub", directoryHint: .isDirectory)
        )
        viewModel.searchResults = [HuggingFaceModelSummary(id: "mlx-community/Tiny")]
        viewModel.selectedSearchModelID = "mlx-community/Tiny"

        await viewModel.installSelectedModel()
        await Task.yield()

        XCTAssertTrue(viewModel.modelInstallProgress?.activities.contains {
            $0.message == "Started Hugging Face snapshot download for mlx-community/Tiny"
        } == true)
    }

    func testLateDownloadProgressDoesNotRegressInstalledProgressPhase() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = LateOutputCommandRunner(
            lateOutput: "model.safetensors:  42%|####      | 4.20G/10.0G [05:10<07:12, 13.4MB/s]\n"
        )
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelInstaller: HuggingFaceModelInstaller(runner: runner),
            authChecker: HuggingFaceAuthChecker(runner: runner),
            huggingFaceCacheRoot: paths.applicationSupport.appending(path: "hub", directoryHint: .isDirectory)
        )
        viewModel.searchResults = [HuggingFaceModelSummary(id: "mlx-community/Tiny")]
        viewModel.selectedSearchModelID = "mlx-community/Tiny"

        await viewModel.installSelectedModel()
        await runner.waitForLateOutput()
        await Task.yield()

        XCTAssertEqual(viewModel.modelInstallProgress?.phase, .installed)
        XCTAssertEqual(viewModel.modelInstallProgress?.downloadStatusText, nil)
    }

    func testLateDownloadActivityDoesNotAppendAfterInstallCompletes() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = LateOutputCommandRunner(
            lateOutput: "MLXDashboard: Late Hugging Face snapshot event\n"
        )
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelInstaller: HuggingFaceModelInstaller(runner: runner),
            authChecker: HuggingFaceAuthChecker(runner: runner),
            huggingFaceCacheRoot: paths.applicationSupport.appending(path: "hub", directoryHint: .isDirectory)
        )
        viewModel.searchResults = [HuggingFaceModelSummary(id: "mlx-community/Tiny")]
        viewModel.selectedSearchModelID = "mlx-community/Tiny"

        await viewModel.installSelectedModel()
        await runner.waitForLateOutput()
        await Task.yield()

        XCTAssertEqual(viewModel.modelInstallProgress?.phase, .installed)
        XCTAssertFalse(viewModel.modelInstallProgress?.activities.contains {
            $0.message == "Late Hugging Face snapshot event"
        } == true)
    }

    func testDownloadProgressUsesTransferPercentETAAndRate() {
        let progress = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .downloading,
            detail: "Downloading mlx-community/Tiny.",
            downloadProgress: HuggingFaceDownloadProgress(
                fractionCompleted: 0.42,
                percentText: "42%",
                etaText: "7m 12s",
                rateText: "13.4MB/s"
            )
        )

        XCTAssertEqual(progress.fractionCompleted, 0.42, accuracy: 0.001)
        XCTAssertEqual(progress.downloadStatusText, "42% • ETA 7m 12s • 13.4MB/s")
    }

    func testDownloadProgressShowsCalculatingETAWhenNoReliableETAExists() {
        let progress = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .downloading,
            detail: "Downloading mlx-community/Tiny.",
            downloadProgress: HuggingFaceDownloadProgress(
                fractionCompleted: 0.42,
                percentText: "42%",
                etaText: nil,
                rateText: "13.4MB/s"
            )
        )

        XCTAssertEqual(progress.downloadStatusText, "42% • Calculating ETA • 13.4MB/s")
    }

    func testDownloadProgressShowsWaitingStatusBeforeReliableTransferProgress() {
        let progress = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .downloading,
            detail: "Downloading mlx-community/Tiny."
        )

        XCTAssertTrue(progress.isWaitingForDownloadData)
        XCTAssertEqual(progress.downloadStatusText, "Waiting for download data")
    }

    func testModelInstallProgressExposesCacheAndActivityStatusText() {
        let progress = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .downloading,
            detail: "Downloading.",
            cacheSummary: DownloadCacheSummary(
                totalBytes: 33 * 1024 * 1024,
                incompleteBlobCount: 3,
                pendingFileNames: ["a.incomplete", "b.incomplete", "c.incomplete"],
                secondsSinceGrowth: 45
            ),
            activities: [
                HuggingFaceDownloadActivity(message: "Xet transfer: connection struggling, concurrency reduced", tone: .warning, source: .xetLog)
            ]
        )

        XCTAssertEqual(progress.cacheStatusText, "Cache 33 MB • 3 incomplete blobs • no growth for 45s")
        XCTAssertEqual(progress.activityMessages, ["Xet transfer: connection struggling, concurrency reduced"])
    }

    func testModelInstallProgressSuggestsNonXetRetryForStalledXetDownloads() {
        let progress = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .downloading,
            detail: "Downloading.",
            cacheSummary: DownloadCacheSummary(
                totalBytes: 33 * 1024 * 1024,
                incompleteBlobCount: 3,
                pendingFileNames: ["a.incomplete", "b.incomplete", "c.incomplete"],
                secondsSinceGrowth: 75
            ),
            activities: [
                HuggingFaceDownloadActivity(message: "Xet transfer: connection struggling, concurrency reduced", tone: .warning, source: .xetLog)
            ]
        )

        XCTAssertEqual(progress.xetFallbackHint, "Xet download is stalled. Pause, then retry without Xet.")
    }

    func testModelInstallProgressHidesActivityStatusTextOutsideDownloading() {
        let progress = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .installed,
            detail: "Installed.",
            activities: [
                HuggingFaceDownloadActivity(message: "Xet transfer: connection struggling", tone: .warning, source: .xetLog)
            ]
        )

        XCTAssertEqual(progress.activityMessages, [])
        XCTAssertEqual(progress.activityRows, [])
    }

    func testModelInstallProgressActivityRowsKeepDuplicateMessagesDistinct() {
        let progress = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .downloading,
            detail: "Downloading.",
            activities: [
                HuggingFaceDownloadActivity(message: "Retrying transfer", tone: .warning, source: .xetLog),
                HuggingFaceDownloadActivity(message: "Retrying transfer", tone: .warning, source: .xetLog)
            ]
        )

        XCTAssertEqual(progress.activityRows.map(\.message), ["Retrying transfer", "Retrying transfer"])
        XCTAssertNotEqual(progress.activityRows[0].id, progress.activityRows[1].id)
    }

    func testModelInstallProgressCapsActivityToLatestFiveEntries() {
        var progress = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .downloading,
            detail: "Downloading."
        )

        for index in 1...6 {
            progress = progress.appendingActivity(
                HuggingFaceDownloadActivity(message: "event \(index)", tone: .info, source: .commandOutput)
            )
        }

        XCTAssertEqual(progress.activities.map(\.message), ["event 2", "event 3", "event 4", "event 5", "event 6"])
    }

    func testInstallSelectedModelFinishesWithFailedProgress() async throws {
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
            "install": CommandResult(exitCode: 1, standardOutput: "", standardError: "download failed")
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelInstaller: HuggingFaceModelInstaller(runner: runner),
            authChecker: HuggingFaceAuthChecker(runner: runner)
        )
        viewModel.searchResults = [HuggingFaceModelSummary(id: "mlx-community/Tiny")]
        viewModel.selectedSearchModelID = "mlx-community/Tiny"

        await viewModel.installSelectedModel()

        XCTAssertEqual(viewModel.modelInstallProgress?.modelID, "mlx-community/Tiny")
        XCTAssertEqual(viewModel.modelInstallProgress?.phase, .failed)
        XCTAssertEqual(viewModel.modelInstallProgress?.fractionCompleted, 1.0)
        XCTAssertTrue(viewModel.modelInstallProgress?.detail.contains("download failed") == true)
    }

    func testContinueLastModelInstallRetriesFailedModelID() async throws {
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
                standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/resumed"}"#,
                standardError: ""
            )
        ])
        let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
        registry.upsert(ModelRecord(id: "mlx-community/Tiny", status: .failed, message: "network interrupted"))
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelInstaller: HuggingFaceModelInstaller(runner: runner),
            authChecker: HuggingFaceAuthChecker(runner: runner)
        )
        viewModel.modelInstallProgress = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .failed,
            detail: "Install failed for mlx-community/Tiny: network interrupted"
        )

        await viewModel.continueLastModelInstall()

        let installCommands = runner.commands.filter { ($0.arguments.last ?? "").contains("snapshot_download") }
        XCTAssertEqual(installCommands.count, 1)
        XCTAssertEqual(installCommands.last?.environment["HF_HUB_DISABLE_XET"], "1")
        XCTAssertNil(installCommands.last?.environment["HF_XET_NUM_CONCURRENT_RANGE_GETS"])
        XCTAssertEqual(registry.record(id: "mlx-community/Tiny")?.status, .installed)
        XCTAssertEqual(viewModel.modelInstallProgress?.phase, .installed)
        XCTAssertEqual(viewModel.modelInstallMessage, "Installed mlx-community/Tiny at /tmp/cache/models--mlx-community--Tiny/snapshots/resumed")
    }

    func testContinueSelectedInstalledModelRetriesFailedRecord() async throws {
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
                standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/resumed"}"#,
                standardError: ""
            )
        ])
        let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
        registry.upsert(ModelRecord(id: "mlx-community/Tiny", status: .failed, message: "network interrupted"))
        try registry.save()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelInstaller: HuggingFaceModelInstaller(runner: runner),
            authChecker: HuggingFaceAuthChecker(runner: runner)
        )
        viewModel.selectedInstalledModelID = "mlx-community/Tiny"

        await viewModel.continueSelectedInstalledModelInstall()

        XCTAssertEqual(registry.record(id: "mlx-community/Tiny")?.status, .installed)
        XCTAssertEqual(viewModel.modelInstallProgress?.phase, .installed)
    }

    func testRetryLastModelInstallWithoutXetDisablesXetForInstallCommand() async throws {
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
                standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/resumed"}"#,
                standardError: ""
            )
        ])
        let settingsStore = SettingsStore(fileURL: paths.settingsFile)
        try settingsStore.save(DashboardSettings(downloadSettings: .conservativeDefault))
        let viewModel = DashboardViewModel(
            settingsStore: settingsStore,
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelInstaller: HuggingFaceModelInstaller(runner: runner),
            authChecker: HuggingFaceAuthChecker(runner: runner)
        )
        viewModel.modelInstallProgress = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .failed,
            detail: "Install failed for mlx-community/Tiny: network interrupted"
        )

        await viewModel.retryLastModelInstallWithoutXet()

        let installCommands = runner.commands.filter { ($0.arguments.last ?? "").contains("snapshot_download") }
        XCTAssertEqual(installCommands.last?.environment["HF_HUB_DISABLE_XET"], "1")
        XCTAssertNil(installCommands.last?.environment["HF_XET_NUM_CONCURRENT_RANGE_GETS"])
        XCTAssertEqual(viewModel.modelInstallProgress?.phase, .installed)
    }

    func testPauseActiveModelInstallMarksDownloadPausedAndAllowsContinue() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = PausingCommandRunner()
        let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelInstaller: HuggingFaceModelInstaller(runner: runner),
            authChecker: HuggingFaceAuthChecker(runner: runner)
        )
        viewModel.searchResults = [HuggingFaceModelSummary(id: "mlx-community/Tiny")]
        viewModel.selectedSearchModelID = "mlx-community/Tiny"

        viewModel.startSelectedModelInstall()
        await runner.waitForInstallStart()

        XCTAssertTrue(viewModel.hasRunningDownloads)

        viewModel.pauseActiveModelInstall()
        await runner.waitForInstallCancellation()

        XCTAssertFalse(viewModel.hasRunningDownloads)
        XCTAssertTrue(runner.wasInstallCancelled)
        XCTAssertEqual(viewModel.modelInstallProgress?.phase, .paused)
        XCTAssertEqual(registry.record(id: "mlx-community/Tiny")?.status, .paused)
        XCTAssertTrue(viewModel.canContinueLastModelInstall)
    }

    func testDownloadCacheSamplerReportsSizeAndIncompleteBlobs() throws {
        let root = try temporaryDirectory()
        let repo = root.appending(path: "models--mlx-community--Tiny", directoryHint: .isDirectory)
        let blobs = repo.appending(path: "blobs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: blobs.appending(path: "complete").path, contents: Data(repeating: 1, count: 4))
        FileManager.default.createFile(atPath: blobs.appending(path: "weights.safetensors.incomplete").path, contents: Data())

        let summary = try DownloadCacheSampler().summary(modelID: "mlx-community/Tiny", cacheRoot: root)

        XCTAssertEqual(summary.incompleteBlobCount, 1)
        XCTAssertEqual(summary.pendingFileNames, ["weights.safetensors.incomplete"])
        XCTAssertGreaterThanOrEqual(summary.totalBytes, 4)
    }

    func testDownloadCacheSummaryFormatsQuietStatus() {
        let summary = DownloadCacheSummary(
            totalBytes: 33 * 1024 * 1024,
            incompleteBlobCount: 3,
            pendingFileNames: ["a.incomplete", "b.incomplete", "c.incomplete"],
            secondsSinceGrowth: 45
        )

        XCTAssertEqual(summary.statusText, "Cache 33 MB • 3 incomplete blobs • no growth for 45s")
    }

    func testXetLogActivityReaderClassifiesConnectionStrugglingMessages() throws {
        let root = try temporaryDirectory()
        let logs = root.appending(path: "xet/logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appending(path: "xet_20260612.log")
        try #"{"fields":{"message":"Concurrency control for download: Decreased concurrency from 2 to 1; reason: success ratio below threshold (connection struggling)"}}"#
            .write(to: log, atomically: true, encoding: .utf8)

        let activities = try XetLogActivityReader().activities(logRoot: logs)

        XCTAssertEqual(activities, [
            HuggingFaceDownloadActivity(
                message: "Xet transfer: connection struggling, concurrency reduced",
                tone: .warning,
                source: .xetLog
            )
        ])
    }

    func testXetLogActivityReaderIgnoresNewerBadEntriesAndReadsOlderLog() throws {
        let root = try temporaryDirectory()
        let logs = root.appending(path: "xet/logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let validLog = logs.appending(path: "xet_20260612.log")
        try #"{"fields":{"message":"Concurrency control for download: Decreased concurrency from 2 to 1; reason: success ratio below threshold (connection struggling)"}}"#
            .write(to: validLog, atomically: true, encoding: .utf8)

        let newerDirectory = logs.appending(path: "newer.log", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: newerDirectory, withIntermediateDirectories: true)
        let badLog = logs.appending(path: "bad.log")
        try Data([0xff, 0xfe, 0xfd]).write(to: badLog)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: validLog.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newerDirectory.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 300)],
            ofItemAtPath: badLog.path
        )

        let activities = try XetLogActivityReader().activities(logRoot: logs)

        XCTAssertEqual(activities, [
            HuggingFaceDownloadActivity(
                message: "Xet transfer: connection struggling, concurrency reduced",
                tone: .warning,
                source: .xetLog
            )
        ])
    }

    func testSetSelectedInstalledModelActiveSavesSettings() throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
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

    func testSetSelectedInstallingModelActiveKeepsDownloadProgress() throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )
        let progress = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .downloading,
            detail: "Downloading model files"
        )
        viewModel.installedModels = [
            ModelRecord(id: "mlx-community/Tiny", status: .installing, message: "Installing from Hugging Face")
        ]
        viewModel.selectedInstalledModelID = "mlx-community/Tiny"
        viewModel.modelInstallProgress = progress

        XCTAssertFalse(viewModel.canSetSelectedInstalledModelActive)
        XCTAssertFalse(viewModel.canAssignSelectedInstalledModelToProviderRole)

        viewModel.setSelectedInstalledModelActive()

        XCTAssertNil(viewModel.settings.activeModel)
        XCTAssertEqual(viewModel.modelInstallProgress, progress)
        XCTAssertEqual(viewModel.modelInstallMessage, "Select an installed model before setting it active.")
    }

    func testAssignSelectedInstalledModelToProviderRolePersistsSettings() throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )
        viewModel.installedModels = [
            ModelRecord(id: "mlx-community/Tiny", status: .installed, localPath: "/tmp/tiny")
        ]
        viewModel.selectedInstalledModelID = "mlx-community/Tiny"

        viewModel.assignSelectedInstalledModel(to: .coding)

        XCTAssertEqual(viewModel.settings.providerRoleAssignments.coding, "mlx-community/Tiny")
        XCTAssertEqual(try SettingsStore(fileURL: paths.settingsFile).load().providerRoleAssignments.coding, "mlx-community/Tiny")
        XCTAssertEqual(viewModel.modelInstallMessage, "Assigned mlx-community/Tiny to Fast/Coding.")
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
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:])),
            huggingFaceCacheRoot: cacheRoot
        )
        viewModel.selectedInstalledModelID = "mlx-community/Tiny"

        viewModel.deleteSelectedInstalledModelFromCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appending(path: "models--mlx-community--Tiny").path))
        XCTAssertEqual(registry.record(id: "mlx-community/Tiny")?.status, .removed)
        XCTAssertFalse(viewModel.installedModels.contains(where: { $0.id == "mlx-community/Tiny" }))
        XCTAssertEqual(viewModel.modelInstallMessage, "Deleted cache for mlx-community/Tiny.")
    }

    func testDeleteSelectedInstalledModelClearsStaleInstallProgress() throws {
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
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:])),
            huggingFaceCacheRoot: cacheRoot
        )
        viewModel.selectedInstalledModelID = "mlx-community/Tiny"
        viewModel.modelInstallProgress = ModelInstallProgress(
            modelID: "mlx-community/Previous",
            phase: .installed,
            detail: "Installed previous model"
        )

        viewModel.deleteSelectedInstalledModelFromCache()

        XCTAssertNil(viewModel.modelInstallProgress)
        XCTAssertEqual(viewModel.modelInstallMessage, "Deleted cache for mlx-community/Tiny.")
    }

    func testDeleteSelectedInstalledModelClearsMatchingProviderRoleAssignments() throws {
        let paths = try temporaryAppPaths()
        try SettingsStore(fileURL: paths.settingsFile).save(
            DashboardSettings(
                providerRoleAssignments: ProviderRoleAssignments(
                    ask: "mlx-community/Tiny",
                    plan: "mlx-community/Plan",
                    coding: "mlx-community/Tiny"
                )
            )
        )
        let cacheRoot = try temporaryDirectory()
        let snapshot = cacheRoot.appending(path: "models--mlx-community--Tiny/snapshots/abc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: snapshot.appending(path: "config.json").path, contents: Data())

        let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
        registry.upsert(ModelRecord(id: "mlx-community/Tiny", status: .installed, localPath: snapshot.path))
        try registry.save()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:])),
            huggingFaceCacheRoot: cacheRoot
        )
        viewModel.selectedInstalledModelID = "mlx-community/Tiny"

        viewModel.deleteSelectedInstalledModelFromCache()

        XCTAssertNil(viewModel.settings.providerRoleAssignments.ask)
        XCTAssertEqual(viewModel.settings.providerRoleAssignments.plan, "mlx-community/Plan")
        XCTAssertNil(viewModel.settings.providerRoleAssignments.coding)
        let persisted = try SettingsStore(fileURL: paths.settingsFile).load().providerRoleAssignments
        XCTAssertNil(persisted.ask)
        XCTAssertEqual(persisted.plan, "mlx-community/Plan")
        XCTAssertNil(persisted.coding)
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

    private static func modelListJSON(count: Int) -> String {
        let models = (1...count).map { index in
            #"{"id":"mlx-community/Model-\#(index)","downloads":\#(1000 - index),"likes":\#(index)}"#
        }
        return "[\(models.joined(separator: ","))]"
    }

    private static func modelIDs(in data: Data) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = object?["data"] as? [[String: Any]]
        return models?.compactMap { $0["id"] as? String } ?? []
    }
}

private final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    private(set) var commands: [Command] = []
    let results: [String: CommandResult]
    let thrownErrors: [String: Error]

    init(results: [String: CommandResult], thrownErrors: [String: Error] = [:]) {
        self.results = results
        self.thrownErrors = thrownErrors
    }

    func run(_ command: Command) async throws -> CommandResult {
        commands.append(command)
        let script = command.arguments.last ?? ""
        let key: String
        if script.contains("snapshot_download") {
            key = "install"
        } else if script.contains("whoami") {
            key = "whoami"
        } else if script.contains("list_models") {
            if script.contains("limit=50"), results["search-limit-50"] != nil {
                key = "search-limit-50"
            } else if script.contains("limit=100"), results["search-limit-100"] != nil {
                key = "search-limit-100"
            } else {
                key = "search"
            }
        } else {
            key = script
        }
        if let error = thrownErrors[key] {
            throw error
        }
        return results[key] ?? CommandResult(exitCode: 127, standardOutput: "", standardError: "unexpected command \(key)")
    }
}

private final class LateOutputCommandRunner: CommandRunning, @unchecked Sendable {
    private let lateOutput: String
    private let lock = NSLock()
    private var lateOutputEmitted = false
    private var lateOutputContinuation: CheckedContinuation<Void, Never>?

    init(lateOutput: String) {
        self.lateOutput = lateOutput
    }

    func run(_ command: Command) async throws -> CommandResult {
        let script = command.arguments.last ?? ""
        if script.contains("whoami") {
            return CommandResult(exitCode: 0, standardOutput: #"{"name":"octocat"}"#, standardError: "")
        }
        if script.contains("import mlx_lm") || script.contains("import huggingface_hub") {
            return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        return CommandResult(exitCode: 127, standardOutput: "", standardError: "unexpected command")
    }

    func run(_ command: Command, outputHandler: CommandOutputHandler?) async throws -> CommandResult {
        let script = command.arguments.last ?? ""
        guard script.contains("snapshot_download") else {
            return try await run(command)
        }

        if let outputHandler {
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000)
                outputHandler(lateOutput)
                markLateOutputEmitted()
            }
        } else {
            markLateOutputEmitted()
        }

        return CommandResult(
            exitCode: 0,
            standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
            standardError: ""
        )
    }

    func waitForLateOutput() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if lateOutputEmitted {
                    continuation.resume()
                } else {
                    lateOutputContinuation = continuation
                }
            }
        }
    }

    private func markLateOutputEmitted() {
        let continuation = lock.withLock {
            lateOutputEmitted = true
            let continuation = lateOutputContinuation
            lateOutputContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class PausingCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var installStarted = false
    private var installCancelled = false

    var wasInstallCancelled: Bool {
        lock.withLock { installCancelled }
    }

    func run(_ command: Command) async throws -> CommandResult {
        let script = command.arguments.last ?? ""
        if script.contains("snapshot_download") {
            lock.withLock {
                installStarted = true
            }
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return CommandResult(
                    exitCode: 0,
                    standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
                    standardError: ""
                )
            } catch {
                lock.withLock {
                    installCancelled = true
                }
                throw CancellationError()
            }
        }
        if script.contains("whoami") {
            return CommandResult(exitCode: 0, standardOutput: #"{"name":"octocat"}"#, standardError: "")
        }
        if script.contains("import mlx_lm") || script.contains("import huggingface_hub") {
            return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        return CommandResult(exitCode: 127, standardOutput: "", standardError: "unexpected command")
    }

    func waitForInstallStart() async {
        await waitUntil { self.lock.withLock { self.installStarted } }
    }

    func waitForInstallCancellation() async {
        await waitUntil { self.lock.withLock { self.installCancelled } }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class FakeManagedProcess: ManagedProcess {
    var executableURL: URL?
    var arguments: [String] = []
    var environment: [String: String]?
    var wasLaunched = false
    var wasTerminated = false
    var isRunning = false

    func launch() throws {
        wasLaunched = true
        isRunning = true
    }

    func terminate() {
        wasTerminated = true
        isRunning = false
    }
}

private final class FakeProcessLauncher: ProcessLaunching {
    private var processes: [FakeManagedProcess]

    init(processes: [FakeManagedProcess]) {
        self.processes = processes
    }

    func makeProcess() -> ManagedProcess {
        processes.removeFirst()
    }
}

private struct FakePortChecker: ServerPortChecking {
    let isAvailable: Bool

    func isPortAvailable(host: String, port: Int) -> Bool {
        isAvailable
    }
}
