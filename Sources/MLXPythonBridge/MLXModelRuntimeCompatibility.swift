import Foundation

public enum MLXModelRuntimeCompatibility: Equatable, Sendable {
    case runnable(modelType: String?)
    case unsupported(modelType: String, reason: String)
    case unknown(reason: String)

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
        if case .unknown(let reason) = self {
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
        "diffusion_gemma",
        "nemotron_labs_diffusion"
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
            return .unsupported(
                modelType: modelType,
                reason: runtimeCapabilities.unsupportedReason(modelType: modelType)
            )
        }
        return .runnable(modelType: modelType)
    }

    public func compatibility(discoveredModelType modelType: String?) -> MLXModelRuntimeCompatibility {
        guard let modelType, !modelType.isEmpty else {
            return .unknown(reason: "Model config metadata was unavailable before download.")
        }
        return compatibility(modelType: modelType)
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
    public var mlxLMVersion: String?

    public init(supportedModelTypes: Set<String> = [], mlxLMVersion: String? = nil) {
        self.supportedModelTypes = Set(supportedModelTypes.map { $0.lowercased() })
        self.mlxLMVersion = mlxLMVersion
    }

    public func supports(modelType: String) -> Bool {
        supportedModelTypes.contains(modelType.lowercased())
    }

    public func unsupportedReason(modelType: String) -> String {
        if let mlxLMVersion, !mlxLMVersion.isEmpty {
            return "Installed mlx-lm \(mlxLMVersion) does not support model_type \(modelType)"
        }
        return "Unsupported by installed mlx-lm: \(modelType)"
    }

    public static func inspectingInstalledPackage(sitePackagesURL: URL, mlxLMVersion: String? = nil) -> Self {
        let modelsURL = sitePackagesURL.appending(path: "mlx_lm/models", directoryHint: .isDirectory)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: modelsURL,
            includingPropertiesForKeys: nil
        )) ?? []
        let modelTypes = contents.compactMap { url -> String? in
            guard url.pathExtension == "py" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard name != "__init__" else { return nil }
            return name
        }
        return MLXModelRuntimeCapabilities(
            supportedModelTypes: Set(modelTypes),
            mlxLMVersion: mlxLMVersion
        )
    }
}
