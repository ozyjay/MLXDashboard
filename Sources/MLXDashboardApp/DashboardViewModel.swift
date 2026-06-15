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

private final class ProviderModelMetadataState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMetadata: [String: ProviderModelMetadata] = [:]

    var metadata: [String: ProviderModelMetadata] {
        lock.withLock { storedMetadata }
    }

    func update(_ metadata: [String: ProviderModelMetadata]) {
        lock.withLock {
            storedMetadata = metadata
        }
    }
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var settings: DashboardSettings
    @Published var pythonStatus = "Not checked"
    @Published var providerStatus = "Stopped"
    @Published var installedModels: [ModelRecord] = []
    @Published var searchResults: [HuggingFaceModelSummary] = []
    @Published var searchResultFamilies: [ModelFamilySearchResult] = []
    @Published var modelQuery = "Devstral-Small"
    @Published var modelSearchMessage: String?
    @Published var modelInstallMessage: String?
    @Published var huggingFaceAuthMessage = "Hugging Face: Not checked"
    @Published var shouldOfferPythonPackageInstall = false
    @Published var selectedSearchModelID: String?
    @Published var selectedSearchFamilyID: String?
    @Published var selectedInstalledModelID: String?
    @Published var isInstallingModel = false
    @Published var isLoadingMoreSearchResults = false
    @Published private(set) var installProgressByModelID: [String: ModelInstallProgress] = [:]
    @Published private(set) var activeInstallModelID: String?
    @Published var modelDownloadSettingsNavigationRequestID = 0
    @Published private(set) var roleServerStatuses: [RoleServerStatusRow]

    let telemetry: TelemetryStore
    let serverPoolController: RoleServerPoolController

    private let settingsStore: SettingsStore
    private let registry: ModelRegistry
    private let environmentManager: PythonEnvironmentManager
    private let cacheManager: MLXModelCacheManager
    private let runtimeCompatibilityChecker: MLXModelRuntimeCompatibilityChecker
    private let modelSearcher: HuggingFaceModelSearcher
    private let modelInstaller: HuggingFaceModelInstaller
    private let authChecker: HuggingFaceAuthChecker
    private let configuredHuggingFaceCacheRoot: URL?
    private let activeModelSelection: ActiveModelSelection
    private let providerDebugCaptureState: ProviderDebugCaptureState
    private let providerRoleAssignmentState: ProviderRoleAssignmentState
    private let providerUpstreamEndpointState: ProviderUpstreamEndpointState
    private let providerModelMetadataState: ProviderModelMetadataState
    private var serverPoolControllerCancellable: AnyCancellable?
    private var providerServer: NIOProviderServer?
    private var activeInstallTask: Task<Void, Never>?
    private var downloadActivityMonitorTask: Task<Void, Never>?
    private var installSessionCounter = 0
    private var activeInstallSessionID: Int?
    private let modelSearchPageSize = 50
    private var modelSearchLimit = 50
    private var rawModelSearchResultCount = 0

    init(
        settingsStore: SettingsStore = SettingsStore(),
        registry: ModelRegistry = ModelRegistry(),
        environmentManager: PythonEnvironmentManager = PythonEnvironmentManager(),
        cacheManager: MLXModelCacheManager = MLXModelCacheManager(),
        runtimeCompatibilityChecker: MLXModelRuntimeCompatibilityChecker = MLXModelRuntimeCompatibilityChecker(),
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
        self.runtimeCompatibilityChecker = runtimeCompatibilityChecker
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
        self.providerModelMetadataState = ProviderModelMetadataState()
        self.roleServerStatuses = serverPoolController.roleStatuses
        try? registry.load()
        let compatibilityChanged = refreshRuntimeCompatibilityForInstalledRecords()
        self.installedModels = Self.visibleInstalledModels(from: registry.records)
        refreshProviderModelMetadataState()
        let settingsChanged = syncRuntimeSelectionsWithRunnableModels()
        if compatibilityChanged {
            try? registry.save()
        }
        if settingsChanged {
            try? settingsStore.save(settings)
        }
        self.providerUpstreamEndpointState.update(
            defaultEndpoint: serverPoolController.defaultEndpoint,
            roleEndpoints: serverPoolController.roleEndpoints
        )
        self.serverPoolControllerCancellable = Publishers.CombineLatest4(
            serverPoolController.$state,
            serverPoolController.$roleStatuses,
            serverPoolController.$defaultEndpoint,
            serverPoolController.$roleEndpoints
        ).sink { [weak self] _, roleStatuses, _, _ in
            self?.roleServerStatuses = roleStatuses
            self?.updateProviderEndpointState()
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

    var modelInstallProgress: ModelInstallProgress? {
        guard let activeInstallModelID else { return nil }
        return installProgressByModelID[activeInstallModelID]
    }

    var selectedInstalledModelProgress: ModelInstallProgress? {
        guard let selectedInstalledModelID else { return nil }
        return installProgressByModelID[selectedInstalledModelID]
    }

    var installedWorkspacePrimaryProgress: ModelInstallProgress? {
        selectedInstalledModelProgress ?? modelInstallProgress
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
            && rawModelSearchResultCount > 0
            && rawModelSearchResultCount == modelSearchLimit
    }

    var canInstallSelectedSearchModel: Bool {
        ModelDiscoveryPolicy.canInstallSelected(
            hasSelection: selectedSearchModelID != nil,
            isInstalling: isInstallingModel,
            isSelectedInstalled: selectedSearchModelIsInstalled
        )
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
            activeModelSelection.update(settings.activeModel)
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
            if syncRuntimeSelectionsWithRunnableModels() {
                try? settingsStore.save(settings)
            }
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

    func stopRoleServer(_ role: ProviderModelRole) {
        serverPoolController.stop(role: role)
        roleServerStatuses = serverPoolController.roleStatuses
        updateProviderEndpointState()
        telemetry.appendLog("Stopped \(role.displayName.lowercased()) role server")
    }

    func restartServer() async {
        do {
            if syncRuntimeSelectionsWithRunnableModels() {
                try? settingsStore.save(settings)
            }
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

    func restartRoleServer(_ role: ProviderModelRole) async {
        do {
            let python = try await environmentManager.ensureVenv()
            try serverPoolController.restart(role: role, settings: settings, pythonExecutable: python)
            roleServerStatuses = serverPoolController.roleStatuses
            updateProviderEndpointState()
            let status = serverPoolController.status(for: role)
            if status.endpoint != nil, status.kind == .running || status.kind == .shared {
                telemetry.appendLog("Restarted \(role.displayName) role server")
            } else {
                telemetry.appendLog("Could not restart \(role.displayName) role server: \(status.detail)")
            }
        } catch {
            roleServerStatuses = serverPoolController.roleStatuses
            updateProviderEndpointState()
            telemetry.appendLog("Failed to restart \(role.displayName) role server: \(error.localizedDescription)")
        }
    }

    func startProvider() throws {
        guard providerServer == nil else { return }
        if syncRuntimeSelectionsWithRunnableModels() {
            try? settingsStore.save(settings)
        }
        let upstream = URLSessionProviderUpstreamProxyClient()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { [activeModelSelection] in activeModelSelection.model },
            modelMetadataProvider: { [providerModelMetadataState] in
                providerModelMetadataState.metadata
            },
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
                registry.upsert(runtimeCheckedRecord(id: model.id, localPath: model.localPath))
            }
            try registry.save()
            installedModels = Self.visibleInstalledModels(from: registry.records)
            refreshProviderModelMetadataState()
            rebuildSearchResultFamilies()
            if syncRuntimeSelectionsWithRunnableModels() {
                try? settingsStore.save(settings)
            }
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
                searchResultFamilies = []
                rawModelSearchResultCount = 0
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
            let rawResults = try await modelSearcher.search(query: modelQuery, pythonExecutable: status.pythonExecutable, limit: limit)
            let filteredResults = runnableSearchResults(from: rawResults)
            searchResults = filteredResults
            rebuildSearchResultFamilies()
            rawModelSearchResultCount = rawResults.count
            modelSearchLimit = limit
            let unsupportedCount = rawResults.count - filteredResults.count
            modelSearchMessage = searchResultStatusText(count: searchResultFamilies.count, unsupportedCount: unsupportedCount)
            let logPrefix = defaultSearch ? "Loaded default" : "Found"
            telemetry.appendLog("\(logPrefix) \(searchResultFamilies.count) mlx-community model families for \(modelQuery)")
        } catch is CancellationError {
            rawModelSearchResultCount = 0
            searchResultFamilies = []
            if defaultSearch {
                modelSearchMessage = "Default model search cancelled."
                telemetry.appendLog("Default model search cancelled.")
            } else {
                modelSearchMessage = "Model search cancelled."
                telemetry.appendLog("Model search cancelled.")
            }
        } catch {
            rawModelSearchResultCount = 0
            searchResultFamilies = []
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
                    searchResultFamilies = []
                    rawModelSearchResultCount = 0
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
        searchResultStatusText(count: count, unsupportedCount: 0)
    }

    private func searchResultStatusText(count: Int, unsupportedCount: Int) -> String {
        let noun = count == 1 ? "result" : "results"
        let base = "Showing \(count) mlx-community \(noun) sorted by downloads"
        guard unsupportedCount > 0 else {
            return "\(base)."
        }
        return "\(base); filtered \(unsupportedCount) unsupported by current mlx-lm."
    }

    private func runnableSearchResults(from results: [HuggingFaceModelSummary]) -> [HuggingFaceModelSummary] {
        results.filter { model in
            runtimeCompatibilityChecker.compatibility(modelType: model.modelType).isRunnable
        }
    }

    private func rebuildSearchResultFamilies() {
        let selectedVariants = Dictionary(uniqueKeysWithValues: searchResultFamilies.map { ($0.id, $0.selectedVariantID) })
        searchResultFamilies = ModelSearchGrouping.group(
            searchResults,
            installedModels: installedModels,
            selectedVariants: selectedVariants,
            installingModelID: modelInstallProgress?.modelID
        )
        guard !searchResultFamilies.isEmpty else {
            selectedSearchFamilyID = nil
            selectedSearchModelID = nil
            return
        }

        let selectedFamily = selectedSearchFamilyID.flatMap { familyID in
            searchResultFamilies.first { $0.id == familyID }
        } ?? searchResultFamilies[0]
        selectedSearchFamilyID = selectedFamily.id
        selectedSearchModelID = selectedFamily.selectedVariantID
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
            rebuildSearchResultFamilies()

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
            let record = runtimeCheckedRecord(id: model.id, localPath: result.localPath)
            registry.upsert(record)
            try registry.save()
            installedModels = Self.visibleInstalledModels(from: registry.records)
            refreshProviderModelMetadataState()
            rebuildSearchResultFamilies()
            scanModelCache()
            if record.status == .installed {
                updateInstallProgress(.installed, modelID: model.id, detail: "Installed \(model.id) at \(result.localPath)")
                telemetry.appendLog("Installed \(model.id)")
            } else {
                updateInstallProgress(.failed, modelID: model.id, detail: "Installed cache for \(model.id), but it is not runnable: \(record.message ?? "unsupported by installed mlx-lm")")
                modelInstallMessage = record.message
                telemetry.appendLog("Installed cache for \(model.id), but it is not runnable: \(record.message ?? "unsupported by installed mlx-lm")")
            }
        } catch is CancellationError {
            markModelDownloadPaused(modelID: model.id)
        } catch {
            let message = friendlyInstallMessage(for: error)
            updateInstallProgress(.failed, modelID: model.id, detail: "Install failed for \(model.id): \(message)")
            registry.upsert(ModelRecord(id: model.id, status: .failed, message: message))
            refreshProviderModelMetadataState()
            try? registry.save()
            installedModels = Self.visibleInstalledModels(from: registry.records)
            rebuildSearchResultFamilies()
            telemetry.appendLog("Install failed for \(model.id): \(error)")
        }
    }

    func installSelectedModel() async {
        guard let selectedSearchModelID,
              let model = searchResults.first(where: { $0.id == selectedSearchModelID })
        else {
            modelInstallMessage = "Select a model from search results before installing."
            return
        }
        await installModel(model)
    }

    func selectSearchVariant(familyID: String, variantID: String) {
        guard let familyIndex = searchResultFamilies.firstIndex(where: { $0.id == familyID }),
              searchResultFamilies[familyIndex].variants.contains(where: { $0.id == variantID })
        else { return }

        searchResultFamilies[familyIndex].selectedVariantID = variantID
        selectedSearchFamilyID = familyID
        selectedSearchModelID = variantID
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
            modelInstallMessage = "Select an installed model before deleting from cache."
            return
        }

        clearInstallProgress(for: selectedInstalledModelID)
        do {
            _ = try cacheManager.deleteModelCache(
                modelID: record.id,
                localPath: record.localPath,
                cacheRoot: huggingFaceCacheRoot
            )
            registry.markRemoved(id: record.id)
            try registry.save()
            installedModels = Self.visibleInstalledModels(from: registry.records)
            refreshProviderModelMetadataState()
            rebuildSearchResultFamilies()
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

    func setInstallProgressForTesting(_ progress: ModelInstallProgress, makeActive: Bool = true) {
        setInstallProgress(progress, makeActive: makeActive)
    }

    private func setInstallProgress(_ progress: ModelInstallProgress, makeActive: Bool) {
        installProgressByModelID[progress.modelID] = progress
        if makeActive {
            activeInstallModelID = progress.modelID
        }
    }

    private func clearInstallProgress(for modelID: String) {
        installProgressByModelID[modelID] = nil
        if activeInstallModelID == modelID {
            activeInstallModelID = nil
        }
    }

    private func clearActiveInstallProgress() {
        guard let activeInstallModelID else { return }
        clearInstallProgress(for: activeInstallModelID)
    }

    private func canApplyDownloadCallback(modelID: String, installSessionID: Int) -> Bool {
        activeInstallSessionID == installSessionID
            && activeInstallModelID == modelID
            && installProgressByModelID[modelID]?.phase == .downloading
    }

    private func updateInstallProgress(
        _ phase: ModelInstallPhase,
        modelID: String,
        detail: String,
        downloadProgress: HuggingFaceDownloadProgress? = nil
    ) {
        let existingProgress = installProgressByModelID[modelID]
        if phase == .downloading, existingProgress?.phase.isTerminalInstallPhase == true {
            return
        }
        let progress = ModelInstallProgress(
            modelID: modelID,
            phase: phase,
            detail: detail,
            downloadProgress: phase == .downloading ? (downloadProgress ?? existingProgress?.downloadProgress) : downloadProgress,
            cacheSummary: existingProgress?.cacheSummary,
            activities: existingProgress?.activities ?? []
        )
        setInstallProgress(progress, makeActive: true)
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
        guard let progress = installProgressByModelID[modelID] else { return }

        setInstallProgress(progress.appendingActivity(activity), makeActive: activeInstallModelID == modelID)
    }

    private func updateInstallCacheSummary(_ cacheSummary: DownloadCacheSummary, modelID: String) {
        guard var progress = installProgressByModelID[modelID] else { return }

        progress.cacheSummary = cacheSummary
        setInstallProgress(progress, makeActive: activeInstallModelID == modelID)
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
        rebuildSearchResultFamilies()
        telemetry.appendLog("Paused download for \(modelID)")
    }

    private static func visibleInstalledModels(from records: [ModelRecord]) -> [ModelRecord] {
        records.filter { $0.status != .removed }
    }

    @discardableResult
    private func refreshRuntimeCompatibilityForInstalledRecords() -> Bool {
        var changed = false
        for record in registry.records where record.status == .installed {
            let checked = runtimeCheckedRecord(id: record.id, localPath: record.localPath)
            if checked.status != record.status || checked.message != record.message {
                registry.upsert(checked)
                changed = true
            }
        }
        return changed
    }

    private func runtimeCheckedRecord(id: String, localPath: String?) -> ModelRecord {
        switch runtimeCompatibilityChecker.compatibility(localPath: localPath) {
        case .runnable:
            return ModelRecord(id: id, status: .installed, localPath: localPath, message: "Installed")
        case .unsupported(_, let reason):
            return ModelRecord(id: id, status: .failed, localPath: localPath, message: reason)
        }
    }

    private func refreshProviderModelMetadataState() {
        let metadata = registry.records.reduce(into: [String: ProviderModelMetadata]()) { result, record in
            guard record.status == .installed || record.localPath != nil else { return }
            switch runtimeCompatibilityChecker.compatibility(localPath: record.localPath) {
            case .runnable(let modelType):
                result[record.id] = .inferred(modelID: record.id, modelType: modelType)
            case .unsupported(let modelType, let reason):
                result[record.id] = .inferred(
                    modelID: record.id,
                    modelType: modelType,
                    state: .unsupported,
                    unsupportedReason: reason
                )
            }
        }
        providerModelMetadataState.update(metadata)
    }

    @discardableResult
    private func syncRuntimeSelectionsWithRunnableModels() -> Bool {
        var changed = false

        if let activeModel = settings.activeModel,
           modelIsKnownNonRunnable(activeModel) {
            settings.activeModel = nil
            activeModelSelection.update(nil)
            changed = true
        } else {
            activeModelSelection.update(settings.activeModel)
        }

        var assignments = settings.providerRoleAssignments
        for role in ProviderModelRole.orderedRoutingRoles {
            guard let model = assignments.model(for: role),
                  modelIsKnownNonRunnable(model)
            else { continue }
            assignments.setModel(nil, for: role)
            changed = true
        }

        if assignments != settings.providerRoleAssignments {
            settings.providerRoleAssignments = assignments
            providerRoleAssignmentState.update(assignments)
        } else {
            providerRoleAssignmentState.update(settings.providerRoleAssignments)
        }

        return changed
    }

    private func modelIsKnownNonRunnable(_ modelID: String) -> Bool {
        guard let record = registry.record(id: modelID) else {
            return false
        }
        return record.status != .installed
    }

    private var selectedInstalledModelIsInstalled: Bool {
        guard let selectedInstalledModelID else { return false }
        return installedModels.contains { $0.id == selectedInstalledModelID && $0.status == .installed }
    }

    private var installedModelIDs: Set<String> {
        Set(installedModels.filter { $0.status == .installed }.map(\.id))
    }

    private var selectedSearchModelIsInstalled: Bool {
        guard let selectedSearchModelID else { return false }
        return installedModelIDs.contains(selectedSearchModelID)
    }

    func searchResultAction(for modelID: String) -> ModelSearchResultAction {
        ModelDiscoveryPolicy.searchResultAction(
            modelID: modelID,
            installedModelIDs: installedModelIDs,
            installingModelID: modelInstallProgress?.modelID,
            isInstalling: isInstallingModel
        )
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
