import AppKit
import XCTest
@testable import MLXDashboardApp

@MainActor
final class AppForegrounderTests: XCTestCase {
    func testBringToFrontMakesApplicationRegularAndActive() {
        let application = SpyApplicationActivator()
        let foregrounder = AppForegrounder(application: application)

        foregrounder.bringToFront()

        XCTAssertEqual(application.activationPolicies, [.regular])
        XCTAssertEqual(application.activateIgnoringOtherApps, [true])
    }
}

@MainActor
private final class SpyApplicationActivator: ApplicationActivating {
    var activationPolicies: [NSApplication.ActivationPolicy] = []
    var activateIgnoringOtherApps: [Bool] = []

    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
        activationPolicies.append(activationPolicy)
        return true
    }

    func activate(ignoringOtherApps flag: Bool) {
        activateIgnoringOtherApps.append(flag)
    }
}
