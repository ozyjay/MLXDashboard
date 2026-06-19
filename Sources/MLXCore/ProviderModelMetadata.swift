import Foundation

public enum ProviderGenerationType: String, Codable, Equatable, Sendable {
    case text
}

public enum ProviderModelFamily: String, Codable, Equatable, Sendable {
    case chat
    case diffusionText = "diffusion_text"
}

public enum ProviderModelRuntimeState: String, Codable, Equatable, Sendable {
    case loaded
    case unsupported
    case notInstalled = "not_installed"
}

public struct ProviderModelMetadata: Codable, Equatable, Sendable {
    public var generationType: ProviderGenerationType
    public var modelFamily: ProviderModelFamily
    public var state: ProviderModelRuntimeState
    public var unsupportedReason: String?
    public var unavailableReason: String?
    public var runtime: ModelRuntimeKind
    public var modelType: String?
    public var supportsStreaming: Bool
    public var supportedGenerationModes: [TextGenerationMode]
    public var maxContextLength: Int?
    public var maxOutputTokens: Int?
    public var estimatedResidentMemoryGB: Double?

    public init(
        generationType: ProviderGenerationType = .text,
        modelFamily: ProviderModelFamily = .chat,
        state: ProviderModelRuntimeState = .loaded,
        unsupportedReason: String? = nil,
        unavailableReason: String? = nil,
        runtime: ModelRuntimeKind = .mlxLM,
        modelType: String? = nil,
        supportsStreaming: Bool = true,
        supportedGenerationModes: [TextGenerationMode] = [.autoregressive],
        maxContextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        estimatedResidentMemoryGB: Double? = nil
    ) {
        self.generationType = generationType
        self.modelFamily = modelFamily
        self.state = state
        self.unsupportedReason = unsupportedReason ?? unavailableReason
        self.unavailableReason = unavailableReason ?? unsupportedReason
        self.runtime = runtime
        self.modelType = modelType
        self.supportsStreaming = supportsStreaming
        self.supportedGenerationModes = supportedGenerationModes
        self.maxContextLength = maxContextLength
        self.maxOutputTokens = maxOutputTokens
        self.estimatedResidentMemoryGB = estimatedResidentMemoryGB
    }

    public static func inferred(
        modelID: String,
        modelType: String? = nil,
        state: ProviderModelRuntimeState = .loaded,
        unsupportedReason: String? = nil,
        unavailableReason: String? = nil,
        runtimeOverrides: [String: ModelRuntimeOverride] = [:]
    ) -> ProviderModelMetadata {
        let runtimeConfiguration = ModelRuntimeResolver.resolved(
            modelID: modelID,
            modelType: modelType,
            overrides: runtimeOverrides
        )
        return ProviderModelMetadata(
            modelFamily: runtimeConfiguration.runtime == .textDiffusion ? .diffusionText : .chat,
            state: state,
            unsupportedReason: unsupportedReason,
            unavailableReason: unavailableReason,
            runtime: runtimeConfiguration.runtime,
            modelType: modelType,
            supportsStreaming: runtimeConfiguration.supportsStreaming,
            supportedGenerationModes: runtimeConfiguration.supportedGenerationModes,
            maxContextLength: runtimeConfiguration.maxContextLength,
            maxOutputTokens: runtimeConfiguration.maxOutputTokens,
            estimatedResidentMemoryGB: runtimeConfiguration.estimatedResidentMemoryGB
        )
    }

    public static func modelFamily(modelID: String, modelType: String?) -> ProviderModelFamily {
        ModelRuntimeResolver.inferred(modelID: modelID, modelType: modelType).runtime == .textDiffusion
            ? .diffusionText
            : .chat
    }
}
