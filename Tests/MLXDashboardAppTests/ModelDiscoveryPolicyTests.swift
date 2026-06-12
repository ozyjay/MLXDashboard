import XCTest
@testable import MLXDashboardApp

final class ModelDiscoveryPolicyTests: XCTestCase {
    func testDefaultSearchRunsOnlyWhenPackagesAreReadyAndResultsAreEmpty() {
        XCTAssertTrue(ModelDiscoveryPolicy.shouldRunDefaultSearch(isReady: true, hasResults: false))
        XCTAssertFalse(ModelDiscoveryPolicy.shouldRunDefaultSearch(isReady: false, hasResults: false))
        XCTAssertFalse(ModelDiscoveryPolicy.shouldRunDefaultSearch(isReady: true, hasResults: true))
    }

    func testInstallActionIsDisabledWithoutSelectionOrWhileInstalling() {
        XCTAssertTrue(ModelDiscoveryPolicy.canInstallSelected(hasSelection: true, isInstalling: false))
        XCTAssertFalse(ModelDiscoveryPolicy.canInstallSelected(hasSelection: false, isInstalling: false))
        XCTAssertFalse(ModelDiscoveryPolicy.canInstallSelected(hasSelection: true, isInstalling: true))
    }
}
