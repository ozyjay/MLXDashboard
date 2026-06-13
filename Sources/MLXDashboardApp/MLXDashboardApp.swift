import SwiftUI
import MLXCore
import MLXPythonBridge
import MLXProviderServer
import MLXServerControl

struct AppLaunchOptions {
    let autostartProvider: Bool

    init(arguments: [String] = CommandLine.arguments) {
        autostartProvider = arguments.contains("--autostart-provider") || arguments.contains("--autostart")
    }
}

@main
struct MLXDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = DashboardViewModel()
    @State private var didHandleLaunchOptions = false
    private let launchOptions = AppLaunchOptions()

    var body: some Scene {
        WindowGroup("MLXDashboard") {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 980, minHeight: 680)
                .onAppear {
                    appDelegate.closeState = viewModel
                    startFromLaunchOptionsIfNeeded()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Start MLX Server") {
                    Task { await viewModel.startServer() }
                }
                Button("Stop MLX Server") {
                    viewModel.stopServer()
                }
            }
        }
    }

    private func startFromLaunchOptionsIfNeeded() {
        guard launchOptions.autostartProvider, !didHandleLaunchOptions else { return }
        didHandleLaunchOptions = true
        Task { await viewModel.startServer() }
    }
}
