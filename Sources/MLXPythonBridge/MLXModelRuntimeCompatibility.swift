import Foundation
import MLXCore

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

    private let runtimeCapabilities: MLXModelRuntimeCapabilities

    public init(runtimeCapabilities: MLXModelRuntimeCapabilities = MLXModelRuntimeCapabilities()) {
        self.runtimeCapabilities = runtimeCapabilities
    }

    public func compatibility(modelType: String?) -> MLXModelRuntimeCompatibility {
        guard let modelType, !modelType.isEmpty else {
            return .runnable(modelType: nil)
        }
        let normalized = modelType.lowercased()
        if Self.unsupportedModelTypes.contains(normalized) {
            return .unsupported(
                modelType: modelType,
                reason: runtimeCapabilities.unsupportedReason(modelType: modelType)
            )
        }

        if ModelRuntimeResolver.diffusionModelTypes.contains(normalized) {
            guard runtimeCapabilities.textDiffusionRuntimeAvailable else {
                return .unsupported(
                    modelType: modelType,
                    reason: runtimeCapabilities.unsupportedReason(modelType: modelType)
                )
            }
            return .runnable(modelType: modelType)
        }

        if runtimeCapabilities.hasInspectedMLXLMModels,
           !runtimeCapabilities.supportsMLXLM(modelType: normalized) {
            return .unknown(
                reason: "Installed mlx-lm does not advertise model_type \(modelType); custom model code must be verified after download."
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

        let directory = URL(filePath: localPath)
        let configURL = directory.appending(path: "config.json")
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .runnable(modelType: nil)
        }

        let modelType = object["model_type"] as? String
        if let modelType,
           ModelRuntimeResolver.diffusionModelTypes.contains(modelType.lowercased()) {
            return compatibility(modelType: modelType)
        }

        if let modelType,
           runtimeCapabilities.supportsMLXLM(modelType: modelType) {
            return .runnable(modelType: modelType)
        }

        if declaresCustomModelCode(config: object, modelDirectory: directory) {
            return .runnable(modelType: modelType)
        }

        guard let modelType, !modelType.isEmpty else {
            return .runnable(modelType: nil)
        }
        return compatibility(modelType: modelType)
    }

    public func runtimeConfiguration(
        modelID: String,
        modelType: String?,
        overrides: [String: ModelRuntimeOverride] = [:]
    ) -> ModelRuntimeConfiguration {
        ModelRuntimeResolver.resolved(
            modelID: modelID,
            modelType: modelType,
            overrides: overrides
        )
    }

    private func declaresCustomModelCode(
        config: [String: Any],
        modelDirectory: URL
    ) -> Bool {
        if let modelFile = config["model_file"] as? String,
           FileManager.default.fileExists(
               atPath: modelDirectory.appending(path: modelFile).path
           ) {
            return true
        }
        if let autoMap = config["auto_map"] as? [String: Any], !autoMap.isEmpty {
            return true
        }
        return false
    }
}

public struct MLXModelRuntimeCapabilities: Equatable, Sendable {
    private let supportedModelTypes: Set<String>
    public var mlxLMVersion: String?
    public var textDiffusionRuntimeAvailable: Bool

    public var hasInspectedMLXLMModels: Bool {
        !supportedModelTypes.isEmpty
    }

    public init(
        supportedModelTypes: Set<String> = [],
        mlxLMVersion: String? = nil,
        textDiffusionRuntimeAvailable: Bool = false
    ) {
        self.supportedModelTypes = Set(supportedModelTypes.map { $0.lowercased() })
        self.mlxLMVersion = mlxLMVersion
        self.textDiffusionRuntimeAvailable = textDiffusionRuntimeAvailable
    }

    public func supports(modelType: String) -> Bool {
        let normalized = modelType.lowercased()
        if ModelRuntimeResolver.diffusionModelTypes.contains(normalized) {
            return textDiffusionRuntimeAvailable
        }
        return supportsMLXLM(modelType: normalized)
    }

    public func supportsMLXLM(modelType: String) -> Bool {
        supportedModelTypes.contains(modelType.lowercased())
    }

    public func unsupportedReason(modelType: String) -> String {
        if ModelRuntimeResolver.diffusionModelTypes.contains(modelType.lowercased()),
           !textDiffusionRuntimeAvailable {
            return "Bundled text diffusion runtime is unavailable for model_type \(modelType)"
        }
        if let mlxLMVersion, !mlxLMVersion.isEmpty {
            return "Installed mlx-lm \(mlxLMVersion) does not support model_type \(modelType)"
        }
        return "Unsupported by installed mlx-lm: \(modelType)"
    }

    public static func inspectingInstalledPackage(
        sitePackagesURL: URL,
        mlxLMVersion: String? = nil
    ) -> Self {
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
        let diffusionRuntimeURL = sitePackagesURL.appending(
            path: "mlxdashboard_text_diffusion",
            directoryHint: .isDirectory
        )
        return MLXModelRuntimeCapabilities(
            supportedModelTypes: Set(modelTypes),
            mlxLMVersion: mlxLMVersion,
            textDiffusionRuntimeAvailable: FileManager.default.fileExists(
                atPath: diffusionRuntimeURL.path
            )
        )
    }
}
