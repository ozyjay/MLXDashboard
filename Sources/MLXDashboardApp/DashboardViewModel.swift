import Foundation
import Combine
import MLXCore
import MLXPythonBridge
import MLXProviderServer
import MLXServerControl

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var settings: DashboardSettings
    @Published var tokenPreview = ""
    @Published var pythonStatus = "Not checked"
    @Published var providerStatus = "Stopped"
    @Published var installedModels: [ModelRecord] = []
    @Published var searchResults: [HuggingFaceModelSummary] = []
    @Published var modelQuery = "mlx-community"
    @Published var modelSearchMessage: String?
    @Published var modelInstallMessage: String?
    @Published var huggingFaceAuthMessage = "Hugging Face: Not checked"
    @Published var shouldOfferPythonPackageInstall = false
    @Published var selectedSearchModelID: String?
    @Published var selectedInstalledModelID: String?
    @Published var isInstallingModel = false

    let telemetry = TelemetryStore()
    let serverController = ServerProcessController()

    private let settingsStore: SettingsStore
    private let tokenStore: ProviderTokenStoring
    private let registry: ModelRegistry
    private let environmentManager: PythonEnvironmentManager
    private let cacheManager: MLXModelCacheManager
    private let modelSearcher: HuggingFaceModelSearcher
    private let modelInstaller: HuggingFaceModelInstaller
    private let authChecker: HuggingFaceAuthChecker
    private let configuredHuggingFaceCacheRoot: URL?
    private var providerServer: NIOProviderServer?

    init(
        settingsStore: SettingsStore = SettingsStore(),
        tokenStore: ProviderTokenStoring = KeychainProviderTokenStore(),
        registry: ModelRegistry = ModelRegistry(),
        environmentManager: PythonEnvironmentManager = PythonEnvironmentManager(),
        cacheManager: MLXModelCacheManager = MLXModelCacheManager(),
        modelSearcher: HuggingFaceModelSearcher = HuggingFaceModelSearcher(),
        modelInstaller: HuggingFaceModelInstaller = HuggingFaceModelInstaller(),
        authChecker: HuggingFaceAuthChecker = HuggingFaceAuthChecker(),
        huggingFaceCacheRoot: URL? = nil
    ) {
        self.settingsStore = settingsStore
        self.tokenStore = tokenStore
        self.registry = registry
        self.environmentManager = environmentManager
        self.cacheManager = cacheManager
        self.modelSearcher = modelSearcher
        self.modelInstaller = modelInstaller
        self.authChecker = authChecker
        self.configuredHuggingFaceCacheRoot = huggingFaceCacheRoot
        self.settings = (try? settingsStore.load()) ?? DashboardSettings()
        try? registry.load()
        self.installedModels = registry.records
        self.tokenPreview = (try? tokenStore.token()) ?? ""
    }

    var providerBaseURL: String {
        settings.providerBaseURL.absoluteString
    }

    func saveSettings() {
        do {
            try settingsStore.save(settings)
            telemetry.appendLog("Saved settings")
        } catch {
            telemetry.appendLog("Failed to save settings: \(error)")
        }
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
            try serverController.start(settings: settings, pythonExecutable: python)
            telemetry.appendLog("Started mlx-lm on \(settings.mlxHost):\(settings.mlxPort)")
            try startProvider()
        } catch {
            telemetry.appendLog("Failed to start server: \(error)")
        }
    }

    func stopServer() {
        serverController.stop()
        telemetry.appendLog("Stopped mlx-lm")
    }

    func startProvider() throws {
        guard providerServer == nil else { return }
        let upstream = URLSessionProviderUpstreamClient { [settings] in
            settings.mlxBaseURL
        }
        let router = ProviderRouter(
            tokenProvider: { [tokenStore] in try tokenStore.token() },
            upstream: upstream
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

    func regenerateToken() {
        do {
            tokenPreview = try tokenStore.regenerateToken()
            telemetry.appendLog("Regenerated provider token")
        } catch {
            telemetry.appendLog("Token regeneration failed: \(error)")
        }
    }

    func scanModelCache() {
        do {
            let cached = try cacheManager.scan(cacheRoot: huggingFaceCacheRoot)
            for model in cached {
                registry.upsert(ModelRecord(id: model.id, status: .installed, localPath: model.localPath))
            }
            try registry.save()
            installedModels = registry.records
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
        do {
            let status = try await environmentManager.status()
            guard status.isReady else {
                let missingPackages = status.packageReport.missingInstallNames.joined(separator: ", ")
                searchResults = []
                shouldOfferPythonPackageInstall = true
                modelSearchMessage = "Python packages are required before searching: \(missingPackages)."
                telemetry.appendLog("Model search needs Python packages: \(missingPackages)")
                return
            }

            shouldOfferPythonPackageInstall = false
            modelSearchMessage = nil
            searchResults = try await modelSearcher.search(query: modelQuery, pythonExecutable: status.pythonExecutable)
            telemetry.appendLog("Found \(searchResults.count) Hugging Face models for \(modelQuery)")
        } catch {
            modelSearchMessage = "Model search failed: \(error)"
            telemetry.appendLog("Model search failed: \(error)")
        }
    }

    func installModel(_ model: HuggingFaceModelSummary) async {
        isInstallingModel = true
        defer { isInstallingModel = false }

        do {
            modelInstallMessage = "Preparing to install \(model.id)..."
            let status = try await environmentManager.status()
            guard status.isReady else {
                let missingPackages = status.packageReport.missingInstallNames.joined(separator: ", ")
                shouldOfferPythonPackageInstall = true
                modelInstallMessage = "Install needs Python packages first: \(missingPackages). Use Install Packages, then try again."
                telemetry.appendLog("Install blocked for \(model.id); missing packages: \(missingPackages)")
                return
            }
            shouldOfferPythonPackageInstall = false

            modelInstallMessage = "Checking Hugging Face login for \(model.id)..."
            let authStatus = try await authChecker.status(pythonExecutable: status.pythonExecutable)
            huggingFaceAuthMessage = authStatus.displayText
            if case .loggedOut = authStatus {
                modelInstallMessage = "Hugging Face login was not found. Public models can still install; private or gated models may require login."
            }

            registry.upsert(ModelRecord(id: model.id, status: .installing, message: "Installing from Hugging Face"))
            try registry.save()
            installedModels = registry.records

            modelInstallMessage = "Downloading \(model.id). Large models can take a while."
            let result = try await modelInstaller.install(modelID: model.id, pythonExecutable: status.pythonExecutable)
            registry.upsert(ModelRecord(id: model.id, status: .installed, localPath: result.localPath, message: "Installed"))
            try registry.save()
            installedModels = registry.records
            scanModelCache()
            modelInstallMessage = "Installed \(model.id) at \(result.localPath)"
            telemetry.appendLog("Installed \(model.id)")
        } catch {
            let message = friendlyInstallMessage(for: error)
            modelInstallMessage = "Install failed for \(model.id): \(message)"
            registry.upsert(ModelRecord(id: model.id, status: .failed, message: message))
            try? registry.save()
            installedModels = registry.records
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

    func setSelectedInstalledModelActive() {
        guard let selectedInstalledModelID,
              installedModels.contains(where: { $0.id == selectedInstalledModelID && $0.status == .installed })
        else {
            modelInstallMessage = "Select an installed model before setting it active."
            return
        }

        settings.activeModel = selectedInstalledModelID
        saveSettings()
        modelInstallMessage = "Selected \(selectedInstalledModelID) as the active model."
    }

    func deleteSelectedInstalledModelFromCache() {
        guard let selectedInstalledModelID,
              let record = installedModels.first(where: { $0.id == selectedInstalledModelID })
        else {
            modelInstallMessage = "Select an installed model before deleting from cache."
            return
        }

        do {
            _ = try cacheManager.deleteModelCache(
                modelID: record.id,
                localPath: record.localPath,
                cacheRoot: huggingFaceCacheRoot
            )
            registry.markRemoved(id: record.id)
            try registry.save()
            installedModels = registry.records
            if settings.activeModel == record.id {
                settings.activeModel = nil
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
}
