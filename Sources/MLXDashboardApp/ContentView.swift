import SwiftUI
import MLXCore

enum DashboardSection: String, CaseIterable, Identifiable {
    case discover = "Discover"
    case installed = "Installed"
    case controller = "Controller"
    case provider = "Provider"
    case dashboard = "Dashboard"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .discover:
            return "magnifyingglass"
        case .installed:
            return "externaldrive"
        case .controller:
            return "switch.2"
        case .provider:
            return "point.3.connected.trianglepath.dotted"
        case .dashboard:
            return "gauge.with.dots.needle.67percent"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var viewModel: DashboardViewModel
    @State private var selectedSection: DashboardSection? = .discover

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("MLXDashboard")
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
        } detail: {
            VStack(spacing: 0) {
                AppHeader(section: selectedSection ?? .discover)
                Divider()
                detailView(for: selectedSection ?? .discover)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(WindowCloseGuardView())
        .onChange(of: viewModel.modelDownloadSettingsNavigationRequestID) { _, _ in
            selectedSection = .controller
        }
    }

    @ViewBuilder
    private func detailView(for section: DashboardSection) -> some View {
        switch section {
        case .discover:
            DiscoverModelsView()
        case .installed:
            InstalledModelsView()
        case .controller:
            ControllerTab()
        case .provider:
            ProviderTab()
        case .dashboard:
            DashboardTab()
        }
    }
}

struct DashboardLayoutPolicy {
    static let spacing: CGFloat = 16
    static let activeModelMinHeight: CGFloat = 240
    static let recentLogsMinHeight: CGFloat = 240
}

private struct AppHeader: View {
    @EnvironmentObject private var viewModel: DashboardViewModel
    let section: DashboardSection

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(section.rawValue)
                    .font(.headline)
                HStack(spacing: 10) {
                    Text("Python: \(viewModel.pythonStatus)")
                    Text("Provider: \(viewModel.providerStatus)")
                    if let activeModel = viewModel.settings.activeModel {
                        Text("Active: \(activeModel)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            Spacer()

            Button {
                Task { await viewModel.refreshPythonStatus() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh Python status")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .task {
            await viewModel.refreshPythonStatus()
        }
    }
}

private struct DashboardTab: View {
    @EnvironmentObject private var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardLayoutPolicy.spacing) {
            HStack(alignment: .top, spacing: DashboardLayoutPolicy.spacing) {
                MetricTile(title: "mlx-lm", value: viewModel.serverController.state.rawValue.capitalized)
                MetricTile(title: "Provider", value: viewModel.providerStatus)
                MetricTile(title: "Requests", value: "\(viewModel.telemetry.requestCount)")
            }

            HStack(alignment: .top, spacing: DashboardLayoutPolicy.spacing) {
                ActiveModelView()
                RecentLogsView()
            }
        }
        .task {
            await viewModel.refreshPythonStatus()
        }
    }
}

private struct ControllerTab: View {
    @EnvironmentObject private var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server Controller").font(.title2.bold())
            TextField("Active model", text: Binding(
                get: { viewModel.settings.activeModel ?? "" },
                set: { viewModel.settings.activeModel = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
            HStack {
                TextField("MLX port", value: $viewModel.settings.mlxPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                TextField("Provider port", value: $viewModel.settings.providerPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Button("Save") { viewModel.saveSettings() }
                Button("Start") { Task { await viewModel.startServer() } }
                    .disabled(!viewModel.canStartServer)
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Stop") { viewModel.stopServer() }
                    .disabled(!viewModel.canStopServer)
                Button("Restart") { Task { await viewModel.restartServer() } }
                    .disabled(!viewModel.canRestartServer)
            }
            Text("Python: \(viewModel.pythonStatus)")
                .foregroundStyle(.secondary)
            HStack {
                Button("Check Python") { Task { await viewModel.refreshPythonStatus() } }
                Button("Install Packages") { Task { await viewModel.installPythonPackages() } }
                    .disabled(!viewModel.shouldOfferPythonPackageInstall)
            }
            Divider()
            ModelDownloadsSettingsView()
            Spacer()
        }
    }
}

private struct ModelDownloadsSettingsView: View {
    @EnvironmentObject private var viewModel: DashboardViewModel

    private var downloadSettings: HuggingFaceDownloadSettings {
        viewModel.settings.downloadSettings
    }

    private var customFieldsDisabled: Bool {
        downloadSettings.mode != .xetCustom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model Downloads")
                .font(.headline)
            Text("Standard download is recommended until Xet is tested on this network.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Download mode", selection: modeBinding) {
                ForEach(HuggingFaceDownloadMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)

            VStack(alignment: .leading, spacing: 8) {
                Stepper(
                    "Concurrency: \(downloadSettings.xetConcurrency)",
                    value: integerBinding(\.xetConcurrency),
                    in: 1...16
                )
                Stepper(
                    "Download timeout: \(downloadSettings.downloadTimeoutSeconds)s",
                    value: integerBinding(\.downloadTimeoutSeconds),
                    in: 10...600,
                    step: 10
                )
                Stepper(
                    "ETag timeout: \(downloadSettings.etagTimeoutSeconds)s",
                    value: integerBinding(\.etagTimeoutSeconds),
                    in: 5...120,
                    step: 5
                )
            }
            .disabled(customFieldsDisabled)
        }
    }

    private var modeBinding: Binding<HuggingFaceDownloadMode> {
        Binding(
            get: { downloadSettings.mode },
            set: { mode in
                if mode == .xetConservative {
                    viewModel.updateDownloadSettings(.conservativeDefault)
                    return
                }
                updateDownloadSettings { settings in
                    settings.mode = mode
                }
            }
        )
    }

    private func integerBinding(_ keyPath: WritableKeyPath<HuggingFaceDownloadSettings, Int>) -> Binding<Int> {
        Binding(
            get: { downloadSettings[keyPath: keyPath] },
            set: { value in
                updateDownloadSettings { settings in
                    settings[keyPath: keyPath] = value
                }
            }
        )
    }

    private func updateDownloadSettings(_ update: (inout HuggingFaceDownloadSettings) -> Void) {
        var settings = downloadSettings
        update(&settings)
        viewModel.updateDownloadSettings(settings)
    }
}

private struct DiscoverModelsView: View {
    @EnvironmentObject private var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Search Hugging Face MLX models", text: $viewModel.modelQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await viewModel.searchModels() }
                    }
                Button("Search") { Task { await viewModel.searchModels() } }
                if viewModel.canLoadMoreSearchResults || viewModel.isLoadingMoreSearchResults {
                    Button("Load More") {
                        Task { await viewModel.loadMoreSearchResults() }
                    }
                    .disabled(!viewModel.canLoadMoreSearchResults)
                    if viewModel.isLoadingMoreSearchResults {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Button("Check Login") { Task { await viewModel.refreshHuggingFaceAuthStatus() } }
                if viewModel.shouldOfferPythonPackageInstall {
                    Button("Install Packages") {
                        Task { await viewModel.installPythonPackages() }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.huggingFaceAuthMessage)
                    .foregroundStyle(.secondary)
                if let message = viewModel.modelSearchMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(message)
                            .foregroundStyle(.secondary)
                        if viewModel.shouldOfferPythonPackageInstall {
                            Button("Install Packages") {
                                Task { await viewModel.installPythonPackages() }
                            }
                        }
                    }
                }
                if let progress = viewModel.modelInstallProgress {
                    InstallProgressBanner(progress: progress)
                } else if let message = viewModel.modelInstallMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
            .font(.caption)

            HStack(spacing: 10) {
                Button("Install Selected") {
                    viewModel.startSelectedModelInstall()
                }
                .disabled(!ModelDiscoveryPolicy.canInstallSelected(
                    hasSelection: viewModel.selectedSearchModelID != nil,
                    isInstalling: viewModel.isInstallingModel
                ))
                if viewModel.isInstallingModel {
                    ProgressView()
                        .controlSize(.small)
                    Button("Pause Download") {
                        viewModel.pauseActiveModelInstall()
                    }
                }
                if viewModel.canContinueLastModelInstall {
                    Button("Continue Downloading") {
                        viewModel.startContinueLastModelInstall()
                    }
                }
                if viewModel.canRetryLastModelInstallWithoutXet {
                    Button("Retry without Xet") {
                        viewModel.startRetryLastModelInstallWithoutXet()
                    }
                }
                Spacer()
            }

            Table(viewModel.searchResults, selection: $viewModel.selectedSearchModelID) {
                TableColumn("Model") { model in
                    Text(model.id)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .width(min: 560, ideal: 900)
                TableColumn("Downloads") { model in
                    Text(model.downloads.map(String.init) ?? "")
                        .monospacedDigit()
                }
                .width(min: 72, ideal: 86, max: 104)
                TableColumn("Likes") { model in
                    Text(model.likes.map(String.init) ?? "")
                        .monospacedDigit()
                }
                .width(min: 42, ideal: 52, max: 64)
                TableColumn("Action") { model in
                    if viewModel.isInstallingModel && viewModel.modelInstallProgress?.modelID == model.id {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Installing")
                        }
                    } else {
                        Button("Install") {
                            viewModel.selectedSearchModelID = model.id
                            viewModel.startSelectedModelInstall()
                        }
                        .disabled(viewModel.isInstallingModel)
                    }
                }
                .width(min: 112, ideal: 128, max: 150)
            }
            .frame(minHeight: 420)
        }
        .task {
            await viewModel.searchDefaultModelsIfReady()
        }
    }
}

private struct InstalledModelsView: View {
    @EnvironmentObject private var viewModel: DashboardViewModel
    @State private var isConfirmingCacheDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Installed Models").font(.title3.bold())
                Spacer()
                Button("Scan Cache") { viewModel.scanModelCache() }
                if viewModel.hasRunningDownloads {
                    Button("Pause Download") {
                        viewModel.pauseActiveModelInstall()
                    }
                }
                Button("Continue Downloading") {
                    viewModel.startContinueSelectedInstalledModelInstall()
                }
                .disabled(!viewModel.canContinueSelectedInstalledModelInstall)
                Button("Retry without Xet") {
                    viewModel.startRetrySelectedInstalledModelInstallWithoutXet()
                }
                .disabled(!viewModel.canRetrySelectedInstalledModelInstallWithoutXet)
                Button("Set Active") { viewModel.setSelectedInstalledModelActive() }
                    .disabled(!viewModel.canSetSelectedInstalledModelActive)
                Button("Set Ask") { viewModel.assignSelectedInstalledModel(to: .ask) }
                    .disabled(!viewModel.canAssignSelectedInstalledModelToProviderRole)
                Button("Set Plan") { viewModel.assignSelectedInstalledModel(to: .plan) }
                    .disabled(!viewModel.canAssignSelectedInstalledModelToProviderRole)
                Button("Set Fast") { viewModel.assignSelectedInstalledModel(to: .coding) }
                    .disabled(!viewModel.canAssignSelectedInstalledModelToProviderRole)
                Button("Delete from Cache", role: .destructive) {
                    isConfirmingCacheDelete = true
                }
                .disabled(viewModel.selectedInstalledModelID == nil)
            }
            if let progress = viewModel.modelInstallProgress {
                InstallProgressBanner(progress: progress)
            } else if let message = viewModel.modelInstallMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Table(viewModel.installedModels, selection: $viewModel.selectedInstalledModelID) {
                TableColumn("Model") { record in
                    Text(record.id)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .width(min: 420, ideal: 760)
                TableColumn("Status") { record in
                    Text(record.status.rawValue)
                }
                .width(min: 76, ideal: 88, max: 104)
                TableColumn("Path") { record in
                    Text(record.localPath ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 120, ideal: 180, max: 240)
                TableColumn("Message") { record in
                    Text(record.message ?? "")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .width(min: 90, ideal: 140, max: 190)
            }
        }
        .confirmationDialog(
            "Delete cached model?",
            isPresented: $isConfirmingCacheDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Cache", role: .destructive) {
                viewModel.deleteSelectedInstalledModelFromCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all cached snapshots for the selected Hugging Face model.")
        }
    }
}

private struct WindowCloseGuardView: NSViewRepresentable {
    @EnvironmentObject private var viewModel: DashboardViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.viewModel = viewModel
        DispatchQueue.main.async {
            view.window?.delegate = context.coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.viewModel = viewModel
        DispatchQueue.main.async {
            nsView.window?.delegate = context.coordinator
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var viewModel: DashboardViewModel?

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard let viewModel,
                  !DashboardClosePolicy.canClose(hasRunningDownloads: viewModel.hasRunningDownloads)
            else {
                viewModel?.stopOwnedServicesBeforeClose()
                return true
            }

            viewModel.notifyCloseBlockedForRunningDownloads()
            AppForegrounder().bringToFront()
            return false
        }
    }
}

private struct InstallProgressBanner: View {
    let progress: ModelInstallProgress

    private var tintColor: Color {
        switch progress.phase {
        case .installed:
            return .green
        case .failed:
            return .red
        case .blocked:
            return .orange
        default:
            return .accentColor
        }
    }

    private var symbolName: String {
        switch progress.phase {
        case .installed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .blocked:
            return "exclamationmark.triangle.fill"
        default:
            return "arrow.down.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbolName)
                    .foregroundStyle(tintColor)
                Text(progress.title)
                    .font(.caption.bold())
                Text(progress.stepText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(progress.modelID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let downloadStatusText = progress.downloadStatusText {
                    Text(downloadStatusText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if progress.isWaitingForDownloadData {
                ProgressView()
                    .controlSize(.small)
                    .tint(tintColor)
            } else {
                ProgressView(value: progress.fractionCompleted)
                    .tint(tintColor)
            }
            if let cacheStatusText = progress.cacheStatusText {
                Text(cacheStatusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let xetFallbackHint = progress.xetFallbackHint {
                Text(xetFallbackHint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if !progress.activityRows.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(progress.activityRows) { row in
                        Text(row.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
            Text(progress.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ProviderTab: View {
    @EnvironmentObject private var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MLXChat Provider").font(.title2.bold())
            LabeledContent("Base URL", value: viewModel.providerBaseURL)
            LabeledContent("Access", value: "Localhost only")
            GroupBox("Role assignments") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    roleRow("Ask", viewModel.settings.providerRoleAssignments.ask)
                    roleRow("Plan", viewModel.settings.providerRoleAssignments.plan)
                    roleRow("Fast/Coding", viewModel.settings.providerRoleAssignments.coding)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle(
                "Full local payload capture",
                isOn: Binding(
                    get: { viewModel.settings.providerDebugCaptureEnabled },
                    set: { viewModel.setProviderDebugCaptureEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            Text("Debug log: \(viewModel.providerDebugLogPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("Start Provider") {
                    do {
                        try viewModel.startProvider()
                    } catch {
                        viewModel.telemetry.appendLog("Provider start failed: \(error)")
                    }
                }
                .disabled(!viewModel.canStartProvider)
                Button("Stop Provider") { viewModel.stopProvider() }
                    .disabled(!viewModel.canStopProvider)
            }
            Divider()
            Text("Routes").font(.headline)
            Text("GET /health")
            Text("GET /v1/models")
            Text("POST /v1/responses")
            Text("POST /v1/chat/completions")
            Text("POST /v1/completions")
            Spacer()
        }
    }

    @ViewBuilder
    private func roleRow(_ label: String, _ model: String?) -> some View {
        GridRow {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(model ?? "Not assigned")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private struct ActiveModelView: View {
    @EnvironmentObject private var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active Model").font(.headline)
            Text(viewModel.settings.activeModel ?? "No model selected")
                .font(.title3)
            Text("MLX: \(viewModel.settings.mlxBaseURL.absoluteString)")
            Text("MLXChat: \(viewModel.providerBaseURL)")
        }
        .frame(
            maxWidth: .infinity,
            minHeight: DashboardLayoutPolicy.activeModelMinHeight,
            alignment: .topLeading
        )
    }
}

private struct MetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct RecentLogsView: View {
    @EnvironmentObject private var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Logs").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.telemetry.logs.suffix(12)) { entry in
                        Text(entry.message)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: DashboardLayoutPolicy.recentLogsMinHeight,
            alignment: .topLeading
        )
    }
}
