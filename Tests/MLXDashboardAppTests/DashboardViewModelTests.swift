import XCTest
import Combine
import MLXCore
import MLXPythonBridge
import MLXProviderServer
import MLXServerControl
@testable import MLXDashboardApp

@MainActor
final class DashboardViewModelTests: XCTestCase {
    func testAppLaunchOptionsEnableAutostartProvider() {
        XCTAssertTrue(AppLaunchOptions(arguments: ["MLXDashboard", "--autostart-provider"]).autostartProvider)
        XCTAssertTrue(AppLaunchOptions(arguments: ["MLXDashboard", "--autostart"]).autostartProvider)
        XCTAssertFalse(AppLaunchOptions(arguments: ["MLXDashboard"]).autostartProvider)
    }

    func testDashboardRecentLogsUseExpandedMinimumHeight() {
        XCTAssertEqual(DashboardLayoutPolicy.activeModelMinHeight, 240)
        XCTAssertEqual(DashboardLayoutPolicy.recentLogsMinHeight, 360)
        XCTAssertEqual(DashboardLayoutPolicy.recentLogsVisibleLimit, 24)
    }

    func testDashboardSectionDefaultsToDashboardLandingView() {
        XCTAssertEqual(DashboardSection.defaultSelection, .dashboard)
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

    func testRoleServerStatusTablePolicyStopsOnlyNonDefaultRoleEndpoints() {
        let defaultEndpoint = RoleServerEndpoint(
            modelID: "base",
            port: 8080,
            baseURL: URL(string: "http://127.0.0.1:8080")!
        )
        let nonDefaultEndpoint = RoleServerEndpoint(
            modelID: "plan",
            port: 8081,
            baseURL: URL(string: "http://127.0.0.1:8081")!
        )

        let fallbackRow = RoleServerStatusRow(
            role: .plan,
            assignedModel: "plan",
            endpoint: defaultEndpoint,
            kind: .fallback,
            detail: "Using active model"
        )
        let defaultSharedRow = RoleServerStatusRow(
            role: .ask,
            assignedModel: "base",
            endpoint: defaultEndpoint,
            kind: .shared,
            detail: "Shared on port 8080"
        )
        let sharedRoleRow = RoleServerStatusRow(
            role: .coding,
            assignedModel: "plan",
            endpoint: nonDefaultEndpoint,
            kind: .shared,
            detail: "Shared on port 8081"
        )

        XCTAssertFalse(RoleServerStatusTablePolicy.canStop(fallbackRow, defaultEndpoint: defaultEndpoint))
        XCTAssertFalse(RoleServerStatusTablePolicy.canStop(defaultSharedRow, defaultEndpoint: defaultEndpoint))
        XCTAssertTrue(RoleServerStatusTablePolicy.canStop(sharedRoleRow, defaultEndpoint: defaultEndpoint))
    }

    func testRoleServerStatusTablePolicyRestartsOnlyNonDefaultRunningOwnerEndpoints() {
        let defaultEndpoint = RoleServerEndpoint(
            modelID: "base",
            port: 8080,
            baseURL: URL(string: "http://127.0.0.1:8080")!
        )
        let nonDefaultEndpoint = RoleServerEndpoint(
            modelID: "plan",
            port: 8081,
            baseURL: URL(string: "http://127.0.0.1:8081")!
        )

        let fallbackRow = RoleServerStatusRow(
            role: .plan,
            assignedModel: "plan",
            endpoint: defaultEndpoint,
            kind: .fallback,
            detail: "Using active model"
        )
        let defaultSharedRow = RoleServerStatusRow(
            role: .ask,
            assignedModel: "base",
            endpoint: defaultEndpoint,
            kind: .shared,
            detail: "Shared on port 8080"
        )
        let sharedRoleRow = RoleServerStatusRow(
            role: .coding,
            assignedModel: "plan",
            endpoint: nonDefaultEndpoint,
            kind: .shared,
            detail: "Shared on port 8081"
        )
        let runningRoleRow = RoleServerStatusRow(
            role: .plan,
            assignedModel: "plan",
            endpoint: nonDefaultEndpoint,
            kind: .running,
            detail: "Running on port 8081"
        )

        XCTAssertFalse(RoleServerStatusTablePolicy.canRestart(fallbackRow, defaultEndpoint: defaultEndpoint))
        XCTAssertFalse(RoleServerStatusTablePolicy.canRestart(defaultSharedRow, defaultEndpoint: defaultEndpoint))
        XCTAssertFalse(RoleServerStatusTablePolicy.canRestart(sharedRoleRow, defaultEndpoint: defaultEndpoint))
        XCTAssertTrue(RoleServerStatusTablePolicy.canRestart(runningRoleRow, defaultEndpoint: defaultEndpoint))
    }

    func testControllerAvailabilityRefreshesWhenServerStateChanges() throws {
        let paths = try temporaryAppPaths()
        let process = FakeManagedProcess()
        let serverPoolController = RoleServerPoolController(
            processLauncher: FakeProcessLauncher(processes: [process]),
            portChecker: FakePortChecker(isAvailable: true),
            healthChecker: FakeHealthChecker()
        )
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:])),
            serverPoolController: serverPoolController
        )
        var refreshCount = 0
        let cancellable = viewModel.objectWillChange.sink {
            refreshCount += 1
        }

        XCTAssertTrue(viewModel.canStartServer)
        XCTAssertFalse(viewModel.canStopServer)
        XCTAssertFalse(viewModel.canRestartServer)

        try serverPoolController.start(settings: DashboardSettings(), pythonExecutable: URL(filePath: "/venv/bin/python"))

        XCTAssertFalse(viewModel.canStartServer)
        XCTAssertTrue(viewModel.canStopServer)
        XCTAssertFalse(viewModel.canRestartServer)
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
        let serverPoolController = RoleServerPoolController(
            processLauncher: FakeProcessLauncher(processes: [originalProcess, restartedProcess]),
            portChecker: FakePortChecker(isAvailable: true),
            healthChecker: FakeHealthChecker()
        )
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [
                "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
                "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            ])),
            serverPoolController: serverPoolController
        )

        try serverPoolController.start(settings: DashboardSettings(), pythonExecutable: python)
        let ready = await serverPoolController.waitUntilReady(timeout: 0.1, pollInterval: 0.05)
        XCTAssertTrue(ready)
        await viewModel.restartServer()

        XCTAssertTrue(originalProcess.wasTerminated)
        XCTAssertTrue(restartedProcess.wasLaunched)
        XCTAssertEqual(serverPoolController.state, .running)
    }

    func testStartServerLogsFriendlyMessageWhenMLXPortIsUnavailable() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())
        let process = FakeManagedProcess()
        let serverPoolController = RoleServerPoolController(
            processLauncher: FakeProcessLauncher(processes: [process]),
            portChecker: FakePortChecker(unavailablePorts: [DashboardSettings().mlxPort]),
            healthChecker: FakeHealthChecker()
        )
        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            serverPoolController: serverPoolController
        )

        await viewModel.startServer()

        XCTAssertEqual(serverPoolController.state, .failed)
        XCTAssertFalse(process.wasLaunched)
        let logText = try String(contentsOf: paths.logsDirectory.appending(path: "mlxdashboard.log"), encoding: .utf8)
        XCTAssertTrue(logText.contains("Failed to start server: Cannot start the model runtime because 127.0.0.1:8080 is already in use."))
    }

    func testStartServerStartsUniqueRoleServerPoolProcesses() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let gemma = FakeManagedProcess()
        let devstral = FakeManagedProcess()
        let serverPoolController = RoleServerPoolController(
            processLauncher: FakeProcessLauncher(processes: [gemma, devstral]),
            portChecker: FakePortChecker(isAvailable: true),
            healthChecker: FakeHealthChecker()
        )
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [
                "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
                "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            ])),
            serverPoolController: serverPoolController
        )
        viewModel.settings.activeModel = "mlx-community/gemma4"
        viewModel.settings.providerPort = 0
        viewModel.settings.providerRoleAssignments = ProviderRoleAssignments(
            ask: "mlx-community/gemma4",
            plan: "mlx-community/devstral",
            coding: "mlx-community/gemma4"
        )

        await viewModel.startServer()
        defer {
            viewModel.stopProvider()
            viewModel.stopServer()
        }

        let expectedKinds: [RoleServerStatusKind] = [.shared, .running, .shared]
        XCTAssertEqual(serverPoolController.state, .running)
        XCTAssertTrue(gemma.wasLaunched)
        XCTAssertTrue(devstral.wasLaunched)
        XCTAssertEqual(viewModel.roleServerStatuses.map(\.kind), expectedKinds)
        XCTAssertEqual(serverPoolController.processesByPort.count, 2)
    }

    func testStopServerStopsRoleServerPoolProcesses() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let gemma = FakeManagedProcess()
        let devstral = FakeManagedProcess()
        let serverPoolController = RoleServerPoolController(
            processLauncher: FakeProcessLauncher(processes: [gemma, devstral]),
            portChecker: FakePortChecker(isAvailable: true),
            healthChecker: FakeHealthChecker()
        )
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [
                "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
                "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            ])),
            serverPoolController: serverPoolController
        )
        viewModel.settings.activeModel = "mlx-community/gemma4"
        viewModel.settings.providerPort = 0
        viewModel.settings.providerRoleAssignments = ProviderRoleAssignments(
            ask: "mlx-community/gemma4",
            plan: "mlx-community/devstral",
            coding: "mlx-community/gemma4"
        )

        await viewModel.startServer()
        viewModel.stopProvider()
        viewModel.stopServer()

        let expectedKinds: [RoleServerStatusKind] = [.unassigned, .unassigned, .unassigned]
        XCTAssertEqual(serverPoolController.state, .stopped)
        XCTAssertTrue(gemma.wasTerminated)
        XCTAssertTrue(devstral.wasTerminated)
        XCTAssertEqual(viewModel.roleServerStatuses.map(\.kind), expectedKinds)
    }

    func testStopRoleServerStopsOnlySelectedRoleProcess() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let base = FakeManagedProcess()
        let ask = FakeManagedProcess()
        let serverPoolController = RoleServerPoolController(
            processLauncher: FakeProcessLauncher(processes: [base, ask]),
            portChecker: FakePortChecker(isAvailable: true),
            healthChecker: FakeHealthChecker()
        )
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [
                "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
                "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            ])),
            serverPoolController: serverPoolController
        )
        viewModel.settings.activeModel = "base"
        viewModel.settings.providerRoleAssignments = ProviderRoleAssignments(ask: "ask")

        await viewModel.startServer()
        viewModel.stopRoleServer(.ask)

        XCTAssertTrue(ask.wasTerminated)
        XCTAssertFalse(base.wasTerminated)
        XCTAssertNil(serverPoolController.endpoint(for: .ask))
        XCTAssertEqual(viewModel.roleServerStatuses, serverPoolController.roleStatuses)
        XCTAssertEqual(viewModel.roleServerStatuses.first(where: { $0.role == .ask })?.kind, .fallback)
    }

    func testRestartRoleServerRestartsStoppedRoleProcess() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let base = FakeManagedProcess()
        let originalAsk = FakeManagedProcess()
        let restartedAsk = FakeManagedProcess()
        let serverPoolController = RoleServerPoolController(
            processLauncher: FakeProcessLauncher(processes: [base, originalAsk, restartedAsk]),
            portChecker: FakePortChecker(isAvailable: true),
            healthChecker: FakeHealthChecker()
        )
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [
                "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
                "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            ])),
            serverPoolController: serverPoolController
        )
        viewModel.settings.activeModel = "base"
        viewModel.settings.providerRoleAssignments = ProviderRoleAssignments(ask: "ask")

        await viewModel.startServer()
        viewModel.stopRoleServer(.ask)
        await viewModel.restartRoleServer(.ask)

        XCTAssertTrue(originalAsk.wasTerminated)
        XCTAssertTrue(restartedAsk.wasLaunched)
        XCTAssertEqual(viewModel.roleServerStatuses, serverPoolController.roleStatuses)
        XCTAssertEqual(viewModel.roleServerStatuses.first(where: { $0.role == .ask })?.kind, .running)
        XCTAssertEqual(serverPoolController.endpoint(for: .ask)?.port, 8081)
    }

    func testRestartRoleServerLogsFailureWhenRolePortIsUnavailable() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let portChecker = MutableFakePortChecker()
        let base = FakeManagedProcess()
        let ask = FakeManagedProcess()
        let serverPoolController = RoleServerPoolController(
            processLauncher: FakeProcessLauncher(processes: [base, ask]),
            portChecker: portChecker,
            healthChecker: FakeHealthChecker()
        )
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [
                "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
                "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: "")
            ])),
            serverPoolController: serverPoolController
        )
        viewModel.settings.activeModel = "base"
        viewModel.settings.providerRoleAssignments = ProviderRoleAssignments(ask: "ask")

        await viewModel.startServer()
        viewModel.stopRoleServer(.ask)
        portChecker.unavailablePorts = [8081]

        await viewModel.restartRoleServer(.ask)

        XCTAssertEqual(serverPoolController.status(for: .ask).kind, .fallback)
        XCTAssertNil(serverPoolController.endpoint(for: .ask))

        let logText = try String(contentsOf: paths.logsDirectory.appending(path: "mlxdashboard.log"), encoding: .utf8)
        XCTAssertTrue(logText.contains("Could not restart Ask role server: Port 8081 unavailable; using active model"))
        XCTAssertFalse(logText.contains("Restarted Ask role server"))
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
        let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
        registry.upsert(ModelRecord(id: "mlx-community/Tiny", status: .installed, localPath: "/tmp/tiny"))
        try registry.save()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )
        viewModel.settings.providerPort = 18123

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
        XCTAssertEqual(try Self.modelIDs(in: data), ["mlx-ask", "mlx-plan", "mlx-coding", "mlx-community/Tiny"])
    }

    func testRuntimeCapabilityInspectionMarksNemotronDiffusionUnsupportedInProviderMetadata() async throws {
        let paths = try temporaryAppPaths()
        let ports = try availableTestPorts()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())
        let sitePackages = try temporaryDirectory()
        let cacheRoot = try temporaryDirectory()
        let snapshot = cacheRoot.appending(
            path: "models--mlx-community--Nemotron-Labs-Diffusion-3B-4bit/snapshots/abc",
            directoryHint: .isDirectory
        )
        try createCachedModelSnapshot(at: snapshot, config: #"{"model_type":"nemotron_labs_diffusion"}"#)
        let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
        registry.upsert(ModelRecord(
            id: "mlx-community/Nemotron-Labs-Diffusion-3B-4bit",
            status: .installed,
            localPath: snapshot.path
        ))
        try registry.save()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [
                "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
                "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
                "runtime-capabilities": CommandResult(
                    exitCode: 0,
                    standardOutput: #"{"site_packages":"\#(sitePackages.path)","version":"0.31.3"}"#,
                    standardError: ""
                )
            ])),
            huggingFaceCacheRoot: cacheRoot
        )
        viewModel.settings.providerPort = ports.providerPort

        await viewModel.refreshPythonStatus()
        do {
            try viewModel.startProvider()
        } catch {
            throw XCTSkip("Loopback listener unavailable in this sandbox: \(error)")
        }
        defer { viewModel.stopProvider() }

        let url = URL(string: "http://127.0.0.1:\(ports.providerPort)/provider/v1/models")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let models = try Self.models(in: data)
        let nemotron = try XCTUnwrap(models.first { $0["id"] as? String == "mlx-community/Nemotron-Labs-Diffusion-3B-4bit" })

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(nemotron["generation_type"] as? String, "text")
        XCTAssertEqual(nemotron["model_family"] as? String, "diffusion_text")
        XCTAssertEqual(nemotron["state"] as? String, "unsupported")
        XCTAssertEqual(
            nemotron["unsupported_reason"] as? String,
            "Bundled text diffusion runtime is unavailable for model_type nemotron_labs_diffusion"
        )
    }

    func testRunningProviderUsesActiveModelSavedAfterProviderStart() async throws {
        let paths = try temporaryAppPaths()
        let ports = try availableTestPorts()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )
        viewModel.settings.providerPort = ports.providerPort

        do {
            try viewModel.startProvider()
        } catch {
            throw XCTSkip("Loopback listener unavailable in this sandbox: \(error)")
        }
        defer { viewModel.stopProvider() }

        viewModel.settings.activeModel = "mlx-community/Manual"
        viewModel.saveSettings()

        let v1URL = URL(string: "http://127.0.0.1:\(ports.providerPort)/v1/models")!
        let (v1Data, v1Response) = try await URLSession.shared.data(from: v1URL)

        XCTAssertEqual((v1Response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try Self.modelIDs(in: v1Data), [])

        let v0URL = URL(string: "http://127.0.0.1:\(ports.providerPort)/api/v0/models")!
        let (v0Data, v0Response) = try await URLSession.shared.data(from: v0URL)

        XCTAssertEqual((v0Response as? HTTPURLResponse)?.statusCode, 200)
        let models = try Self.models(in: v0Data)
        let manual = try XCTUnwrap(models.first { $0["id"] as? String == "mlx-community/Manual" })
        XCTAssertEqual(manual["state"] as? String, "not_installed")
        XCTAssertEqual(manual["reason"] as? String, "Model is not installed in the local Hugging Face cache.")
    }

    func testSearchResultActionMarksInstalledModelsFromRegistry() throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )
        viewModel.searchResults = [
            HuggingFaceModelSummary(id: "mlx-community/Tiny"),
            HuggingFaceModelSummary(id: "mlx-community/Other")
        ]
        viewModel.installedModels = [
            ModelRecord(id: "mlx-community/Tiny", status: .installed, localPath: "/tmp/tiny")
        ]
        viewModel.selectedSearchModelID = "mlx-community/Tiny"

        XCTAssertEqual(viewModel.searchResultAction(for: "mlx-community/Tiny"), .alreadyInstalled)
        XCTAssertEqual(viewModel.searchResultAction(for: "mlx-community/Other"), .install)
        XCTAssertFalse(viewModel.canInstallSelectedSearchModel)

        viewModel.selectedSearchModelID = "mlx-community/Other"

        XCTAssertTrue(viewModel.canInstallSelectedSearchModel)
    }

    func testDirectRolePoolStartPublishesEndpointsToRunningProvider() async throws {
        let paths = try temporaryAppPaths()
        let ports = try availableTestPorts()
        let defaultModel = "mlx-community/Gemma"
        let planModel = "mlx-community/Devstral"

        let defaultUpstream = try makeUpstreamServer(modelID: defaultModel, port: ports.mlxPort)
        let planUpstream = try makeUpstreamServer(modelID: planModel, port: ports.planPort)
        defer {
            try? defaultUpstream.stop()
            try? planUpstream.stop()
        }

        let serverPoolController = RoleServerPoolController(
            processLauncher: FakeProcessLauncher(processes: [FakeManagedProcess(), FakeManagedProcess()]),
            portChecker: FakePortChecker(isAvailable: true),
            healthChecker: FakeHealthChecker()
        )
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:])),
            serverPoolController: serverPoolController
        )
        viewModel.settings.mlxPort = ports.mlxPort
        viewModel.settings.providerPort = ports.providerPort
        viewModel.settings.activeModel = defaultModel
        viewModel.settings.providerRoleAssignments = ProviderRoleAssignments(plan: planModel)
        viewModel.saveSettings()

        do {
            try viewModel.startProvider()
        } catch {
            throw XCTSkip("Loopback listener unavailable in this sandbox: \(error)")
        }
        defer { viewModel.stopProvider() }

        let unavailableStatus = try await providerStatusCode(port: ports.providerPort, model: "mlx-plan")
        XCTAssertEqual(unavailableStatus, 503)

        try serverPoolController.start(settings: viewModel.settings, pythonExecutable: URL(filePath: "/venv/bin/python"))
        let ready = await serverPoolController.waitUntilReady(timeout: 0.1, pollInterval: 0.05)
        XCTAssertTrue(ready)
        await Task.yield()

        let routedModel = try await providerResponseModel(port: ports.providerPort, model: "mlx-plan")
        XCTAssertEqual(routedModel, planModel)
    }

    func testDirectRolePoolStopClearsEndpointsFromRunningProvider() async throws {
        let paths = try temporaryAppPaths()
        let ports = try availableTestPorts()
        let defaultModel = "mlx-community/Gemma"
        let planModel = "mlx-community/Devstral"

        let defaultUpstream = try makeUpstreamServer(modelID: defaultModel, port: ports.mlxPort)
        let planUpstream = try makeUpstreamServer(modelID: planModel, port: ports.planPort)
        defer {
            try? defaultUpstream.stop()
            try? planUpstream.stop()
        }

        let serverPoolController = RoleServerPoolController(
            processLauncher: FakeProcessLauncher(processes: [FakeManagedProcess(), FakeManagedProcess()]),
            portChecker: FakePortChecker(isAvailable: true),
            healthChecker: FakeHealthChecker()
        )
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:])),
            serverPoolController: serverPoolController
        )
        viewModel.settings.mlxPort = ports.mlxPort
        viewModel.settings.providerPort = ports.providerPort
        viewModel.settings.activeModel = defaultModel
        viewModel.settings.providerRoleAssignments = ProviderRoleAssignments(plan: planModel)
        viewModel.saveSettings()

        do {
            try viewModel.startProvider()
        } catch {
            throw XCTSkip("Loopback listener unavailable in this sandbox: \(error)")
        }
        defer { viewModel.stopProvider() }

        try serverPoolController.start(settings: viewModel.settings, pythonExecutable: URL(filePath: "/venv/bin/python"))
        let ready = await serverPoolController.waitUntilReady(timeout: 0.1, pollInterval: 0.05)
        XCTAssertTrue(ready)
        await Task.yield()
        let routedModel = try await providerResponseModel(port: ports.providerPort, model: "mlx-plan")
        XCTAssertEqual(routedModel, planModel)

        serverPoolController.stopAll()
        await Task.yield()

        let unavailableStatus = try await providerStatusCode(port: ports.providerPort, model: "mlx-plan")
        XCTAssertEqual(unavailableStatus, 503)
    }

    func testDefaultsModelQueryToEmptyString() throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )

        XCTAssertEqual(viewModel.modelQuery, "")
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
                standardOutput: #"[{"id":"lmstudio-community/Devstral-Small-2505-MLX-4bit","downloads":10036,"likes":7,"model_type":"mistral"}]"#,
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
        XCTAssertTrue(runner.commands.contains { $0.pythonScript?.contains("list_models") == true && $0.arguments.last == "50" })
        XCTAssertEqual(viewModel.modelSearchMessage, "Showing 50 mlx-community results sorted by downloads.")
    }

    func testSearchModelsFiltersKnownUnsupportedRuntimeModelTypes() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "search-limit-50": CommandResult(
                exitCode: 0,
                standardOutput: """
                [
                  {"id":"mlx-community/Runnable","downloads":100,"likes":7,"model_type":"mistral"},
                  {"id":"mlx-community/Gemma4","downloads":99,"likes":8,"model_type":"gemma4_unified"},
                  {"id":"mlx-community/Unknown","downloads":98,"likes":9}
                ]
                """,
                standardError: ""
            )
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelSearcher: HuggingFaceModelSearcher(runner: runner)
        )

        await viewModel.searchModels()

        XCTAssertEqual(viewModel.searchResults.map(\.id), ["mlx-community/Runnable"])
        XCTAssertEqual(
            viewModel.modelSearchMessage,
            "Showing 1 mlx-community result sorted by downloads; filtered 1 unsupported and 1 unknown by current mlx-lm."
        )
    }

    func testSearchModelsGroupsVariantsAndInstallsSelectedVariant() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "search-limit-50": CommandResult(
                exitCode: 0,
                standardOutput: """
                [
                  {"id":"mlx-community/Foo-6bit","downloads":900,"likes":6,"model_type":"mistral"},
                  {"id":"mlx-community/Foo-4bit","downloads":100,"likes":4,"model_type":"mistral"},
                  {"id":"mlx-community/Foo-8bit","downloads":800,"likes":8,"model_type":"mistral"}
                ]
                """,
                standardError: ""
            ),
            "install": CommandResult(exitCode: 0, standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Foo-6bit/snapshots/abc"}"#, standardError: ""),
            "whoami": CommandResult(exitCode: 0, standardOutput: #"{"name":"tester"}"#, standardError: "")
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelSearcher: HuggingFaceModelSearcher(runner: runner),
            modelInstaller: HuggingFaceModelInstaller(runner: runner),
            authChecker: HuggingFaceAuthChecker(runner: runner)
        )

        await viewModel.searchModels()
        viewModel.selectSearchVariant(familyID: "mlx-community/Foo", variantID: "mlx-community/Foo-6bit")
        await viewModel.installSelectedModel()

        XCTAssertEqual(viewModel.searchResultFamilies.count, 1)
        XCTAssertEqual(viewModel.searchResultFamilies[0].variants.map(\.label), ["4bit", "6bit", "8bit"])
        XCTAssertEqual(viewModel.searchResultFamilies[0].selectedVariantID, "mlx-community/Foo-6bit")
        XCTAssertTrue(runner.commands.contains { command in
            command.pythonScript?.contains("snapshot_download") == true
                && command.arguments.contains("mlx-community/Foo-6bit")
        }, runner.commands.map { $0.arguments.joined(separator: " ") }.joined(separator: "\n"))
    }

    func testSearchModelsCanLoadMoreWhenRawPageIsFullAfterFiltering() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "search-limit-50": CommandResult(exitCode: 0, standardOutput: Self.modelListJSON(count: 50, unsupportedIndices: [50]), standardError: "")
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelSearcher: HuggingFaceModelSearcher(runner: runner)
        )

        await viewModel.searchModels()

        XCTAssertEqual(viewModel.searchResults.count, 49)
        XCTAssertTrue(viewModel.canLoadMoreSearchResults)
        XCTAssertEqual(viewModel.modelSearchMessage, "Showing 49 mlx-community results sorted by downloads; filtered 1 unsupported by current mlx-lm.")
    }

    func testSearchModelsCanLoadMoreWhenFullRawPageIsEntirelyFiltered() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "search-limit-50": CommandResult(exitCode: 0, standardOutput: Self.modelListJSON(count: 50, unsupportedIndices: Set(1...50)), standardError: "")
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
            modelSearcher: HuggingFaceModelSearcher(runner: runner)
        )

        await viewModel.searchModels()

        XCTAssertEqual(viewModel.searchResults.count, 0)
        XCTAssertTrue(viewModel.canLoadMoreSearchResults)
        XCTAssertEqual(viewModel.modelSearchMessage, "Showing 0 mlx-community results sorted by downloads; filtered 50 unsupported by current mlx-lm.")
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
        XCTAssertTrue(runner.commands.contains { $0.pythonScript?.contains("list_models") == true && $0.arguments.last == "100" })
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

        let searchCommands = runner.commands
            .filter { $0.pythonScript?.contains("list_models") == true }
        XCTAssertTrue(searchCommands.suffix(1).allSatisfy { $0.arguments.last == "50" })
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
        XCTAssertFalse(runner.commands.contains { $0.pythonScript?.contains("list_models") == true })
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
        XCTAssertEqual(runner.commands.count, 4)
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

        XCTAssertTrue(runner.commands.contains {
            $0.arguments == ["-m", "pip", "install", "--upgrade", "mlx", "mlx-lm", "huggingface_hub"]
        })
        XCTAssertTrue(runner.commands.contains {
            $0.pythonScript?.contains("metadata.distribution(\"mlx-lm\")") == true
        })
        XCTAssertEqual(viewModel.pythonStatus, "Ready")
        XCTAssertFalse(viewModel.shouldOfferPythonPackageInstall)
        XCTAssertEqual(viewModel.modelSearchMessage, "Python packages installed. Search is ready.")
    }

    func testRefreshPythonStatusLogsRuntimeCapabilityFailureWithoutDuplicatedPrefix() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "import mlx": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "runtime-capabilities": CommandResult(exitCode: 2, standardOutput: "", standardError: ""),
            "runtime-package-versions": CommandResult(
                exitCode: 0,
                standardOutput: #"{"mlx":"0.29.0","mlx-lm":"0.31.3"}"#,
                standardError: ""
            ),
            "pip-outdated": CommandResult(exitCode: 0, standardOutput: #"[]"#, standardError: "")
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner)
        )

        await viewModel.refreshPythonStatus()

        let logText = try String(contentsOf: paths.logsDirectory.appending(path: "mlxdashboard.log"), encoding: .utf8)
        XCTAssertTrue(
            logText.contains("Runtime capability inspection failed: python exited with code 2 without diagnostic output")
        )
        XCTAssertFalse(logText.contains("Runtime capability inspection failed: Runtime capability inspection failed"))
    }

    func testRefreshPythonStatusChecksRuntimePackageUpgradesWhenReady() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: python.path, contents: Data())
        let sitePackages = try temporaryDirectory()

        let runner = FakeCommandRunner(results: [
            "import mlx": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            "runtime-capabilities": CommandResult(
                exitCode: 0,
                standardOutput: #"{"site_packages":"\#(sitePackages.path)","version":"0.31.3"}"#,
                standardError: ""
            ),
            "runtime-package-versions": CommandResult(
                exitCode: 0,
                standardOutput: #"{"mlx":"0.29.0","mlx-lm":"0.31.3"}"#,
                standardError: ""
            ),
            "pip-outdated": CommandResult(
                exitCode: 0,
                standardOutput: #"[{"name":"mlx-lm","version":"0.31.3","latest_version":"0.32.0"}]"#,
                standardError: ""
            )
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner)
        )

        await viewModel.refreshPythonStatus()

        XCTAssertEqual(viewModel.runtimePackageUpgradeSummary, "Updates: mlx-lm 0.31.3 -> 0.32.0")
        XCTAssertTrue(viewModel.canUpgradeRuntimePackages)
        XCTAssertTrue(runner.commands.contains { $0.arguments == ["-m", "pip", "list", "--outdated", "--format=json"] })
    }

    func testRefreshPythonStatusLeavesUpgradeStatusUncheckedWhenPackagesAreMissing() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let runner = FakeCommandRunner(results: [
            "import mlx": CommandResult(exitCode: 1, standardOutput: "", standardError: "No module named mlx"),
            "import mlx_lm": CommandResult(exitCode: 1, standardOutput: "", standardError: "No module named mlx_lm"),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner)
        )

        await viewModel.refreshPythonStatus()

        XCTAssertEqual(viewModel.pythonStatus, "Missing: mlx, mlx-lm")
        XCTAssertEqual(viewModel.runtimePackageUpgradeSummary, "Runtime updates: not checked")
        XCTAssertFalse(viewModel.canUpgradeRuntimePackages)
        XCTAssertFalse(runner.commands.contains { $0.arguments == ["-m", "pip", "list", "--outdated", "--format=json"] })
    }

    func testRuntimePackageUpgradeCheckLogsCancellationWithoutFailure() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: python.path, contents: Data())
        let sitePackages = try temporaryDirectory()

        let runner = FakeCommandRunner(
            results: [
                "runtime-capabilities": CommandResult(
                    exitCode: 0,
                    standardOutput: #"{"site_packages":"\#(sitePackages.path)","version":"0.31.3"}"#,
                    standardError: ""
                ),
                "runtime-package-versions": CommandResult(
                    exitCode: 0,
                    standardOutput: #"{"mlx":"0.29.0","mlx-lm":"0.31.3"}"#,
                    standardError: ""
                )
            ],
            thrownErrors: [
                "pip-outdated": CancellationError()
            ]
        )
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner)
        )

        await viewModel.checkRuntimePackageUpgrades()

        let logText = try String(contentsOf: paths.logsDirectory.appending(path: "mlxdashboard.log"), encoding: .utf8)
        XCTAssertTrue(logText.contains("Runtime package upgrade check cancelled."))
        XCTAssertFalse(logText.contains("Runtime package upgrade check failed"))
    }

    func testUpgradeRuntimePackagesRunsUpgradeAndRefreshesUpgradeStatus() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: python.path, contents: Data())
        let sitePackages = try temporaryDirectory()

        let runner = FakeCommandRunner(results: [
            "runtime-upgrade": CommandResult(exitCode: 0, standardOutput: "upgraded", standardError: ""),
            "runtime-capabilities": CommandResult(
                exitCode: 0,
                standardOutput: #"{"site_packages":"\#(sitePackages.path)","version":"0.32.0"}"#,
                standardError: ""
            ),
            "runtime-package-versions": CommandResult(
                exitCode: 0,
                standardOutput: #"{"mlx":"0.30.0","mlx-lm":"0.32.0"}"#,
                standardError: ""
            ),
            "pip-outdated": CommandResult(exitCode: 0, standardOutput: #"[]"#, standardError: "")
        ])
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: runner)
        )
        viewModel.runtimePackageUpgradeStatus = PythonPackageUpgradeReport(statuses: [
            PythonPackageVersionStatus(
                packageName: "mlx-lm",
                installedVersion: "0.31.3",
                latestVersion: "0.32.0",
                state: .upgradeAvailable
            )
        ])

        await viewModel.upgradeRuntimePackages()

        XCTAssertTrue(runner.commands.contains {
            $0.arguments == ["-m", "pip", "install", "--upgrade", "mlx", "mlx-lm"]
        })
        XCTAssertEqual(viewModel.runtimePackageUpgradeSummary, "Runtime packages are current")
        XCTAssertFalse(viewModel.canUpgradeRuntimePackages)
        XCTAssertEqual(viewModel.modelSearchMessage, "Runtime packages upgraded. Search is ready.")
        let logText = try String(contentsOf: paths.logsDirectory.appending(path: "mlxdashboard.log"), encoding: .utf8)
        XCTAssertTrue(logText.contains("Upgraded MLX runtime packages"))
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

        let installCommands = runner.commands.filter { $0.pythonScript?.contains("snapshot_download") == true }
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

        let installCommands = runner.commands.filter { $0.pythonScript?.contains("snapshot_download") == true }
        XCTAssertNil(installCommands.last?.environment["HF_HUB_DISABLE_XET"])
        XCTAssertEqual(installCommands.last?.environment["HF_XET_NUM_CONCURRENT_RANGE_GETS"], "4")
        XCTAssertEqual(installCommands.last?.environment["HF_HUB_DOWNLOAD_TIMEOUT"], "60")
        XCTAssertEqual(installCommands.last?.environment["HF_HUB_ETAG_TIMEOUT"], "30")
    }

    func testInstallSelectedModelUsesFixedConservativeEnvironmentWhenCustomValuesWereStored() async throws {
        let paths = try temporaryAppPaths()
        let python = paths.venvDirectory.appending(path: "bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: python.path, contents: Data())

        let settingsStore = SettingsStore(fileURL: paths.settingsFile)
        try settingsStore.save(DashboardSettings(
            downloadSettings: HuggingFaceDownloadSettings(
                mode: .xetConservative,
                xetConcurrency: 16,
                downloadTimeoutSeconds: 600,
                etagTimeoutSeconds: 120
            )
        ))
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

        let installCommands = runner.commands.filter { $0.pythonScript?.contains("snapshot_download") == true }
        XCTAssertNil(installCommands.last?.environment["HF_HUB_DISABLE_XET"])
        XCTAssertEqual(installCommands.last?.environment["HF_XET_NUM_CONCURRENT_RANGE_GETS"], "4")
        XCTAssertEqual(installCommands.last?.environment["HF_HUB_DOWNLOAD_TIMEOUT"], "60")
        XCTAssertEqual(installCommands.last?.environment["HF_HUB_ETAG_TIMEOUT"], "30")
        XCTAssertEqual(installCommands.last?.environmentRemovals, ["HF_HUB_DISABLE_XET"])
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
        XCTAssertEqual(viewModel.searchResultAction(for: "mlx-community/Tiny"), .alreadyInstalled)
        XCTAssertEqual(viewModel.searchResultFamilies.first?.selectedVariant?.installState, .installed)
    }

    func testInstallProgressIsStoredByModelIDAndExposedForSelectedInstalledModel() async throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )
        let progress = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .downloading,
            detail: "Downloading"
        )

        viewModel.setInstallProgressForTesting(progress)
        viewModel.selectedInstalledModelID = "mlx-community/Tiny"

        XCTAssertEqual(viewModel.installProgressByModelID["mlx-community/Tiny"], progress)
        XCTAssertEqual(viewModel.selectedInstalledModelProgress, progress)
        XCTAssertEqual(viewModel.modelInstallProgress, progress)
    }

    func testSelectedInstalledModelProgressCanDifferFromActiveInstallProgress() async throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )
        let active = ModelInstallProgress(modelID: "mlx-community/Active", phase: .downloading, detail: "Active")
        let selected = ModelInstallProgress(modelID: "mlx-community/Selected", phase: .failed, detail: "Failed")

        viewModel.setInstallProgressForTesting(active)
        viewModel.setInstallProgressForTesting(selected, makeActive: false)
        viewModel.selectedInstalledModelID = "mlx-community/Selected"

        XCTAssertEqual(viewModel.modelInstallProgress, active)
        XCTAssertEqual(viewModel.selectedInstalledModelProgress, selected)
    }

    func testInstalledProgressPrefersSelectedModelProgressOverActiveProgressForDetail() throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )
        let active = ModelInstallProgress(modelID: "mlx-community/Active", phase: .downloading, detail: "Active")
        let selected = ModelInstallProgress(modelID: "mlx-community/Selected", phase: .failed, detail: "Selected failed")

        viewModel.setInstallProgressForTesting(active)
        viewModel.setInstallProgressForTesting(selected, makeActive: false)
        viewModel.selectedInstalledModelID = "mlx-community/Selected"

        XCTAssertEqual(viewModel.installedWorkspacePrimaryProgress, selected)
        XCTAssertEqual(viewModel.modelInstallProgress, active)
    }

    func testInstalledProgressFallsBackToActiveProgressWhenSelectedHasNoHistory() throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )
        let active = ModelInstallProgress(modelID: "mlx-community/Active", phase: .downloading, detail: "Active")

        viewModel.setInstallProgressForTesting(active)
        viewModel.selectedInstalledModelID = "mlx-community/Other"

        XCTAssertEqual(viewModel.installedWorkspacePrimaryProgress, active)
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

    func testModelInstallProgressShowsActivityRowsForTerminalPhases() {
        let progress = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .failed,
            detail: "Install failed",
            activities: [
                HuggingFaceDownloadActivity(message: "Downloading config", tone: .info, source: .commandOutput)
            ]
        )

        XCTAssertEqual(progress.activityRows.map(\.message), ["Downloading config"])
        XCTAssertEqual(progress.fullActivityRows.map(\.message), ["Downloading config"])
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

    func testModelInstallProgressRetainsFiftyActivitiesAndPreviewsLatestFive() {
        var progress = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .downloading,
            detail: "Downloading"
        )

        for index in 1...60 {
            progress = progress.appendingActivity(
                HuggingFaceDownloadActivity(message: "event \(index)", tone: .info, source: .commandOutput)
            )
        }

        XCTAssertEqual(progress.activities.count, 50)
        XCTAssertEqual(progress.activities.first?.message, "event 11")
        XCTAssertEqual(progress.activities.last?.message, "event 60")
        XCTAssertEqual(progress.activityRows.map(\.message), ["event 56", "event 57", "event 58", "event 59", "event 60"])
        XCTAssertEqual(progress.fullActivityRows.count, 50)
    }

    func testModelInstallProgressDisplayModeUsesDeterminateIndeterminateAndPhaseFallback() {
        let waiting = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .downloading,
            detail: "Downloading"
        )
        XCTAssertEqual(waiting.progressDisplayMode, .indeterminateDownload)

        let transfer = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .downloading,
            detail: "Downloading",
            downloadProgress: HuggingFaceDownloadProgress(
                fractionCompleted: 0.42,
                percentText: "42%",
                etaText: "7m 12s",
                rateText: "13.4MB/s"
            )
        )
        XCTAssertEqual(transfer.progressDisplayMode, .determinate(value: 0.42))

        let preparing = ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .preparing,
            detail: "Preparing"
        )
        XCTAssertEqual(preparing.progressDisplayMode, .phaseFallback(value: 0.08))
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
        XCTAssertEqual(viewModel.searchResultAction(for: "mlx-community/Tiny"), .install)
        XCTAssertEqual(viewModel.searchResultFamilies.first?.selectedVariant?.installState, .failed)
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
        viewModel.setInstallProgressForTesting(ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .failed,
            detail: "Install failed for mlx-community/Tiny: network interrupted"
        ))

        await viewModel.continueLastModelInstall()

        let installCommands = runner.commands.filter { $0.pythonScript?.contains("snapshot_download") == true }
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
        viewModel.setInstallProgressForTesting(ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .failed,
            detail: "Install failed for mlx-community/Tiny: network interrupted"
        ))

        await viewModel.retryLastModelInstallWithoutXet()

        let installCommands = runner.commands.filter { $0.pythonScript?.contains("snapshot_download") == true }
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
        XCTAssertEqual(viewModel.modelInstallMessage, "Set mlx-community/Tiny as the default model.")
    }

    func testSetSelectedInstalledModelActiveDoesNotClearInstallProgressHistory() throws {
        let paths = try temporaryAppPaths()
        let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
        registry.upsert(ModelRecord(id: "mlx-community/Tiny", status: .installed, localPath: "/tmp/tiny"))
        try registry.save()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )
        let progress = ModelInstallProgress(modelID: "mlx-community/Tiny", phase: .installed, detail: "Installed")
        viewModel.setInstallProgressForTesting(progress)
        viewModel.selectedInstalledModelID = "mlx-community/Tiny"

        viewModel.setSelectedInstalledModelActive()

        XCTAssertEqual(viewModel.settings.activeModel, "mlx-community/Tiny")
        XCTAssertEqual(viewModel.installProgressByModelID["mlx-community/Tiny"], progress)
        XCTAssertEqual(viewModel.selectedInstalledModelProgress, progress)
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
        viewModel.setInstallProgressForTesting(progress)

        XCTAssertFalse(viewModel.canSetSelectedInstalledModelActive)
        XCTAssertFalse(viewModel.canAssignSelectedInstalledModelToProviderRole)

        viewModel.setSelectedInstalledModelActive()

        XCTAssertNil(viewModel.settings.activeModel)
        XCTAssertEqual(viewModel.modelInstallProgress, progress)
        XCTAssertEqual(viewModel.modelInstallMessage, "Select an installed model before setting it as default.")
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
        XCTAssertEqual(viewModel.modelInstallMessage, "Assigned mlx-community/Tiny to Coding.")
    }

    func testUpdateGenerationSettingsPersistsRoleDefaults() throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )

        viewModel.updateGenerationSettings(
            ProviderGenerationSettings(temperature: 0.42, topP: 0.88, maxTokens: 1234),
            for: .coding
        )

        let reloaded = try SettingsStore(fileURL: paths.settingsFile).load()
        XCTAssertEqual(viewModel.settings.providerGenerationDefaults.coding.temperature, 0.42)
        XCTAssertEqual(viewModel.settings.providerGenerationDefaults.coding.topP, 0.88)
        XCTAssertEqual(viewModel.settings.providerGenerationDefaults.coding.maxTokens, 1234)
        XCTAssertEqual(reloaded.providerGenerationDefaults.coding.temperature, 0.42)
        XCTAssertEqual(reloaded.providerGenerationDefaults.coding.topP, 0.88)
        XCTAssertEqual(reloaded.providerGenerationDefaults.coding.maxTokens, 1234)
    }

    func testAssignSelectedInstalledModelToRoleDoesNotClearInstallProgressHistory() throws {
        let paths = try temporaryAppPaths()
        let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
        registry.upsert(ModelRecord(id: "mlx-community/Tiny", status: .installed, localPath: "/tmp/tiny"))
        try registry.save()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )
        let progress = ModelInstallProgress(modelID: "mlx-community/Tiny", phase: .installed, detail: "Installed")
        viewModel.setInstallProgressForTesting(progress)
        viewModel.selectedInstalledModelID = "mlx-community/Tiny"

        viewModel.assignSelectedInstalledModel(to: .ask)

        XCTAssertEqual(viewModel.settings.providerRoleAssignments.ask, "mlx-community/Tiny")
        XCTAssertEqual(viewModel.installProgressByModelID["mlx-community/Tiny"], progress)
        XCTAssertEqual(viewModel.selectedInstalledModelProgress, progress)
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

    func testDeleteSelectedInstalledModelClearsMatchingInstallProgress() throws {
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
        viewModel.setInstallProgressForTesting(ModelInstallProgress(
            modelID: "mlx-community/Tiny",
            phase: .installed,
            detail: "Installed Tiny"
        ))

        viewModel.deleteSelectedInstalledModelFromCache()

        XCTAssertNil(viewModel.modelInstallProgress)
        XCTAssertEqual(viewModel.modelInstallMessage, "Deleted cache for mlx-community/Tiny.")
    }

    func testDeleteSelectedInstalledModelClearsOnlyThatModelsProgressHistory() throws {
        let paths = try temporaryAppPaths()
        let cacheRoot = try temporaryDirectory()
        let tinyRepo = cacheRoot.appending(path: "models--mlx-community--Tiny/snapshots/abc123", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tinyRepo, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tinyRepo.appending(path: "config.json").path, contents: Data())
        let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
        registry.upsert(ModelRecord(id: "mlx-community/Tiny", status: .installed, localPath: tinyRepo.path))
        registry.upsert(ModelRecord(id: "mlx-community/Other", status: .installed, localPath: "/tmp/other"))
        try registry.save()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:])),
            huggingFaceCacheRoot: cacheRoot
        )
        viewModel.setInstallProgressForTesting(ModelInstallProgress(modelID: "mlx-community/Tiny", phase: .installed, detail: "Tiny"))
        viewModel.setInstallProgressForTesting(ModelInstallProgress(modelID: "mlx-community/Other", phase: .installed, detail: "Other"))
        viewModel.selectedInstalledModelID = "mlx-community/Tiny"

        viewModel.deleteSelectedInstalledModelFromCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appending(path: "models--mlx-community--Tiny").path))
        XCTAssertEqual(registry.record(id: "mlx-community/Tiny")?.status, .removed)
        XCTAssertNil(viewModel.installProgressByModelID["mlx-community/Tiny"])
        XCTAssertNotNil(viewModel.installProgressByModelID["mlx-community/Other"])
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

    func testCacheScanMarksUnsupportedModelTypesFailedAndClearsRuntimeSelections() throws {
        let paths = try temporaryAppPaths()
        try SettingsStore(fileURL: paths.settingsFile).save(
            DashboardSettings(
                activeModel: "mlx-community/Gemma4",
                providerRoleAssignments: ProviderRoleAssignments(
                    ask: "mlx-community/Gemma4",
                    plan: "mlx-community/Devstral",
                    coding: "mlx-community/Gemma4"
                )
            )
        )
        let cacheRoot = try temporaryDirectory()
        let unsupported = cacheRoot.appending(path: "models--mlx-community--Gemma4/snapshots/abc", directoryHint: .isDirectory)
        let runnable = cacheRoot.appending(path: "models--mlx-community--Devstral/snapshots/def", directoryHint: .isDirectory)
        try createCachedModelSnapshot(at: unsupported, config: #"{"model_type":"gemma4_unified"}"#)
        try createCachedModelSnapshot(at: runnable, config: #"{"model_type":"mistral"}"#)

        let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:])),
            huggingFaceCacheRoot: cacheRoot
        )

        viewModel.scanModelCache()

        let unsupportedRecord = try XCTUnwrap(registry.record(id: "mlx-community/Gemma4"))
        XCTAssertEqual(unsupportedRecord.status, .failed)
        XCTAssertEqual(unsupportedRecord.localPath, unsupported.path)
        XCTAssertEqual(unsupportedRecord.message, "Unsupported by installed mlx-lm: gemma4_unified")
        XCTAssertEqual(registry.record(id: "mlx-community/Devstral")?.status, .installed)
        XCTAssertNil(viewModel.settings.activeModel)
        XCTAssertNil(viewModel.settings.providerRoleAssignments.ask)
        XCTAssertEqual(viewModel.settings.providerRoleAssignments.plan, "mlx-community/Devstral")
        XCTAssertNil(viewModel.settings.providerRoleAssignments.coding)

        let persisted = try SettingsStore(fileURL: paths.settingsFile).load()
        XCTAssertNil(persisted.activeModel)
        XCTAssertNil(persisted.providerRoleAssignments.ask)
        XCTAssertEqual(persisted.providerRoleAssignments.plan, "mlx-community/Devstral")
        XCTAssertNil(persisted.providerRoleAssignments.coding)
    }

    func testInitializationMigratesUnsupportedInstalledRecordAndClearsActiveModel() throws {
        let paths = try temporaryAppPaths()
        let cacheRoot = try temporaryDirectory()
        let unsupported = cacheRoot.appending(path: "models--mlx-community--Gemma4/snapshots/abc", directoryHint: .isDirectory)
        try createCachedModelSnapshot(at: unsupported, config: #"{"model_type":"gemma4_unified"}"#)
        try SettingsStore(fileURL: paths.settingsFile).save(
            DashboardSettings(
                activeModel: "mlx-community/Gemma4",
                providerRoleAssignments: ProviderRoleAssignments(ask: "mlx-community/Gemma4")
            )
        )
        let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
        registry.upsert(ModelRecord(id: "mlx-community/Gemma4", status: .installed, localPath: unsupported.path))
        try registry.save()

        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: registry,
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:])),
            huggingFaceCacheRoot: cacheRoot
        )

        XCTAssertEqual(registry.record(id: "mlx-community/Gemma4")?.status, .failed)
        XCTAssertEqual(registry.record(id: "mlx-community/Gemma4")?.message, "Unsupported by installed mlx-lm: gemma4_unified")
        XCTAssertNil(viewModel.settings.activeModel)
        XCTAssertNil(viewModel.settings.providerRoleAssignments.ask)
        let persisted = try SettingsStore(fileURL: paths.settingsFile).load()
        XCTAssertNil(persisted.activeModel)
        XCTAssertNil(persisted.providerRoleAssignments.ask)
    }

    func testRequestModelDownloadSettingsNavigationIncrementsRequestID() throws {
        let paths = try temporaryAppPaths()
        let viewModel = DashboardViewModel(
            settingsStore: SettingsStore(fileURL: paths.settingsFile),
            registry: ModelRegistry(fileURL: paths.modelRegistryFile),
            environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
        )
        let initialRequestID = viewModel.modelDownloadSettingsNavigationRequestID

        viewModel.requestModelDownloadSettingsNavigation()

        XCTAssertEqual(viewModel.modelDownloadSettingsNavigationRequestID, initialRequestID + 1)
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

    private func createCachedModelSnapshot(at snapshot: URL, config: String) throws {
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try config.write(to: snapshot.appending(path: "config.json"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: snapshot.appending(path: "model.safetensors.index.json").path, contents: Data())
        FileManager.default.createFile(atPath: snapshot.appending(path: "tokenizer_config.json").path, contents: Data())
    }

    private func availableTestPorts() throws -> (mlxPort: Int, planPort: Int, providerPort: Int) {
        let checker = TCPServerPortChecker()
        for basePort in stride(from: 23000, through: 43000, by: 17) {
            let planPort = basePort + 1
            let providerPort = basePort + 2
            guard checker.isPortAvailable(host: DashboardSettings.localMLXHost, port: basePort),
                  checker.isPortAvailable(host: DashboardSettings.localMLXHost, port: planPort),
                  checker.isPortAvailable(host: DashboardSettings.localMLXHost, port: providerPort)
            else { continue }
            return (basePort, planPort, providerPort)
        }
        throw XCTSkip("No free loopback ports available for provider endpoint sync test.")
    }

    private func makeUpstreamServer(modelID: String, port: Int) throws -> NIOProviderServer {
        let server = NIOProviderServer(
            host: DashboardSettings.localMLXHost,
            port: port,
            router: ProviderRouter(
                upstream: FixedModelUpstream(modelID: modelID),
                activeModelProvider: { modelID }
            )
        )
        do {
            try server.start()
            return server
        } catch {
            throw XCTSkip("Loopback upstream listener unavailable in this sandbox: \(error)")
        }
    }

    private func providerStatusCode(port: Int, model: String) async throws -> Int {
        let response = try await providerChatResponse(port: port, model: model)
        return response.statusCode
    }

    private func providerResponseModel(port: Int, model: String) async throws -> String? {
        let response = try await providerChatResponse(port: port, model: model)
        let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        return json?["model"] as? String
    }

    private func providerChatResponse(port: Int, model: String) async throws -> (data: Data, statusCode: Int) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(#"{"model":"\#(model)","messages":[{"role":"user","content":"plan"}],"stream":false}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
    }

    private static func modelListJSON(count: Int, unsupportedIndices: Set<Int> = []) -> String {
        let models = (1...count).map { index in
            let modelType = unsupportedIndices.contains(index) ? "gemma4_unified" : "mistral"
            return #"{"id":"mlx-community/Model-\#(index)","downloads":\#(1000 - index),"likes":\#(index),"model_type":"\#(modelType)"}"#
        }
        return "[\(models.joined(separator: ","))]"
    }

    private static func modelIDs(in data: Data) throws -> [String] {
        try models(in: data).compactMap { $0["id"] as? String }
    }

    private static func models(in data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["data"] as? [[String: Any]] ?? []
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
        let script = command.pythonScript ?? command.arguments.last ?? ""
        let key: String
        if script.contains("snapshot_download") {
            key = "install"
        } else if script.contains("whoami") {
            key = "whoami"
        } else if script.contains("packages = sys.argv[1:]") {
            key = "runtime-package-versions"
        } else if script.contains("metadata.distribution(\"mlx-lm\")") {
            key = "runtime-capabilities"
        } else if command.arguments == ["-m", "pip", "list", "--outdated", "--format=json"] {
            key = "pip-outdated"
        } else if command.arguments == ["-m", "pip", "install", "--upgrade", "mlx", "mlx-lm"] {
            key = "runtime-upgrade"
        } else if command.arguments.count == 5,
                  Array(command.arguments[0...3]) == ["-m", "pip", "install", "--upgrade"],
                  command.arguments[4].contains("TextDiffusionRuntime") {
            key = "text-diffusion-runtime-install"
        } else if script.contains("list_models") {
            if command.arguments.last == "50", results["search-limit-50"] != nil {
                key = "search-limit-50"
            } else if command.arguments.last == "100", results["search-limit-100"] != nil {
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
        if script.hasPrefix("import ") {
            return results[key] ?? CommandResult(exitCode: 0, standardOutput: "", standardError: "")
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

private final class LateOutputCommandRunner: CommandRunning, @unchecked Sendable {
    private let lateOutput: String
    private let lock = NSLock()
    private var lateOutputEmitted = false
    private var lateOutputContinuation: CheckedContinuation<Void, Never>?

    init(lateOutput: String) {
        self.lateOutput = lateOutput
    }

    func run(_ command: Command) async throws -> CommandResult {
        let script = command.pythonScript ?? ""
        if script.contains("whoami") {
            return CommandResult(exitCode: 0, standardOutput: #"{"name":"octocat"}"#, standardError: "")
        }
        if script == "import mlx" || script == "import mlx_lm" || script == "import huggingface_hub" {
            return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        return CommandResult(exitCode: 127, standardOutput: "", standardError: "unexpected command")
    }

    func run(_ command: Command, outputHandler: CommandOutputHandler?) async throws -> CommandResult {
        let script = command.pythonScript ?? ""
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
        let script = command.pythonScript ?? ""
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
        if script == "import mlx" || script == "import mlx_lm" || script == "import huggingface_hub" {
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
    var isAvailable: Bool = true
    var unavailablePorts: Set<Int> = []

    func isPortAvailable(host: String, port: Int) -> Bool {
        isAvailable && !unavailablePorts.contains(port)
    }
}

private struct FakeHealthChecker: ServerHealthChecking {
    var healthyPorts: Set<Int>? = nil

    func waitUntilHealthy(
        baseURL: URL,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async -> Bool {
        guard let healthyPorts else { return true }
        return healthyPorts.contains(baseURL.port ?? -1)
    }
}

private final class MutableFakePortChecker: ServerPortChecking, @unchecked Sendable {
    var isAvailable = true
    var unavailablePorts: Set<Int> = []

    func isPortAvailable(host: String, port: Int) -> Bool {
        isAvailable && !unavailablePorts.contains(port)
    }
}

private struct FixedModelUpstream: ProviderUpstreamClient {
    let modelID: String

    func proxy(_ request: ProviderRequest) async throws -> ProviderResponse {
        switch request.path {
        case "/v1/chat/completions":
            return ProviderResponse(
                status: 200,
                headers: ["content-type": "application/json"],
                body: Data(
                    #"{"id":"chatcmpl-test","object":"chat.completion","created":1,"model":"\#(modelID)","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"Hello from \#(modelID)."}}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}"#.utf8
                )
            )
        case "/v1/models":
            return ProviderResponse(
                status: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"object":"list","data":[]}"#.utf8)
            )
        default:
            return ProviderResponse(
                status: 404,
                headers: ["content-type": "application/json"],
                body: Data(#"{"error":"not found"}"#.utf8)
            )
        }
    }

    func proxyStream(_ request: ProviderRequest) async throws -> ProviderStreamedResponse {
        let response = try await proxy(request)
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            if !response.body.isEmpty {
                continuation.yield(response.body)
            }
            continuation.finish()
        }
        return ProviderStreamedResponse(status: response.status, headers: response.headers, chunks: chunks)
    }
}
