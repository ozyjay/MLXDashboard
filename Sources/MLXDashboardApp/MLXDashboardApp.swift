import AppKit
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
    @StateObject private var textSizeController = AppTextSizeController()
    @State private var didHandleLaunchOptions = false
    private let launchOptions = AppLaunchOptions()

    var body: some Scene {
        WindowGroup("MLXDashboard") {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(textSizeController)
                .environment(\.appTextSizeLevel, textSizeController.level)
                .frame(minWidth: 980, minHeight: 680)
                .onAppear {
                    appDelegate.closeState = viewModel
                    startFromLaunchOptionsIfNeeded()
                }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    NSApp.activate(ignoringOtherApps: true)
                    viewModel.requestModelDownloadSettingsNavigation()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            CommandGroup(after: .appInfo) {
                Button("Start MLX Server") {
                    Task { await viewModel.startServer() }
                }
                Button("Stop MLX Server") {
                    viewModel.stopServer()
                }
            }
            CommandMenu("View") {
                Button("Increase Font Size") {
                    textSizeController.increase()
                }
                .keyboardShortcut("+", modifiers: [.command])

                Button("Decrease Font Size") {
                    textSizeController.decrease()
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button("Reset Font Size") {
                    textSizeController.reset()
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }

    private func startFromLaunchOptionsIfNeeded() {
        guard launchOptions.autostartProvider, !didHandleLaunchOptions else { return }
        didHandleLaunchOptions = true
        Task { await viewModel.startServer() }
    }
}
