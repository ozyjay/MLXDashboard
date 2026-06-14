enum ModelSearchResultAction: Equatable {
    case install
    case installing
    case alreadyInstalled
}

enum ModelDiscoveryPolicy {
    static func shouldRunDefaultSearch(isReady: Bool, hasResults: Bool) -> Bool {
        isReady && !hasResults
    }

    static func canInstallSelected(hasSelection: Bool, isInstalling: Bool) -> Bool {
        hasSelection && !isInstalling
    }

    static func canInstallSelected(hasSelection: Bool, isInstalling: Bool, isSelectedInstalled: Bool) -> Bool {
        hasSelection && !isInstalling && !isSelectedInstalled
    }

    static func searchResultAction(
        modelID: String,
        installedModelIDs: Set<String>,
        installingModelID: String?,
        isInstalling: Bool
    ) -> ModelSearchResultAction {
        if installedModelIDs.contains(modelID) {
            return .alreadyInstalled
        }
        if isInstalling, installingModelID == modelID {
            return .installing
        }
        return .install
    }
}
