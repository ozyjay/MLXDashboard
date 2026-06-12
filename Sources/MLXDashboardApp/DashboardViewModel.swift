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
    @Published var shouldOfferPythonPackageInstall = false

    let telemetry = TelemetryStore()
    let serverController = ServerProcessController()

    private let settingsStore: SettingsStore
    private let tokenStore: ProviderTokenStoring
    private let registry: ModelRegistry
    private let environmentManager: PythonEnvironmentManager
    private let cacheScanner = MLXModelCacheScanner()
    private let modelSearcher = HuggingFaceModelSearcher()
    private let modelInstaller = HuggingFaceModelInstaller()
    private var providerServer: NIOProviderServer?

    init(
        settingsStore: SettingsStore = SettingsStore(),
        tokenStore: ProviderTokenStoring = KeychainProviderTokenStore(),
        registry: ModelRegistry = ModelRegistry(),
        environmentManager: PythonEnvironmentManager = PythonEnvironmentManager()
    ) {
        self.settingsStore = settingsStore
        self.tokenStore = tokenStore
        self.registry = registry
        self.environmentManager = environmentManager
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
            let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".cache/huggingface/hub", directoryHint: .isDirectory)
            let cached = try cacheScanner.scan(cacheRoot: cacheRoot)
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
        do {
            registry.upsert(ModelRecord(id: model.id, status: .installing, message: "Installing from Hugging Face"))
            try registry.save()
            installedModels = registry.records

            let python = try await environmentManager.ensureVenv()
            try await modelInstaller.install(modelID: model.id, pythonExecutable: python)
            registry.upsert(ModelRecord(id: model.id, status: .installed, message: "Installed"))
            try registry.save()
            installedModels = registry.records
            scanModelCache()
            telemetry.appendLog("Installed \(model.id)")
        } catch {
            registry.upsert(ModelRecord(id: model.id, status: .failed, message: String(describing: error)))
            try? registry.save()
            installedModels = registry.records
            telemetry.appendLog("Install failed for \(model.id): \(error)")
        }
    }
}
