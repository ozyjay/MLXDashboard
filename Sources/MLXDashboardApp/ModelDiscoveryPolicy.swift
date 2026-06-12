enum ModelDiscoveryPolicy {
    static func shouldRunDefaultSearch(isReady: Bool, hasResults: Bool) -> Bool {
        isReady && !hasResults
    }

    static func canInstallSelected(hasSelection: Bool, isInstalling: Bool) -> Bool {
        hasSelection && !isInstalling
    }
}
