import Foundation
import Combine
import MLXCore
import MLXPythonBridge
import MLXProviderServer
import MLXServerControl

struct ControllerButtonPolicy {
    static func canStartServer(state: ServerState) -> Bool {
        state == .stopped || state == .failed
    }

    static func canStopServer(state: ServerState) -> Bool {
        state == .starting || state == .running
    }

    static func canRestartServer(state: ServerState) -> Bool {
        state == .running
    }
}

private final class ActiveModelSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var storedModel: String?

    init(model: String?) {
        self.storedModel = model
    }

    var model: String? {
        lock.withLock { storedModel }
    }

    func update(_ model: String?) {
        lock.withLock {
            storedModel = model
        }
    }
}

private final class ProviderDebugCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEnabled: Bool

    init(enabled: Bool) {
        self.storedEnabled = enabled
    }

    var isEnabled: Bool {
        lock.withLock { storedEnabled }
    }

    func update(_ enabled: Bool) {
        lock.withLock {
            storedEnabled = enabled
        }
    }
}

private final class ProviderRoleAssignmentState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAssignments: ProviderRoleAssignments

    init(assignments: ProviderRoleAssignments) {
        self.storedAssignments = assignments
    }

    var assignments: ProviderRoleAssignments {
        lock.withLock { storedAssignments }
    }

    func update(_ assignments: ProviderRoleAssignments) {
        lock.withLock {
            storedAssignments = assignments
        }
    }
}

private final class ProviderUpstreamEndpointState: @unchecked Sendable {
    private let lock = NSLock()
    private var defaultEndpointValue: ProviderUpstreamEndpoint?
    private var roleEndpointsValue: [ProviderModelRole: ProviderUpstreamEndpoint] = [:]

    var defaultEndpoint: ProviderUpstreamEndpoint? {
        lock.withLock { defaultEndpointValue }
    }

    func endpoint(for role: ProviderModelRole) -> ProviderUpstreamEndpoint? {
        lock.withLock { roleEndpointsValue[role] }
    }

    func update(defaultEndpoint: RoleServerEndpoint?, roleEndpoints: [ProviderModelRole: RoleServerEndpoint]) {
        lock.withLock {
            defaultEndpointValue = defaultEndpoint.flatMap(Self.providerEndpoint(from:))
            roleEndpointsValue = Dictionary(uniqueKeysWithValues: roleEndpoints.compactMap { role, endpoint in
                guard let providerEndpoint = Self.providerEndpoint(from: endpoint) else {
                    return nil
                }
                return (role, providerEndpoint)
            })
        }
    }

    func clear() {
        lock.withLock {
            defaultEndpointValue = nil
            roleEndpointsValue = [:]
        }
    }

    private static func providerEndpoint(from endpoint: RoleServerEndpoint) -> ProviderUpstreamEndpoint? {
        guard let modelID = endpoint.modelID else {
            return nil
        }
        return ProviderUpstreamEndpoint(modelID: modelID, baseURL: endpoint.baseURL, port: endpoint.port)
    }
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var settings: DashboardSettings
    @Published var pythonStatus = "Not checked"
    @Published var providerStatus = "Stopped"
    @Published var installedModels: [ModelRecord] = []
    @Published var searchResults: [HuggingFaceModelSummary] = []
    @Published var modelQuery = "Devstral-Small"
    @Published var modelSearchMessage: String?
    @Published var modelInstallMessage: String?
    @Published var huggingFaceAuthMessage = "Hugging Face: Not checked"
    @Published var shouldOfferPythonPackageInstall = false
    @Published var selectedSearchModelID: String?
    @Published var selectedInstalledModelID: String?
    @Published var isInstallingModel = false
    @Published var isLoadingMoreSearchResults = false
    @Published var modelInstallProgress: ModelInstallProgress?
    @Published var modelDownloadSettingsNavigationRequestID = 0
    @Published private(set) var roleServerStatuses: [RoleServerStatusRow]

    let telemetry: TelemetryStore
    let serverPoolController: RoleServerPoolController

    private let settingsStore: SettingsStore
    private let registry: ModelRegistry
    private let environmentManager: PythonEnvironmentManager
    private let cacheManager: MLXModelCacheManager
    private let modelSearcher: HuggingFaceModelSearcher
    private let modelInstaller: HuggingFaceModelInstaller
    private let authChecker: HuggingFaceAuthChecker
    private let configuredHuggingFaceCacheRoot: URL?
    private let activeModelSelection: ActiveModelSelection
    private let providerDebugCaptureState: ProviderDebugCaptureState
    private let providerRoleAssignmentState: ProviderRoleAssignmentState
    private let providerUpstreamEndpointState: ProviderUpstreamEndpointState
    private var serverPoolControllerCancellable: AnyCancellable?
    private var providerServer: NIOProviderServer?
    private var activeInstallTask: Task<Void, Never>?
    private var downloadActivityMonitorTask: Task<Void, Never>?
    private var installSessionCounter = 0
    private var activeInstallSessionID: Int?
    private let modelSearchPageSize = 50
    private var modelSearchLimit = 50

    init(
        settingsStore: SettingsStore = SettingsStore(),
        registry: ModelRegistry = ModelRegistry(),
        environmentManager: PythonEnvironmentManager = PythonEnvironmentManager(),
        cacheManager: MLXModelCacheManager = MLXModelCacheManager(),
        modelSearcher: HuggingFaceModelSearcher = HuggingFaceModelSearcher(),
        modelInstaller: HuggingFaceModelInstaller = HuggingFaceModelInstaller(),
        authChecker: HuggingFaceAuthChecker = HuggingFaceAuthChecker(),
        huggingFaceCacheRoot: URL? = nil,
        serverPoolController: RoleServerPoolController = RoleServerPoolController(),
        telemetry: TelemetryStore? = nil
    ) {
        self.settingsStore = settingsStore
        self.registry = registry
        self.environmentManager = environmentManager
        self.cacheManager = cacheManager
        self.modelSearcher = modelSearcher
        self.modelInstaller = modelInstaller
        self.authChecker = authChecker
        self.configuredHuggingFaceCacheRoot = huggingFaceCacheRoot
        self.serverPoolController = serverPoolController
        self.telemetry = telemetry ?? TelemetryStore(
            logFileURL: environmentManager.paths.logsDirectory.appending(path: "mlxdashboard.log")
        )
        let loadedSettings = (try? settingsStore.load()) ?? DashboardSettings()
        self.settings = loadedSettings
        self.activeModelSelection = ActiveModelSelection(model: loadedSettings.activeModel)
        self.providerDebugCaptureState = ProviderDebugCaptureState(enabled: loadedSettings.providerDebugCaptureEnabled)
        self.providerRoleAssignmentState = ProviderRoleAssignmentState(assignments: loadedSettings.providerRoleAssignments)
        self.providerUpstreamEndpointState = ProviderUpstreamEndpointState()
        self.roleServerStatuses = serverPoolController.roleStatuses
        try? registry.load()
        self.installedModels = Self.visibleInstalledModels(from: registry.records)
        self.providerUpstreamEndpointState.update(
            defaultEndpoint: serverPoolController.defaultEndpoint,
            roleEndpoints: serverPoolController.roleEndpoints
        )
        self.serverPoolControllerCancellable = Publishers.CombineLatest(
            serverPoolController.$state,
            serverPoolController.$roleStatuses
        ).sink { [weak self] _, roleStatuses in
            self?.roleServerStatuses = roleStatuses
        }
    }

    var providerBaseURL: String {
        settings.providerBaseURL.absoluteString
    }

    var providerDebugLogPath: String {
        environmentManager.paths.logsDirectory.appending(path: "provider-debug.jsonl").path
    }

    var canStartProvider: Bool {
        providerServer == nil
    }

    var serverState: ServerState {
        serverPoolController.state
    }

    var canStopProvider: Bool {
        providerServer != nil
    }

    var hasRunningDownloads: Bool {
        isInstallingModel || activeInstallTask != nil
    }

    var canStartServer: Bool {
        ControllerButtonPolicy.canStartServer(state: serverPoolController.state)
    }

    var canStopServer: Bool {
        ControllerButtonPolicy.canStopServer(state: serverPoolController.state)
    }

    var canRestartServer: Bool {
        ControllerButtonPolicy.canRestartServer(state: serverPoolController.state)
    }

    var canLoadMoreSearchResults: Bool {
        !isLoadingMoreSearchResults
            && !searchResults.isEmpty
            && searchResults.count == modelSearchLimit
    }

    var canContinueLastModelInstall: Bool {
        guard !isInstallingModel,
              let progress = modelInstallProgress
        else { return false }
        return progress.phase.canContinueDownloading
    }

    var canRetryLastModelInstallWithoutXet: Bool {
        canContinueLastModelInstall
    }

    var canContinueSelectedInstalledModelInstall: Bool {
        guard !isInstallingModel,
              let selectedInstalledModelID,
              let record = installedModels.first(where: { $0.id == selectedInstalledModelID })
        else { return false }
        return record.status == .failed || record.status == .paused || record.status == .installing
    }

    var canRetrySelectedInstalledModelInstallWithoutXet: Bool {
        canContinueSelectedInstalledModelInstall
    }

    var canSetSelectedInstalledModelActive: Bool {
        selectedInstalledModelIsInstalled
    }

    var canAssignSelectedInstalledModelToProviderRole: Bool {
        selectedInstalledModelIsInstalled
    }

    func saveSettings() {
        do {
            providerDebugCaptureState.update(settings.providerDebugCaptureEnabled)
            providerRoleAssignmentState.update(settings.providerRoleAssignments)
            try settingsStore.save(settings)
            telemetry.appendLog("Saved settings")
        } catch {
            telemetry.appendLog("Failed to save settings: \(error)")
        }
    }

    func setProviderDebugCaptureEnabled(_ enabled: Bool) {
        settings.providerDebugCaptureEnabled = enabled
        providerDebugCaptureState.update(enabled)
        saveSettings()
        telemetry.appendLog(enabled ? "Enabled provider debug payload capture" : "Disabled provider debug payload capture")
    }

    func updateDownloadSettings(_ downloadSettings: HuggingFaceDownloadSettings) {
        settings.downloadSettings = downloadSettings.validated()
        saveSettings()
    }

    func requestModelDownloadSettingsNavigation() {
        modelDownloadSettingsNavigationRequestID += 1
    }

    func refreshPythonStatus() async {
        do {
            let status = try await environmentManager.status()
            pythonStatus = status.isReady ? "Ready: \(status.pythonExecutable.path)" : "Missing: \(status.packageReport.missingInstallNames.joined(separator: ", "))"
        } catch {
            pythonStatus = "Error: \(error)"
        }
    }

    func installPythonPackages() async {
        do {
            try await environmentManager.installRequiredPackages()
            pythonStatus = "Ready"
            shouldOfferPythonPackageInstall = false
            modelSearchMessage = "Python packages installed. Search is ready."
            telemetry.appendLog("Installed Python packages")
        } catch {
            pythonStatus = "Error: \(error)"
            modelSearchMessage = "Python package installation failed: \(error)"
            telemetry.appendLog("Python setup failed: \(error)")
        }
    }

    func startServer() async {
        do {
            let python = try await environmentManager.ensureVenv()
            try serverPoolController.start(settings: settings, pythonExecutable: python)
            roleServerStatuses = serverPoolController.roleStatuses
            updateProviderEndpointState()
            telemetry.appendLog("Started mlx-lm on \(DashboardSettings.localMLXHost):\(settings.mlxPort)")
            try startProvider()
        } catch {
            roleServerStatuses = serverPoolController.roleStatuses
            if serverPoolController.state != .running {
                clearProviderEndpointState()
            }
            telemetry.appendLog("Failed to start server: \(error.localizedDescription)")
        }
    }

    func stopServer() {
        serverPoolController.stopAll()
        roleServerStatuses = serverPoolController.roleStatuses
        clearProviderEndpointState()
        telemetry.appendLog("Stopped mlx-lm")
    }

    func restartServer() async {
        do {
            let python = try await environmentManager.ensureVenv()
            serverPoolController.stopAll()
            roleServerStatuses = serverPoolController.roleStatuses
            clearProviderEndpointState()
            try serverPoolController.start(settings: settings, pythonExecutable: python)
            roleServerStatuses = serverPoolController.roleStatuses
            updateProviderEndpointState()
            telemetry.appendLog("Restarted mlx-lm on \(DashboardSettings.localMLXHost):\(settings.mlxPort)")
        } catch {
            roleServerStatuses = serverPoolController.roleStatuses
            if serverPoolController.state != .running {
                clearProviderEndpointState()
            }
            telemetry.appendLog("Failed to restart server: \(error.localizedDescription)")
        }
    }

    func startProvider() throws {
        guard providerServer == nil else { return }
        let upstream = URLSessionProviderUpstreamProxyClient()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { [activeModelSelection] in activeModelSelection.model },
            roleAssignmentsProvider: { [providerRoleAssignmentState] in providerRoleAssignmentState.assignments },
            defaultEndpointProvider: { [providerUpstreamEndpointState] in
                providerUpstreamEndpointState.defaultEndpoint
            },
            roleEndpointProvider: { [providerUpstreamEndpointState] role in
                providerUpstreamEndpointState.endpoint(for: role)
            },
            eventLogger: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.telemetry.recordRequest(latency: 0)
                    self?.telemetry.appendLog(message)
                }
            },
            debugRecorder: ProviderDebugRecorder(
                fileURL: environmentManager.paths.logsDirectory.appending(path: "provider-debug.jsonl"),
                isEnabled: { [providerDebugCaptureState] in providerDebugCaptureState.isEnabled }
            )
        )
        let server = NIOProviderServer(host: settings.providerHost, port: settings.providerPort, router: router)
        try server.start()
        providerServer = server
        providerStatus = "Running at \(providerBaseURL)"
        telemetry.appendLog("Started provider at \(providerBaseURL)")
    }

    func stopProvider() {
        do {
            try providerServer?.stop()
            providerServer = nil
            providerStatus = "Stopped"
            telemetry.appendLog("Stopped provider")
        } catch {
            telemetry.appendLog("Failed to stop provider: \(error)")
        }
    }

    func stopOwnedServicesBeforeClose() {
        if providerServer != nil {
            stopProvider()
        }
        if canStopServer {
            stopServer()
        }
    }

    private func updateProviderEndpointState() {
        providerUpstreamEndpointState.update(
            defaultEndpoint: serverPoolController.defaultEndpoint,
            roleEndpoints: serverPoolController.roleEndpoints
        )
    }

    private func clearProviderEndpointState() {
        providerUpstreamEndpointState.clear()
    }

    func scanModelCache() {
        do {
            let cached = try cacheManager.scan(cacheRoot: huggingFaceCacheRoot)
            for model in cached {
                registry.upsert(ModelRecord(id: model.id, status: .installed, localPath: model.localPath))
            }
            try registry.save()
            installedModels = Self.visibleInstalledModels(from: registry.records)
            telemetry.appendLog("Scanned Hugging Face cache")
        } catch {
            telemetry.appendLog("Cache scan failed: \(error)")
        }
    }

    func refreshHuggingFaceAuthStatus() async {
        do {
            let status = try await environmentManager.status()
            guard status.isReady else {
                let missingPackages = status.packageReport.missingInstallNames.joined(separator: ", ")
                huggingFaceAuthMessage = "Hugging Face: install packages first (\(missingPackages))"
                return
            }
            let auth = try await authChecker.status(pythonExecutable: status.pythonExecutable)
            huggingFaceAuthMessage = auth.displayText
        } catch {
            huggingFaceAuthMessage = "Hugging Face: unable to check auth - \(error)"
        }
    }

    func searchModels() async {
        modelSearchLimit = modelSearchPageSize
        await runModelSearch(limit: modelSearchLimit, defaultSearch: false)
    }

    func loadMoreSearchResults() async {
        guard canLoadMoreSearchResults else { return }
        let nextLimit = modelSearchLimit + modelSearchPageSize
        isLoadingMoreSearchResults = true
        defer { isLoadingMoreSearchResults = false }
        await runModelSearch(limit: nextLimit, defaultSearch: false)
    }

    private func runModelSearch(limit: Int, defaultSearch: Bool) async {
        do {
            let status = try await environmentManager.status()
            guard status.isReady else {
                let missingPackages = status.packageReport.missingInstallNames.joined(separator: ", ")
                searchResults = []
                shouldOfferPythonPackageInstall = true
                if defaultSearch {
                    modelSearchMessage = "Install Python packages to search default MLX models: \(missingPackages)."
                    telemetry.appendLog("Default model search needs Python packages: \(missingPackages)")
                } else {
                    modelSearchMessage = "Python packages are required before searching: \(missingPackages)."
                    telemetry.appendLog("Model search needs Python packages: \(missingPackages)")
                }
                return
            }

            shouldOfferPythonPackageInstall = false
            searchResults = try await modelSearcher.search(query: modelQuery, pythonExecutable: status.pythonExecutable, limit: limit)
            modelSearchLimit = limit
            modelSearchMessage = searchResultStatusText(count: searchResults.count)
            let logPrefix = defaultSearch ? "Loaded default" : "Found"
            telemetry.appendLog("\(logPrefix) \(searchResults.count) mlx-community models for \(modelQuery)")
        } catch is CancellationError {
            if defaultSearch {
                modelSearchMessage = "Default model search cancelled."
                telemetry.appendLog("Default model search cancelled.")
            } else {
                modelSearchMessage = "Model search cancelled."
                telemetry.appendLog("Model search cancelled.")
            }
        } catch {
            if defaultSearch {
                modelSearchMessage = "Default model search failed: \(error)"
                telemetry.appendLog("Default model search failed: \(error)")
            } else {
                modelSearchMessage = "Model search failed: \(error)"
                telemetry.appendLog("Model search failed: \(error)")
            }
        }
    }

    func searchDefaultModelsIfReady() async {
        do {
            let status = try await environmentManager.status()
            guard ModelDiscoveryPolicy.shouldRunDefaultSearch(
                isReady: status.isReady,
                hasResults: !searchResults.isEmpty
            ) else {
                if !status.isReady {
                    let missingPackages = status.packageReport.missingInstallNames.joined(separator: ", ")
                    searchResults = []
                    shouldOfferPythonPackageInstall = true
                    modelSearchMessage = "Install Python packages to search default MLX models: \(missingPackages)."
                    telemetry.appendLog("Default model search needs Python packages: \(missingPackages)")
                }
                return
            }

            modelSearchLimit = modelSearchPageSize
            await runModelSearch(limit: modelSearchLimit, defaultSearch: true)
        } catch is CancellationError {
            modelSearchMessage = "Default model search cancelled."
            telemetry.appendLog("Default model search cancelled.")
        } catch {
            modelSearchMessage = "Default model search failed: \(error)"
            telemetry.appendLog("Default model search failed: \(error)")
        }
    }

    private func searchResultStatusText(count: Int) -> String {
        let noun = count == 1 ? "result" : "results"
        return "Showing \(count) mlx-community \(noun) sorted by downloads."
    }

    func installModel(
        _ model: HuggingFaceModelSummary,
        isContinuation: Bool = false,
        forceStandardDownload: Bool = false
    ) async {
        let installSessionID = beginInstallSession()
        isInstallingModel = true
        let downloadSettings = forceStandardDownload ? .standardDefault : settings.downloadSettings.validated()
        let downloadEnvironment = downloadSettings.huggingFaceEnvironment
        let downloadEnvironmentRemovals = downloadSettings.huggingFaceEnvironmentRemovals
        let isStandardDownload = downloadSettings.mode == .standard
        defer {
            stopDownloadActivityMonitor(installSessionID: installSessionID)
            finishInstallSession(installSessionID)
            isInstallingModel = false
        }

        do {
            if forceStandardDownload {
                updateInstallProgress(.preparing, modelID: model.id, detail: "Preparing to retry \(model.id) without Xet.")
            } else if isContinuation {
                updateInstallProgress(.preparing, modelID: model.id, detail: "Preparing to continue downloading \(model.id).")
            } else {
                updateInstallProgress(.preparing, modelID: model.id, detail: "Preparing to install \(model.id).")
            }
            updateInstallProgress(.checkingPackages, modelID: model.id, detail: "Checking local Python packages before downloading.")
            let status = try await environmentManager.status()
            guard status.isReady else {
                let missingPackages = status.packageReport.missingInstallNames.joined(separator: ", ")
                shouldOfferPythonPackageInstall = true
                updateInstallProgress(
                    .blocked,
                    modelID: model.id,
                    detail: "Install needs Python packages first: \(missingPackages). Use Install Packages, then try again."
                )
                telemetry.appendLog("Install blocked for \(model.id); missing packages: \(missingPackages)")
                return
            }
            shouldOfferPythonPackageInstall = false

            updateInstallProgress(.checkingLogin, modelID: model.id, detail: "Checking Hugging Face login for \(model.id).")
            let authStatus = try await authChecker.status(pythonExecutable: status.pythonExecutable)
            huggingFaceAuthMessage = authStatus.displayText
            if case .loggedOut = authStatus {
                updateInstallProgress(
                    .checkingLogin,
                    modelID: model.id,
                    detail: "Hugging Face login was not found. Public models can still install; private or gated models may require login."
                )
            }

            registry.upsert(ModelRecord(id: model.id, status: .installing, message: "Installing from Hugging Face"))
            try registry.save()
            installedModels = Self.visibleInstalledModels(from: registry.records)

            let downloadDetail = isContinuation
                ? (isStandardDownload
                    ? "Retrying \(model.id) with standard Hugging Face download. Existing cache files will be reused when available."
                    : "Continuing download for \(model.id). Existing Hugging Face cache files will be reused when available.")
                : (isStandardDownload
                    ? "Downloading \(model.id) with standard Hugging Face download. Large models can take a while."
                    : "Downloading \(model.id). Large models can take a while.")
            updateInstallProgress(.downloading, modelID: model.id, detail: downloadDetail)
            startDownloadActivityMonitor(modelID: model.id, installSessionID: installSessionID)
            let result = try await modelInstaller.install(
                modelID: model.id,
                pythonExecutable: status.pythonExecutable,
                downloadEnvironment: downloadEnvironment,
                downloadEnvironmentRemovals: downloadEnvironmentRemovals,
                progressHandler: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard self?.canApplyDownloadCallback(modelID: model.id, installSessionID: installSessionID) == true else { return }
                        self?.updateInstallProgress(
                            .downloading,
                            modelID: model.id,
                            detail: downloadDetail,
                            downloadProgress: progress
                        )
                    }
                },
                activityHandler: { [weak self] activity in
                    Task { @MainActor [weak self] in
                        self?.appendInstallActivity(activity, modelID: model.id, installSessionID: installSessionID)
                    }
                }
            )
            await Task.yield()
            try Task.checkCancellation()
            updateInstallProgress(.finalizing, modelID: model.id, detail: "Finalizing cache record for \(model.id).")
            registry.upsert(ModelRecord(id: model.id, status: .installed, localPath: result.localPath, message: "Installed"))
            try registry.save()
            installedModels = Self.visibleInstalledModels(from: registry.records)
            scanModelCache()
            updateInstallProgress(.installed, modelID: model.id, detail: "Installed \(model.id) at \(result.localPath)")
            telemetry.appendLog("Installed \(model.id)")
        } catch is CancellationError {
            markModelDownloadPaused(modelID: model.id)
        } catch {
            let message = friendlyInstallMessage(for: error)
            updateInstallProgress(.failed, modelID: model.id, detail: "Install failed for \(model.id): \(message)")
            registry.upsert(ModelRecord(id: model.id, status: .failed, message: message))
            try? registry.save()
            installedModels = Self.visibleInstalledModels(from: registry.records)
            telemetry.appendLog("Install failed for \(model.id): \(error)")
        }
    }

    func installSelectedModel() async {
        guard let selectedSearchModelID,
              let model = searchResults.first(where: { $0.id == selectedSearchModelID })
        else {
            modelInstallProgress = nil
            modelInstallMessage = "Select a model from search results before installing."
            return
        }
        await installModel(model)
    }

    func startSelectedModelInstall() {
        startInstallTask {
            await self.installSelectedModel()
        }
    }

    func continueLastModelInstall() async {
        guard canContinueLastModelInstall,
              let modelID = modelInstallProgress?.modelID
        else {
            modelInstallMessage = "No failed model download is available to continue."
            return
        }
        await installModel(HuggingFaceModelSummary(id: modelID), isContinuation: true)
    }

    func startContinueLastModelInstall() {
        startInstallTask {
            await self.continueLastModelInstall()
        }
    }

    func retryLastModelInstallWithoutXet() async {
        guard canRetryLastModelInstallWithoutXet,
              let modelID = modelInstallProgress?.modelID
        else {
            modelInstallMessage = "No failed or paused model download is available to retry without Xet."
            return
        }
        await installModel(HuggingFaceModelSummary(id: modelID), isContinuation: true, forceStandardDownload: true)
    }

    func startRetryLastModelInstallWithoutXet() {
        startInstallTask {
            await self.retryLastModelInstallWithoutXet()
        }
    }

    func continueSelectedInstalledModelInstall() async {
        guard canContinueSelectedInstalledModelInstall,
              let modelID = selectedInstalledModelID
        else {
            modelInstallProgress = nil
            modelInstallMessage = "Select a failed or incomplete model before continuing."
            return
        }
        await installModel(HuggingFaceModelSummary(id: modelID), isContinuation: true)
    }

    func startContinueSelectedInstalledModelInstall() {
        startInstallTask {
            await self.continueSelectedInstalledModelInstall()
        }
    }

    func retrySelectedInstalledModelInstallWithoutXet() async {
        guard canRetrySelectedInstalledModelInstallWithoutXet,
              let modelID = selectedInstalledModelID
        else {
            modelInstallProgress = nil
            modelInstallMessage = "Select a failed or incomplete model before retrying without Xet."
            return
        }
        await installModel(HuggingFaceModelSummary(id: modelID), isContinuation: true, forceStandardDownload: true)
    }

    func startRetrySelectedInstalledModelInstallWithoutXet() {
        startInstallTask {
            await self.retrySelectedInstalledModelInstallWithoutXet()
        }
    }

    func pauseActiveModelInstall() {
        guard let activeInstallTask,
              let modelID = modelInstallProgress?.modelID
        else {
            modelInstallMessage = "No active model download is running."
            return
        }

        activeInstallTask.cancel()
        markModelDownloadPaused(modelID: modelID)
    }

    func notifyCloseBlockedForRunningDownloads() {
        modelInstallMessage = "A model download is still running. Pause it before closing MLXDashboard."
        telemetry.appendLog("Close prevented while a model download is running")
    }

    func setSelectedInstalledModelActive() {
        guard let selectedInstalledModelID,
              selectedInstalledModelIsInstalled
        else {
            modelInstallMessage = "Select an installed model before setting it active."
            return
        }

        modelInstallProgress = nil
        settings.activeModel = selectedInstalledModelID
        activeModelSelection.update(selectedInstalledModelID)
        saveSettings()
        modelInstallMessage = "Selected \(selectedInstalledModelID) as the active model."
    }

    func assignSelectedInstalledModel(to role: ProviderModelRole) {
        guard let selectedInstalledModelID,
              selectedInstalledModelIsInstalled
        else {
            modelInstallMessage = "Select an installed model before assigning it to \(role.displayName)."
            return
        }

        modelInstallProgress = nil
        settings.providerRoleAssignments.setModel(selectedInstalledModelID, for: role)
        providerRoleAssignmentState.update(settings.providerRoleAssignments)
        saveSettings()
        modelInstallMessage = "Assigned \(selectedInstalledModelID) to \(role.displayName)."
        telemetry.appendLog("Assigned \(selectedInstalledModelID) to provider role \(role.rawValue)")
    }

    func deleteSelectedInstalledModelFromCache() {
        guard let selectedInstalledModelID,
              let record = installedModels.first(where: { $0.id == selectedInstalledModelID })
        else {
            modelInstallProgress = nil
            modelInstallMessage = "Select an installed model before deleting from cache."
            return
        }

        modelInstallProgress = nil
        do {
            _ = try cacheManager.deleteModelCache(
                modelID: record.id,
                localPath: record.localPath,
                cacheRoot: huggingFaceCacheRoot
            )
            registry.markRemoved(id: record.id)
            try registry.save()
            installedModels = Self.visibleInstalledModels(from: registry.records)
            self.selectedInstalledModelID = nil
            if settings.activeModel == record.id {
                settings.activeModel = nil
                activeModelSelection.update(nil)
            }
            if clearProviderRoleAssignments(for: record.id) || settings.activeModel == nil {
                saveSettings()
            }
            modelInstallMessage = "Deleted cache for \(record.id)."
            telemetry.appendLog("Deleted cache for \(record.id)")
        } catch {
            let message = String(describing: error)
            modelInstallMessage = "Could not delete cache for \(record.id): \(message)"
            telemetry.appendLog("Cache delete failed for \(record.id): \(error)")
        }
    }

    private var huggingFaceCacheRoot: URL {
        configuredHuggingFaceCacheRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".cache/huggingface/hub", directoryHint: .isDirectory)
    }

    private func startInstallTask(_ operation: @escaping @MainActor () async -> Void) {
        guard activeInstallTask == nil else {
            modelInstallMessage = "A model download is already running."
            return
        }

        activeInstallTask = Task { @MainActor [weak self] in
            await operation()
            self?.activeInstallTask = nil
        }
    }

    private func beginInstallSession() -> Int {
        installSessionCounter += 1
        activeInstallSessionID = installSessionCounter
        return installSessionCounter
    }

    private func finishInstallSession(_ installSessionID: Int) {
        guard activeInstallSessionID == installSessionID else { return }
        activeInstallSessionID = nil
    }

    private func canApplyDownloadCallback(modelID: String, installSessionID: Int) -> Bool {
        activeInstallSessionID == installSessionID
            && modelInstallProgress?.modelID == modelID
            && modelInstallProgress?.phase == .downloading
    }

    private func updateInstallProgress(
        _ phase: ModelInstallPhase,
        modelID: String,
        detail: String,
        downloadProgress: HuggingFaceDownloadProgress? = nil
    ) {
        let existingProgress = modelInstallProgress?.modelID == modelID ? modelInstallProgress : nil
        if phase == .downloading, existingProgress?.phase.isTerminalInstallPhase == true {
            return
        }
        modelInstallProgress = ModelInstallProgress(
            modelID: modelID,
            phase: phase,
            detail: detail,
            downloadProgress: phase == .downloading ? (downloadProgress ?? existingProgress?.downloadProgress) : downloadProgress,
            cacheSummary: existingProgress?.cacheSummary,
            activities: existingProgress?.activities ?? []
        )
        modelInstallMessage = detail
    }

    private func appendInstallActivity(
        _ activity: HuggingFaceDownloadActivity,
        modelID: String,
        installSessionID: Int? = nil
    ) {
        if let installSessionID {
            guard canApplyDownloadCallback(modelID: modelID, installSessionID: installSessionID) else { return }
        }
        guard let progress = modelInstallProgress,
              progress.modelID == modelID
        else { return }

        modelInstallProgress = progress.appendingActivity(activity)
    }

    private func updateInstallCacheSummary(_ cacheSummary: DownloadCacheSummary, modelID: String) {
        guard var progress = modelInstallProgress,
              progress.modelID == modelID
        else { return }

        progress.cacheSummary = cacheSummary
        modelInstallProgress = progress
    }

    private func startDownloadActivityMonitor(modelID: String, installSessionID: Int) {
        stopDownloadActivityMonitor()
        let cacheRoot = huggingFaceCacheRoot
        let xetLogRoot = cacheRoot
            .deletingLastPathComponent()
            .appending(path: "xet/logs", directoryHint: .isDirectory)
        downloadActivityMonitorTask = Task.detached(priority: .utility) { [weak self, cacheRoot, xetLogRoot] in
            await self?.monitorDownloadActivity(
                modelID: modelID,
                installSessionID: installSessionID,
                cacheRoot: cacheRoot,
                xetLogRoot: xetLogRoot
            )
        }
    }

    private func stopDownloadActivityMonitor(installSessionID: Int? = nil) {
        if let installSessionID, activeInstallSessionID != installSessionID {
            return
        }
        downloadActivityMonitorTask?.cancel()
        downloadActivityMonitorTask = nil
    }

    private nonisolated func monitorDownloadActivity(
        modelID: String,
        installSessionID: Int,
        cacheRoot: URL,
        xetLogRoot: URL
    ) async {
        let cacheSampler = DownloadCacheSampler()
        let xetLogReader = XetLogActivityReader()

        var lastTotalBytes: Int64?
        var lastGrowthDate = Date()
        var warnedAboutNoGrowth = false
        var seenXetActivityKeys = Set<String>()

        while !Task.isCancelled {
            let canContinue = await MainActor.run { [weak self] in
                self?.canApplyDownloadCallback(modelID: modelID, installSessionID: installSessionID) == true
            }
            guard canContinue else { return }

            let now = Date()
            if var summary = try? cacheSampler.summary(modelID: modelID, cacheRoot: cacheRoot) {
                if let previousTotalBytes = lastTotalBytes {
                    if summary.totalBytes > previousTotalBytes {
                        lastGrowthDate = now
                        warnedAboutNoGrowth = false
                    }
                } else {
                    lastGrowthDate = now
                }
                lastTotalBytes = summary.totalBytes

                let secondsSinceGrowth = max(0, Int(now.timeIntervalSince(lastGrowthDate)))
                summary.secondsSinceGrowth = secondsSinceGrowth
                await MainActor.run { [weak self] in
                    guard self?.canApplyDownloadCallback(modelID: modelID, installSessionID: installSessionID) == true else { return }
                    self?.updateInstallCacheSummary(summary, modelID: modelID)
                }

                if secondsSinceGrowth >= 30, !warnedAboutNoGrowth {
                    let activity = HuggingFaceDownloadActivity(
                        message: "No cache growth for \(secondsSinceGrowth)s",
                        tone: .warning,
                        source: .cacheScan
                    )
                    await MainActor.run { [weak self] in
                        self?.appendInstallActivity(activity, modelID: modelID, installSessionID: installSessionID)
                    }
                    warnedAboutNoGrowth = true
                }
            }

            if let activities = try? xetLogReader.activities(logRoot: xetLogRoot) {
                for activity in activities {
                    let key = "\(activity.source.rawValue):\(activity.message)"
                    guard !seenXetActivityKeys.contains(key) else { continue }
                    seenXetActivityKeys.insert(key)
                    await MainActor.run { [weak self] in
                        self?.appendInstallActivity(activity, modelID: modelID, installSessionID: installSessionID)
                    }
                }
            }

            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
        }
    }

    private func markModelDownloadPaused(modelID: String) {
        stopDownloadActivityMonitor()
        let detail = "Paused download for \(modelID). Use Continue Downloading to resume with cached files."
        updateInstallProgress(.paused, modelID: modelID, detail: detail)
        registry.upsert(ModelRecord(id: modelID, status: .paused, message: "Paused; continue downloading to resume"))
        try? registry.save()
        installedModels = Self.visibleInstalledModels(from: registry.records)
        telemetry.appendLog("Paused download for \(modelID)")
    }

    private static func visibleInstalledModels(from records: [ModelRecord]) -> [ModelRecord] {
        records.filter { $0.status != .removed }
    }

    private var selectedInstalledModelIsInstalled: Bool {
        guard let selectedInstalledModelID else { return false }
        return installedModels.contains { $0.id == selectedInstalledModelID && $0.status == .installed }
    }

    private func friendlyInstallMessage(for error: Error) -> String {
        let raw = String(describing: error)
        let lowercased = raw.lowercased()
        if lowercased.contains("401") || lowercased.contains("403") || lowercased.contains("gated") || lowercased.contains("unauthorized") {
            return "Hugging Face denied access. Log in with Hugging Face or request access to the model, then try again. Details: \(raw)"
        }
        if lowercased.contains("no module named") {
            return "A required Python package is missing. Use Install Packages, then try again. Details: \(raw)"
        }
        return raw
    }

    @discardableResult
    private func clearProviderRoleAssignments(for modelID: String) -> Bool {
        var assignments = settings.providerRoleAssignments
        var changed = false
        for role in [ProviderModelRole.ask, .plan, .coding] where assignments.model(for: role) == modelID {
            assignments.setModel(nil, for: role)
            changed = true
        }
        guard changed else { return false }
        settings.providerRoleAssignments = assignments
        providerRoleAssignmentState.update(assignments)
        return true
    }
}

private extension ModelInstallPhase {
    var isTerminalInstallPhase: Bool {
        switch self {
        case .installed, .paused, .blocked, .failed:
            return true
        case .preparing, .checkingPackages, .checkingLogin, .downloading, .finalizing:
            return false
        }
    }
}

private extension ProviderModelRole {
    var displayName: String {
        switch self {
        case .ask:
            "Ask"
        case .plan:
            "Plan"
        case .coding:
            "Fast/Coding"
        }
    }
}
