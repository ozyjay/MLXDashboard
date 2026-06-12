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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            AppForegrounder().bringToFront()
        }
    }
}
