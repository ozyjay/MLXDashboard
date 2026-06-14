import Foundation
import MLXCore
import MLXPythonBridge

enum ModelVariantInstallState: Equatable, Sendable {
    case notInstalled
    case installing
    case installed
    case failed
    case paused
}

struct ModelSearchVariant: Identifiable, Equatable, Sendable {
    var id: String { summary.id }
    var label: String
    var summary: HuggingFaceModelSummary
    var installState: ModelVariantInstallState
}

struct ModelFamilySearchResult: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    var variants: [ModelSearchVariant]
    var selectedVariantID: String

    var selectedVariant: ModelSearchVariant? {
        variants.first { $0.id == selectedVariantID } ?? variants.first
    }
}

enum ModelSearchGrouping {
    static func group(
        _ models: [HuggingFaceModelSummary],
        installedModels: [ModelRecord],
        selectedVariants: [String: String] = [:],
        installingModelID: String? = nil
    ) -> [ModelFamilySearchResult] {
        let installedRecords = Dictionary(uniqueKeysWithValues: installedModels.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: models) { familyDescriptor(for: $0.id).familyID }

        return grouped.map { familyID, models in
            let descriptor = familyDescriptor(for: models[0].id)
            let variants = models
                .map { model in
                    let descriptor = familyDescriptor(for: model.id)
                    return ModelSearchVariant(
                        label: descriptor.variantLabel,
                        summary: model,
                        installState: installState(
                            for: model.id,
                            installedRecords: installedRecords,
                            installingModelID: installingModelID
                        )
                    )
                }
                .sorted(by: variantSort)
            let selectedVariantID = selectedVariants[familyID].flatMap { selectedID in
                variants.contains(where: { $0.id == selectedID }) ? selectedID : nil
            } ?? defaultVariantID(from: variants)
            return ModelFamilySearchResult(
                id: familyID,
                displayName: descriptor.displayName,
                variants: variants,
                selectedVariantID: selectedVariantID
            )
        }
        .sorted { lhs, rhs in
            let lhsDownloads = lhs.selectedVariant?.summary.downloads ?? 0
            let rhsDownloads = rhs.selectedVariant?.summary.downloads ?? 0
            if lhsDownloads != rhsDownloads {
                return lhsDownloads > rhsDownloads
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func familyDescriptor(for modelID: String) -> (familyID: String, displayName: String, variantLabel: String) {
        let parts = modelID.split(separator: "/", maxSplits: 1).map(String.init)
        let owner = parts.count == 2 ? parts[0] : nil
        let repoName = parts.count == 2 ? parts[1] : modelID
        let tokens = repoName.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let last = tokens.last,
              let variantLabel = variantLabel(for: last),
              tokens.count > 1
        else {
            return (modelID, repoName, "Default")
        }

        let familyName = tokens.dropLast().joined(separator: "-")
        let familyID = owner.map { "\($0)/\(familyName)" } ?? familyName
        return (familyID, familyName, variantLabel)
    }

    private static func variantLabel(for token: String) -> String? {
        let normalized = token.lowercased()
        switch normalized {
        case "4bit", "4-bit":
            return "4bit"
        case "6bit", "6-bit":
            return "6bit"
        case "8bit", "8-bit":
            return "8bit"
        case "bf16":
            return "bf16"
        case "fp16":
            return "fp16"
        case "dwq":
            return "DWQ"
        case "q4":
            return "Q4"
        case "q6":
            return "Q6"
        case "q8":
            return "Q8"
        default:
            return nil
        }
    }

    private static func variantSort(_ lhs: ModelSearchVariant, _ rhs: ModelSearchVariant) -> Bool {
        let lhsRank = variantRank(lhs.label)
        let rhsRank = variantRank(rhs.label)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        let lhsDownloads = lhs.summary.downloads ?? 0
        let rhsDownloads = rhs.summary.downloads ?? 0
        if lhsDownloads != rhsDownloads {
            return lhsDownloads > rhsDownloads
        }
        return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
    }

    private static func defaultVariantID(from variants: [ModelSearchVariant]) -> String {
        if let fourBit = variants.first(where: { $0.label == "4bit" }) {
            return fourBit.id
        }
        if let sixBit = variants.first(where: { $0.label == "6bit" }) {
            return sixBit.id
        }
        return variants
            .max { ($0.summary.downloads ?? 0) < ($1.summary.downloads ?? 0) }?
            .id ?? variants[0].id
    }

    private static func variantRank(_ label: String) -> Int {
        switch label {
        case "4bit": return 0
        case "6bit": return 1
        case "8bit": return 2
        case "DWQ": return 3
        case "Q4": return 4
        case "Q6": return 5
        case "Q8": return 6
        case "bf16": return 7
        case "fp16": return 8
        default: return 99
        }
    }

    private static func installState(
        for modelID: String,
        installedRecords: [String: ModelRecord],
        installingModelID: String?
    ) -> ModelVariantInstallState {
        if modelID == installingModelID {
            return .installing
        }
        switch installedRecords[modelID]?.status {
        case .installed:
            return .installed
        case .failed:
            return .failed
        case .paused:
            return .paused
        case .installing:
            return .installing
        case .removed, nil:
            return .notInstalled
        }
    }
}
