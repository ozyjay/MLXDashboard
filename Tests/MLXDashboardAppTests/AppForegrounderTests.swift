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

    func testDashboardClosePolicyBlocksCloseWhileDownloadsRun() {
        XCTAssertFalse(DashboardClosePolicy.canClose(hasRunningDownloads: true))
        XCTAssertTrue(DashboardClosePolicy.canClose(hasRunningDownloads: false))
    }

    func testApplicationShouldTerminateStopsOwnedServicesWhenCloseIsAllowed() {
        let closeState = SpyDashboardCloseState(hasRunningDownloads: false)
        let delegate = AppDelegate()
        delegate.closeState = closeState

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(closeState.stopOwnedServicesBeforeCloseCallCount, 1)
        XCTAssertEqual(closeState.notifyCloseBlockedCallCount, 0)
    }

    func testApplicationShouldTerminateDoesNotStopOwnedServicesWhenDownloadsBlockClose() {
        let closeState = SpyDashboardCloseState(hasRunningDownloads: true)
        let delegate = AppDelegate()
        delegate.closeState = closeState

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertEqual(closeState.stopOwnedServicesBeforeCloseCallCount, 0)
        XCTAssertEqual(closeState.notifyCloseBlockedCallCount, 1)
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

@MainActor
private final class SpyDashboardCloseState: DashboardCloseState {
    let hasRunningDownloads: Bool
    var notifyCloseBlockedCallCount = 0
    var stopOwnedServicesBeforeCloseCallCount = 0

    init(hasRunningDownloads: Bool) {
        self.hasRunningDownloads = hasRunningDownloads
    }

    func notifyCloseBlockedForRunningDownloads() {
        notifyCloseBlockedCallCount += 1
    }

    func stopOwnedServicesBeforeClose() {
        stopOwnedServicesBeforeCloseCallCount += 1
    }
}
