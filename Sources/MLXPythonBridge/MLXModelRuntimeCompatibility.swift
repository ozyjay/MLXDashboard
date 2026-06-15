import Foundation

public enum MLXModelRuntimeCompatibility: Equatable, Sendable {
    case runnable(modelType: String?)
    case unsupported(modelType: String, reason: String)

    public var isRunnable: Bool {
        if case .runnable = self {
            return true
        }
        return false
    }

    public var failureMessage: String? {
        if case .unsupported(_, let reason) = self {
            return reason
        }
        return nil
    }
}

public struct MLXModelRuntimeCompatibilityChecker: Sendable {
    private static let unsupportedModelTypes: Set<String> = [
        "gemma4_unified"
    ]
    private static let capabilityGatedModelTypes: Set<String> = [
        "diffusion_gemma"
    ]

    private let runtimeCapabilities: MLXModelRuntimeCapabilities

    public init(runtimeCapabilities: MLXModelRuntimeCapabilities = MLXModelRuntimeCapabilities()) {
        self.runtimeCapabilities = runtimeCapabilities
    }

    public func compatibility(modelType: String?) -> MLXModelRuntimeCompatibility {
        guard let modelType, !modelType.isEmpty else {
            return .runnable(modelType: nil)
        }

        if Self.unsupportedModelTypes.contains(modelType)
            || Self.capabilityGatedModelTypes.contains(modelType) && !runtimeCapabilities.supports(modelType: modelType) {
            return .unsupported(modelType: modelType, reason: "Unsupported by installed mlx-lm: \(modelType)")
        }
        return .runnable(modelType: modelType)
    }

    public func compatibility(localPath: String?) -> MLXModelRuntimeCompatibility {
        guard let localPath else {
            return .runnable(modelType: nil)
        }

        let configURL = URL(filePath: localPath).appending(path: "config.json")
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelType = object["model_type"] as? String,
              !modelType.isEmpty
        else {
            return .runnable(modelType: nil)
        }

        return compatibility(modelType: modelType)
    }
}

public struct MLXModelRuntimeCapabilities: Equatable, Sendable {
    private let supportedModelTypes: Set<String>

    public init(supportedModelTypes: Set<String> = []) {
        self.supportedModelTypes = Set(supportedModelTypes.map { $0.lowercased() })
    }

    public func supports(modelType: String) -> Bool {
        supportedModelTypes.contains(modelType.lowercased())
    }
}
