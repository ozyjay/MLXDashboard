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

        XCTAssertTrue(ModelDiscoveryPolicy.canInstallSelected(
            hasSelection: true,
            isInstalling: false,
            isSelectedInstalled: false
        ))
        XCTAssertFalse(ModelDiscoveryPolicy.canInstallSelected(
            hasSelection: true,
            isInstalling: false,
            isSelectedInstalled: true
        ))
    }

    func testSearchResultActionMarksInstalledModels() {
        let installedAction = ModelDiscoveryPolicy.searchResultAction(
            modelID: "mlx-community/Tiny",
            installedModelIDs: ["mlx-community/Tiny"],
            installingModelID: nil,
            isInstalling: false
        )
        let installableAction = ModelDiscoveryPolicy.searchResultAction(
            modelID: "mlx-community/Other",
            installedModelIDs: ["mlx-community/Tiny"],
            installingModelID: nil,
            isInstalling: false
        )
        let installingAction = ModelDiscoveryPolicy.searchResultAction(
            modelID: "mlx-community/Other",
            installedModelIDs: ["mlx-community/Tiny"],
            installingModelID: "mlx-community/Other",
            isInstalling: true
        )

        XCTAssertEqual(installedAction, .alreadyInstalled)
        XCTAssertEqual(installableAction, .install)
        XCTAssertEqual(installingAction, .installing)
    }
}
