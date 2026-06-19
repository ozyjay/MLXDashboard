import Foundation

public enum ModelRuntimeKind: String, Codable, CaseIterable, Equatable, Sendable {
    case mlxLM = "mlx_lm"
    case textDiffusion = "text_diffusion"

    public var displayName: String {
        switch self {
        case .mlxLM:
            return "MLX-LM"
        case .textDiffusion:
            return "Text diffusion"
        }
    }
}

public enum TextGenerationMode: String, Codable, CaseIterable, Equatable, Sendable {
    case autoregressive
    case diffusion
    case linearSpec = "linear_spec"
}

public enum ModeAdviceStrategy: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic
    case heuristic
    case model
    case disabled
}

public struct ModelRuntimeConfiguration: Codable, Equatable, Sendable {
    public var runtime: ModelRuntimeKind
    public var modelType: String?
    public var supportsStreaming: Bool
    public var supportedGenerationModes: [TextGenerationMode]
    public var maxContextLength: Int?
    public var maxOutputTokens: Int?
    public var estimatedResidentMemoryGB: Double?

    public init(
        runtime: ModelRuntimeKind,
        modelType: String? = nil,
        supportsStreaming: Bool,
        supportedGenerationModes: [TextGenerationMode],
        maxContextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        estimatedResidentMemoryGB: Double? = nil
    ) {
        self.runtime = runtime
        self.modelType = modelType
        self.supportsStreaming = supportsStreaming
        self.supportedGenerationModes = supportedGenerationModes
        self.maxContextLength = maxContextLength
        self.maxOutputTokens = maxOutputTokens
        self.estimatedResidentMemoryGB = estimatedResidentMemoryGB
    }

    public static func mlxLM(modelType: String? = nil) -> ModelRuntimeConfiguration {
        ModelRuntimeConfiguration(
            runtime: .mlxLM,
            modelType: modelType,
            supportsStreaming: true,
            supportedGenerationModes: [.autoregressive]
        )
    }

    public static func textDiffusion(modelType: String? = nil) -> ModelRuntimeConfiguration {
        ModelRuntimeConfiguration(
            runtime: .textDiffusion,
            modelType: modelType,
            supportsStreaming: false,
            supportedGenerationModes: [.diffusion, .linearSpec, .autoregressive],
            maxOutputTokens: 4096
        )
    }
}

public struct ModelRuntimeOverride: Codable, Equatable, Sendable {
    public var runtime: ModelRuntimeKind?
    public var supportsStreaming: Bool?
    public var supportedGenerationModes: [TextGenerationMode]?
    public var maxContextLength: Int?
    public var maxOutputTokens: Int?
    public var estimatedResidentMemoryGB: Double?

    public init(
        runtime: ModelRuntimeKind? = nil,
        supportsStreaming: Bool? = nil,
        supportedGenerationModes: [TextGenerationMode]? = nil,
        maxContextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        estimatedResidentMemoryGB: Double? = nil
    ) {
        self.runtime = runtime
        self.supportsStreaming = supportsStreaming
        self.supportedGenerationModes = supportedGenerationModes
        self.maxContextLength = maxContextLength
        self.maxOutputTokens = maxOutputTokens
        self.estimatedResidentMemoryGB = estimatedResidentMemoryGB
    }

    public func applying(to inferred: ModelRuntimeConfiguration) -> ModelRuntimeConfiguration {
        ModelRuntimeConfiguration(
            runtime: runtime ?? inferred.runtime,
            modelType: inferred.modelType,
            supportsStreaming: supportsStreaming ?? inferred.supportsStreaming,
            supportedGenerationModes: supportedGenerationModes ?? inferred.supportedGenerationModes,
            maxContextLength: maxContextLength ?? inferred.maxContextLength,
            maxOutputTokens: maxOutputTokens ?? inferred.maxOutputTokens,
            estimatedResidentMemoryGB: estimatedResidentMemoryGB ?? inferred.estimatedResidentMemoryGB
        )
    }
}

public enum ModelRuntimeResolver {
    public static let diffusionModelTypes: Set<String> = [
        "diffusion_gemma",
        "nemotron_labs_diffusion",
        "dream",
        "llada"
    ]

    public static func inferred(modelID: String, modelType: String? = nil) -> ModelRuntimeConfiguration {
        let normalizedType = modelType?.lowercased()
        let normalizedID = modelID.lowercased()
        let isDiffusion = normalizedType.map(diffusionModelTypes.contains) == true
            || normalizedID.contains("nemotron-labs-diffusion")
            || normalizedID.contains("nemotron_labs_diffusion")
            || normalizedID.contains("diffusion-gemma")
            || normalizedID.contains("diffusion_gemma")
            || normalizedID.contains("llada")
            || normalizedID.contains("diffucoder")
            || normalizedID.contains("dream")

        if isDiffusion {
            return .textDiffusion(modelType: modelType)
        }
        return .mlxLM(modelType: modelType)
    }

    public static func resolved(
        modelID: String,
        modelType: String? = nil,
        overrides: [String: ModelRuntimeOverride]
    ) -> ModelRuntimeConfiguration {
        let inferred = inferred(modelID: modelID, modelType: modelType)
        return overrides[modelID]?.applying(to: inferred) ?? inferred
    }
}
