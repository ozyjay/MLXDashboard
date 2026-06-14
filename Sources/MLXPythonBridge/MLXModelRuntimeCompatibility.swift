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

    public init() {}

    public func compatibility(modelType: String?) -> MLXModelRuntimeCompatibility {
        guard let modelType, !modelType.isEmpty else {
            return .runnable(modelType: nil)
        }

        if Self.unsupportedModelTypes.contains(modelType) {
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
