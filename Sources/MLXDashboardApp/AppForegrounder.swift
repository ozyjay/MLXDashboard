import AppKit

@MainActor
protocol ApplicationActivating: AnyObject {
    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool
    func activate(ignoringOtherApps flag: Bool)
}

extension NSApplication: ApplicationActivating {}

@MainActor
struct AppForegrounder {
    private let application: any ApplicationActivating

    init(application: any ApplicationActivating = NSApp) {
        self.application = application
    }

    func bringToFront() {
        _ = application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)
    }
}

@MainActor
protocol DashboardCloseState: AnyObject {
    var hasRunningDownloads: Bool { get }
    func notifyCloseBlockedForRunningDownloads()
}

struct DashboardClosePolicy {
    static func canClose(hasRunningDownloads: Bool) -> Bool {
        !hasRunningDownloads
    }
}

@MainActor
extension DashboardViewModel: DashboardCloseState {}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var closeState: (any DashboardCloseState)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            AppForegrounder().bringToFront()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let closeState,
              !DashboardClosePolicy.canClose(hasRunningDownloads: closeState.hasRunningDownloads)
        else {
            return .terminateNow
        }

        closeState.notifyCloseBlockedForRunningDownloads()
        AppForegrounder().bringToFront()
        return .terminateCancel
    }
}
