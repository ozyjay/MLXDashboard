import XCTest
import MLXCore
import MLXPythonBridge
@testable import MLXDashboardApp

final class ModelDiscoveryPolicyTests: XCTestCase {
    func testGroupsQuantizedVariantsIntoOneFamilyWithFourBitSelected() {
        let families = ModelSearchGrouping.group([
            .init(id: "mlx-community/Foo-6bit", downloads: 300, likes: 6, modelType: "mistral"),
            .init(id: "mlx-community/Foo-4bit", downloads: 200, likes: 4, modelType: "mistral"),
            .init(id: "mlx-community/Foo-bf16", downloads: 900, likes: 8, modelType: "mistral")
        ], installedModels: [])

        XCTAssertEqual(families.count, 1)
        XCTAssertEqual(families[0].displayName, "Foo")
        XCTAssertEqual(families[0].variants.map(\.label), ["4bit", "6bit", "bf16"])
        XCTAssertEqual(families[0].selectedVariantID, "mlx-community/Foo-4bit")
        XCTAssertEqual(families[0].selectedVariant?.summary.id, "mlx-community/Foo-4bit")
    }

    func testLeavesAmbiguousFamiliesSeparate() {
        let families = ModelSearchGrouping.group([
            .init(id: "mlx-community/Foo-Bar", downloads: 100, likes: 1),
            .init(id: "mlx-community/Foo-Baz", downloads: 90, likes: 1)
        ], installedModels: [])

        XCTAssertEqual(families.map(\.displayName), ["Foo-Bar", "Foo-Baz"])
        XCTAssertEqual(families.map { $0.variants.count }, [1, 1])
    }

    func testSelectsSixBitThenHighestDownloadsWhenFourBitIsMissing() {
        let sixBit = ModelSearchGrouping.group([
            .init(id: "mlx-community/Foo-8bit", downloads: 900),
            .init(id: "mlx-community/Foo-6bit", downloads: 100)
        ], installedModels: [])
        let highestDownloads = ModelSearchGrouping.group([
            .init(id: "mlx-community/Bar-8bit", downloads: 900),
            .init(id: "mlx-community/Bar-bf16", downloads: 100)
        ], installedModels: [])

        XCTAssertEqual(sixBit[0].selectedVariantID, "mlx-community/Foo-6bit")
        XCTAssertEqual(highestDownloads[0].selectedVariantID, "mlx-community/Bar-8bit")
    }

    func testVariantInstallStateUsesExactRegistryRecord() {
        let families = ModelSearchGrouping.group([
            .init(id: "mlx-community/Foo-4bit", downloads: 300),
            .init(id: "mlx-community/Foo-6bit", downloads: 200)
        ], installedModels: [
            ModelRecord(id: "mlx-community/Foo-4bit", status: .installed),
            ModelRecord(id: "mlx-community/Foo-6bit", status: .failed, message: "download failed")
        ])

        XCTAssertEqual(families[0].variants.map(\.installState), [.installed, .failed])
    }

    func testTerminalRegistryStateWinsOverStaleInstallingModelID() {
        let families = ModelSearchGrouping.group([
            .init(id: "mlx-community/Foo-4bit", downloads: 300),
            .init(id: "mlx-community/Foo-6bit", downloads: 200)
        ], installedModels: [
            ModelRecord(id: "mlx-community/Foo-4bit", status: .installed),
            ModelRecord(id: "mlx-community/Foo-6bit", status: .failed, message: "download failed")
        ], installingModelID: "mlx-community/Foo-6bit")

        XCTAssertEqual(families[0].variants.map(\.installState), [.installed, .failed])
    }

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
