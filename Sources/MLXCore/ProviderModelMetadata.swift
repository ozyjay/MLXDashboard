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

    public init(
        generationType: ProviderGenerationType = .text,
        modelFamily: ProviderModelFamily = .chat,
        state: ProviderModelRuntimeState = .loaded,
        unsupportedReason: String? = nil,
        unavailableReason: String? = nil
    ) {
        self.generationType = generationType
        self.modelFamily = modelFamily
        self.state = state
        self.unsupportedReason = unsupportedReason ?? unavailableReason
        self.unavailableReason = unavailableReason ?? unsupportedReason
    }

    public static func inferred(
        modelID: String,
        modelType: String? = nil,
        state: ProviderModelRuntimeState = .loaded,
        unsupportedReason: String? = nil,
        unavailableReason: String? = nil
    ) -> ProviderModelMetadata {
        ProviderModelMetadata(
            modelFamily: modelFamily(modelID: modelID, modelType: modelType),
            state: state,
            unsupportedReason: unsupportedReason,
            unavailableReason: unavailableReason
        )
    }

    public static func modelFamily(modelID: String, modelType: String?) -> ProviderModelFamily {
        let values = [modelType, modelID].compactMap { $0?.lowercased() }
        if values.contains(where: { $0.contains("diffusion_gemma") || $0.contains("diffusion-gemma") }) {
            return .diffusionText
        }
        return .chat
    }
}
