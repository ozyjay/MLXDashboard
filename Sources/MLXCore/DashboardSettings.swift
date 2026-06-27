import Foundation

public enum ProviderModelRole: String, Codable, Equatable, Sendable {
    case ask
    case plan
    case coding

    public static let orderedRoutingRoles: [ProviderModelRole] = [.ask, .plan, .coding]

    public var displayName: String {
        switch self {
        case .ask:
            "Ask"
        case .plan:
            "Plan"
        case .coding:
            "Coding"
        }
    }
}

public struct ProviderRoleAssignments: Codable, Equatable, Sendable {
    public var ask: String?
    public var plan: String?
    public var coding: String?

    public init(ask: String? = nil, plan: String? = nil, coding: String? = nil) {
        self.ask = ask
        self.plan = plan
        self.coding = coding
    }

    public func model(for role: ProviderModelRole) -> String? {
        switch role {
        case .ask:
            ask
        case .plan:
            plan
        case .coding:
            coding
        }
    }

    public mutating func setModel(_ model: String?, for role: ProviderModelRole) {
        switch role {
        case .ask:
            ask = model
        case .plan:
            plan = model
        case .coding:
            coding = model
        }
    }
}

public struct ProviderGenerationSettings: Codable, Equatable, Sendable {
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int

    public init(temperature: Double, topP: Double, maxTokens: Int) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }

    public func validated() -> ProviderGenerationSettings {
        ProviderGenerationSettings(
            temperature: Self.clamp(temperature, lower: 0, upper: 2),
            topP: Self.clamp(topP, lower: 0.01, upper: 1),
            maxTokens: Self.clamp(maxTokens, lower: 1, upper: 32_768)
        )
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private static func clamp(_ value: Int, lower: Int, upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}

public struct ProviderRoleGenerationDefaults: Codable, Equatable, Sendable {
    public static let recommendedDefault = ProviderRoleGenerationDefaults()

    public var ask: ProviderGenerationSettings
    public var plan: ProviderGenerationSettings
    public var coding: ProviderGenerationSettings

    public init(
        ask: ProviderGenerationSettings = ProviderGenerationSettings(temperature: 0.3, topP: 0.9, maxTokens: 2048),
        plan: ProviderGenerationSettings = ProviderGenerationSettings(temperature: 0.2, topP: 0.95, maxTokens: 4096),
        coding: ProviderGenerationSettings = ProviderGenerationSettings(temperature: 0.0, topP: 1.0, maxTokens: 2048)
    ) {
        self.ask = ask.validated()
        self.plan = plan.validated()
        self.coding = coding.validated()
    }

    private enum CodingKeys: String, CodingKey {
        case ask
        case plan
        case coding
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ask: try container.decodeIfPresent(ProviderGenerationSettings.self, forKey: .ask)
                ?? Self.recommendedDefault.ask,
            plan: try container.decodeIfPresent(ProviderGenerationSettings.self, forKey: .plan)
                ?? Self.recommendedDefault.plan,
            coding: try container.decodeIfPresent(ProviderGenerationSettings.self, forKey: .coding)
                ?? Self.recommendedDefault.coding
        )
    }

    public func settings(for role: ProviderModelRole) -> ProviderGenerationSettings {
        switch role {
        case .ask:
            ask
        case .plan:
            plan
        case .coding:
            coding
        }
    }

    public mutating func setSettings(_ settings: ProviderGenerationSettings, for role: ProviderModelRole) {
        switch role {
        case .ask:
            ask = settings.validated()
        case .plan:
            plan = settings.validated()
        case .coding:
            coding = settings.validated()
        }
    }
}

public struct TextDiffusionGenerationSettings: Codable, Equatable, Sendable {
    public var mode: TextGenerationMode
    public var steps: Int
    public var blockLength: Int
    public var threshold: Double
    public var algorithm: String
    public var seed: Int?

    public init(
        mode: TextGenerationMode = .diffusion,
        steps: Int = 64,
        blockLength: Int = 32,
        threshold: Double = 0.9,
        algorithm: String = "entropy",
        seed: Int? = nil
    ) {
        self.mode = mode
        self.steps = steps
        self.blockLength = blockLength
        self.threshold = threshold
        self.algorithm = algorithm
        self.seed = seed
    }

    public func validated() -> TextDiffusionGenerationSettings {
        TextDiffusionGenerationSettings(
            mode: mode,
            steps: min(max(steps, 1), 4096),
            blockLength: min(max(blockLength, 1), 4096),
            threshold: min(max(threshold, 0), 1),
            algorithm: algorithm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "entropy" : algorithm,
            seed: seed
        )
    }
}

public enum HuggingFaceDownloadMode: String, Codable, CaseIterable, Equatable, Sendable {
    case standard
    case xetConservative
    case xetCustom

    public var displayName: String {
        switch self {
        case .standard:
            "Standard download"
        case .xetConservative:
            "Xet conservative"
        case .xetCustom:
            "Xet custom"
        }
    }
}

public struct HuggingFaceDownloadSettings: Codable, Equatable, Sendable {
    public static let standardDefault = HuggingFaceDownloadSettings()
    public static let conservativeDefault = HuggingFaceDownloadSettings(mode: .xetConservative)

    public var mode: HuggingFaceDownloadMode
    public var xetConcurrency: Int
    public var downloadTimeoutSeconds: Int
    public var etagTimeoutSeconds: Int

    public init(
        mode: HuggingFaceDownloadMode = .standard,
        xetConcurrency: Int = 4,
        downloadTimeoutSeconds: Int = 60,
        etagTimeoutSeconds: Int = 30
    ) {
        self.mode = mode
        self.xetConcurrency = xetConcurrency
        self.downloadTimeoutSeconds = downloadTimeoutSeconds
        self.etagTimeoutSeconds = etagTimeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case xetConcurrency
        case downloadTimeoutSeconds
        case etagTimeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = HuggingFaceDownloadSettings(
            mode: try container.decodeIfPresent(HuggingFaceDownloadMode.self, forKey: .mode) ?? .standard,
            xetConcurrency: try container.decodeIfPresent(Int.self, forKey: .xetConcurrency) ?? 4,
            downloadTimeoutSeconds: try container.decodeIfPresent(Int.self, forKey: .downloadTimeoutSeconds) ?? 60,
            etagTimeoutSeconds: try container.decodeIfPresent(Int.self, forKey: .etagTimeoutSeconds) ?? 30
        ).validated()
    }

    public func validated() -> HuggingFaceDownloadSettings {
        HuggingFaceDownloadSettings(
            mode: mode,
            xetConcurrency: Self.clamp(xetConcurrency, lower: 1, upper: 16),
            downloadTimeoutSeconds: Self.clamp(downloadTimeoutSeconds, lower: 10, upper: 600),
            etagTimeoutSeconds: Self.clamp(etagTimeoutSeconds, lower: 5, upper: 120)
        )
    }

    public var huggingFaceEnvironment: [String: String] {
        let settings = validated()
        switch settings.mode {
        case .standard:
            return ["HF_HUB_DISABLE_XET": "1"]
        case .xetConservative:
            return [
                "HF_XET_NUM_CONCURRENT_RANGE_GETS": "4",
                "HF_HUB_DOWNLOAD_TIMEOUT": "60",
                "HF_HUB_ETAG_TIMEOUT": "30"
            ]
        case .xetCustom:
            return [
                "HF_XET_NUM_CONCURRENT_RANGE_GETS": String(settings.xetConcurrency),
                "HF_HUB_DOWNLOAD_TIMEOUT": String(settings.downloadTimeoutSeconds),
                "HF_HUB_ETAG_TIMEOUT": String(settings.etagTimeoutSeconds)
            ]
        }
    }

    public var huggingFaceEnvironmentRemovals: [String] {
        switch mode {
        case .standard:
            []
        case .xetConservative, .xetCustom:
            ["HF_HUB_DISABLE_XET"]
        }
    }

    private static func clamp(_ value: Int, lower: Int, upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}

public struct DashboardSettings: Codable, Equatable, Sendable {
    public static let localMLXHost = "127.0.0.1"

    public var activeModel: String?
    public var mlxHost: String
    public var mlxPort: Int
    public var providerHost: String
    public var providerPort: Int
    public var serverFlags: [String]
    public var providerDebugCaptureEnabled: Bool
    public var providerRoleAssignments: ProviderRoleAssignments
    public var providerGenerationDefaults: ProviderRoleGenerationDefaults
    public var textDiffusionDefaults: TextDiffusionGenerationSettings
    public var modeAdviceStrategy: ModeAdviceStrategy
    public var modeAdviceModel: String?
    public var modelRuntimeOverrides: [String: ModelRuntimeOverride]
    public var residentModelMemoryBudgetGB: Double
    public var maxResidentModelProcesses: Int
    public var downloadSettings: HuggingFaceDownloadSettings

    public init(
        activeModel: String? = nil,
        mlxHost: String = DashboardSettings.localMLXHost,
        mlxPort: Int = 8080,
        providerHost: String = DashboardSettings.localMLXHost,
        providerPort: Int = 8123,
        serverFlags: [String] = [],
        providerDebugCaptureEnabled: Bool = false,
        providerRoleAssignments: ProviderRoleAssignments = ProviderRoleAssignments(),
        providerGenerationDefaults: ProviderRoleGenerationDefaults = .recommendedDefault,
        textDiffusionDefaults: TextDiffusionGenerationSettings = TextDiffusionGenerationSettings(),
        modeAdviceStrategy: ModeAdviceStrategy = .automatic,
        modeAdviceModel: String? = nil,
        modelRuntimeOverrides: [String: ModelRuntimeOverride] = [:],
        residentModelMemoryBudgetGB: Double = 42,
        maxResidentModelProcesses: Int = 2,
        downloadSettings: HuggingFaceDownloadSettings = .standardDefault
    ) {
        self.activeModel = activeModel
        self.mlxHost = Self.localMLXHost
        self.mlxPort = mlxPort
        self.providerHost = Self.localMLXHost
        self.providerPort = providerPort
        self.serverFlags = serverFlags
        self.providerDebugCaptureEnabled = providerDebugCaptureEnabled
        self.providerRoleAssignments = providerRoleAssignments
        self.providerGenerationDefaults = providerGenerationDefaults
        self.textDiffusionDefaults = textDiffusionDefaults.validated()
        self.modeAdviceStrategy = modeAdviceStrategy
        self.modeAdviceModel = modeAdviceModel
        self.modelRuntimeOverrides = modelRuntimeOverrides
        self.residentModelMemoryBudgetGB = min(max(residentModelMemoryBudgetGB, 4), 60)
        self.maxResidentModelProcesses = min(max(maxResidentModelProcesses, 1), 8)
        self.downloadSettings = downloadSettings.validated()
        _ = mlxHost
        _ = providerHost
    }

    public init(
        activeModel: String? = nil,
        mlxHost: String = DashboardSettings.localMLXHost,
        mlxPort: Int = 8080,
        providerHost: String = DashboardSettings.localMLXHost,
        providerPort: Int = 8123,
        serverFlags: [String] = [],
        providerDebugCaptureEnabled: Bool = false,
        providerRoleAssignments: ProviderRoleAssignments = ProviderRoleAssignments(),
        downloadSettings: HuggingFaceDownloadSettings
    ) {
        self.init(
            activeModel: activeModel,
            mlxHost: mlxHost,
            mlxPort: mlxPort,
            providerHost: providerHost,
            providerPort: providerPort,
            serverFlags: serverFlags,
            providerDebugCaptureEnabled: providerDebugCaptureEnabled,
            providerRoleAssignments: providerRoleAssignments,
            providerGenerationDefaults: .recommendedDefault,
            downloadSettings: downloadSettings
        )
    }

    private enum CodingKeys: String, CodingKey {
        case activeModel
        case mlxHost
        case mlxPort
        case providerHost
        case providerPort
        case serverFlags
        case providerDebugCaptureEnabled
        case providerRoleAssignments
        case providerGenerationDefaults
        case textDiffusionDefaults
        case modeAdviceStrategy
        case modeAdviceModel
        case modelRuntimeOverrides
        case residentModelMemoryBudgetGB
        case maxResidentModelProcesses
        case downloadSettings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            activeModel: try container.decodeIfPresent(String.self, forKey: .activeModel),
            mlxPort: try container.decodeIfPresent(Int.self, forKey: .mlxPort) ?? 8080,
            providerPort: try container.decodeIfPresent(Int.self, forKey: .providerPort) ?? 8123,
            serverFlags: try container.decodeIfPresent([String].self, forKey: .serverFlags) ?? [],
            providerDebugCaptureEnabled: try container.decodeIfPresent(Bool.self, forKey: .providerDebugCaptureEnabled) ?? false,
            providerRoleAssignments: try container.decodeIfPresent(ProviderRoleAssignments.self, forKey: .providerRoleAssignments) ?? ProviderRoleAssignments(),
            providerGenerationDefaults: try container.decodeIfPresent(ProviderRoleGenerationDefaults.self, forKey: .providerGenerationDefaults) ?? .recommendedDefault,
            textDiffusionDefaults: try container.decodeIfPresent(TextDiffusionGenerationSettings.self, forKey: .textDiffusionDefaults) ?? TextDiffusionGenerationSettings(),
            modeAdviceStrategy: try container.decodeIfPresent(ModeAdviceStrategy.self, forKey: .modeAdviceStrategy) ?? .automatic,
            modeAdviceModel: try container.decodeIfPresent(String.self, forKey: .modeAdviceModel),
            modelRuntimeOverrides: try container.decodeIfPresent([String: ModelRuntimeOverride].self, forKey: .modelRuntimeOverrides) ?? [:],
            residentModelMemoryBudgetGB: try container.decodeIfPresent(Double.self, forKey: .residentModelMemoryBudgetGB) ?? 42,
            maxResidentModelProcesses: try container.decodeIfPresent(Int.self, forKey: .maxResidentModelProcesses) ?? 2,
            downloadSettings: try container.decodeIfPresent(HuggingFaceDownloadSettings.self, forKey: .downloadSettings) ?? .standardDefault
        )
    }

    public var providerRootURL: URL {
        URL(string: "http://\(Self.localMLXHost):\(providerPort)")!
    }

    public var providerBaseURL: URL {
        providerRootURL
    }

    public var providerOpenAIBaseURL: URL {
        providerRootURL.appending(path: "v1")
    }

    public var mlxBaseURL: URL {
        URL(string: "http://\(Self.localMLXHost):\(mlxPort)")!
    }

    public func runtimeConfiguration(modelID: String, modelType: String? = nil) -> ModelRuntimeConfiguration {
        ModelRuntimeResolver.resolved(
            modelID: modelID,
            modelType: modelType,
            overrides: modelRuntimeOverrides
        )
    }
}

public final class SettingsStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL = AppPaths.default.settingsFile) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public func load() throws -> DashboardSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return DashboardSettings()
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(DashboardSettings.self, from: data)
    }

    public func save(_ settings: DashboardSettings) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: [.atomic])
    }
}
