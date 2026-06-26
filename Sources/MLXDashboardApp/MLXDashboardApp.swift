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
    @AppStorage(AppTextSizePolicy.storageKey) private var appTextSizeLevel = AppTextSizePolicy.defaultLevel
    @State private var didHandleLaunchOptions = false
    private let launchOptions = AppLaunchOptions()

    var body: some Scene {
        WindowGroup("MLXDashboard") {
            ContentView()
                .environmentObject(viewModel)
                .dynamicTypeSize(AppTextSizePolicy.dynamicTypeSize(for: appTextSizeLevel))
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
                    appTextSizeLevel = AppTextSizePolicy.increased(appTextSizeLevel)
                }
                .keyboardShortcut("+", modifiers: [.command])

                Button("Decrease Font Size") {
                    appTextSizeLevel = AppTextSizePolicy.decreased(appTextSizeLevel)
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button("Reset Font Size") {
                    appTextSizeLevel = AppTextSizePolicy.defaultLevel
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
