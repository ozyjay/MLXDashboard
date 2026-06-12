import SwiftUI
import MLXCore
import MLXPythonBridge
import MLXProviderServer
import MLXServerControl

@main
struct MLXDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = DashboardViewModel()

    var body: some Scene {
        WindowGroup("MLXDashboard") {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 980, minHeight: 680)
                .onAppear {
                    appDelegate.closeState = viewModel
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
}
