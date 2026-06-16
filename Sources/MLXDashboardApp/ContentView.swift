import SwiftUI
import MLXCore
import MLXPythonBridge
import MLXServerControl

enum DashboardSection: String, CaseIterable, Identifiable {
    case discover = "Discover"
    case installed = "Installed"
    case controller = "Controller"
    case provider = "Provider"
    case dashboard = "Dashboard"

    static let defaultSelection: DashboardSection = .dashboard

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
    @State private var selectedSection: DashboardSection? = DashboardSection.defaultSelection

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
                AppHeader(section: selectedSection ?? DashboardSection.defaultSelection)
                Divider()
                detailView(for: selectedSection ?? DashboardSection.defaultSelection)
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
    static let recentLogsMinHeight: CGFloat = 360
    static let recentLogsVisibleLimit = 24
}

struct RoleServerStatusTablePolicy {
    static func canStop(_ row: RoleServerStatusRow, defaultEndpoint: RoleServerEndpoint?) -> Bool {
        guard row.endpoint != nil else {
            return false
        }

        guard row.endpoint?.port != defaultEndpoint?.port else {
            return false
        }

        return row.kind == .running || row.kind == .shared
    }

    static func canRestart(_ row: RoleServerStatusRow, defaultEndpoint: RoleServerEndpoint?) -> Bool {
        guard row.assignedModel != nil,
              row.endpoint != nil,
              row.endpoint?.port != defaultEndpoint?.port
        else {
            return false
        }

        return row.kind == .running
    }
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
                    if viewModel.runtimePackageUpgradeStatus.hasAvailableUpgrades {
                        Text(viewModel.runtimePackageUpgradeSummary)
                    }
                    Text("Provider: \(viewModel.providerStatus)")
                    if let activeModel = viewModel.settings.activeModel {
                        Text("Default: \(activeModel)")
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
                MetricTile(title: "mlx-lm", value: viewModel.serverState.rawValue.capitalized)
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
            TextField("Default model", text: Binding(
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
            RuntimePackageUpdatesView()
            RoleServerStatusTable()
            HStack {
                Button("Check Python") { Task { await viewModel.refreshPythonStatus() } }
                Button("Install Packages") { Task { await viewModel.installPythonPackages() } }
                    .disabled(!viewModel.shouldOfferPythonPackageInstall)
                Button("Check Upgrades") { Task { await viewModel.checkRuntimePackageUpgrades() } }
                    .disabled(viewModel.isCheckingRuntimePackageUpgrades || viewModel.isUpgradingRuntimePackages)
                Button("Upgrade Runtime") { Task { await viewModel.upgradeRuntimePackages() } }
                    .disabled(!viewModel.canUpgradeRuntimePackages)
                if viewModel.isCheckingRuntimePackageUpgrades || viewModel.isUpgradingRuntimePackages {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Divider()
            ModelDownloadsSettingsView()
            Spacer()
        }
    }
}

private struct RuntimePackageUpdatesView: View {
    @EnvironmentObject private var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.runtimePackageUpgradeSummary)
                .font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    headerText("Package")
                        .frame(width: 70, alignment: .leading)
                    headerText("Installed")
                        .frame(width: 90, alignment: .leading)
                    headerText("Latest")
                        .frame(width: 90, alignment: .leading)
                    headerText("Status")
                        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                }
                ForEach(viewModel.runtimePackageUpgradeStatus.statuses) { status in
                    GridRow {
                        Text(status.packageName)
                            .frame(width: 70, alignment: .leading)
                        Text(status.installedVersion ?? "-")
                            .monospacedDigit()
                            .frame(width: 90, alignment: .leading)
                        Text(status.latestVersion ?? "-")
                            .monospacedDigit()
                            .frame(width: 90, alignment: .leading)
                        Text(statusText(for: status))
                            .foregroundStyle(statusColor(for: status.state))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.caption)
        }
    }

    private func statusText(for status: PythonPackageVersionStatus) -> String {
        if let message = status.message {
            return message
        }
        switch status.state {
        case .missing:
            return "Missing"
        case .current:
            return "Current"
        case .upgradeAvailable:
            return "Upgrade available"
        case .unknown:
            return "Unable to check"
        }
    }

    private func statusColor(for state: PythonPackageVersionState) -> Color {
        switch state {
        case .current:
            return .green
        case .upgradeAvailable:
            return .orange
        case .missing, .unknown:
            return .secondary
        }
    }

    private func headerText(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct RoleServerStatusTable: View {
    @EnvironmentObject private var viewModel: DashboardViewModel

    private var plannedEndpoints: [ProviderModelRole: RoleServerEndpoint] {
        RoleServerPoolController.makePlan(settings: viewModel.settings).roleEndpoints
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Role Servers")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    headerText("Role")
                        .frame(width: 70, alignment: .leading)
                    headerText("Assigned model")
                        .frame(minWidth: 200, maxWidth: 280, alignment: .leading)
                    headerText("Port")
                        .frame(width: 50, alignment: .leading)
                    headerText("Status")
                        .frame(width: 90, alignment: .leading)
                    headerText("Detail")
                        .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                    headerText("Actions")
                        .frame(width: 120, alignment: .leading)
                }

                Divider()
                    .gridCellColumns(6)

                ForEach(viewModel.roleServerStatuses) { row in
                    GridRow {
                        Text(row.role.displayName)
                            .frame(width: 70, alignment: .leading)
                        Text(row.assignedModel ?? "—")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(minWidth: 200, maxWidth: 280, alignment: .leading)
                        Text(portText(for: row))
                            .frame(width: 50, alignment: .leading)
                        Text(statusText(for: row.kind))
                            .foregroundStyle(statusColor(for: row.kind))
                            .frame(width: 90, alignment: .leading)
                        Text(row.detail)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            Button("Restart") {
                                Task { await viewModel.restartRoleServer(row.role) }
                            }
                            .disabled(
                                viewModel.serverState != .running
                                || !RoleServerStatusTablePolicy.canRestart(
                                    row,
                                    defaultEndpoint: viewModel.serverPoolController.defaultEndpoint
                                )
                            )

                            Button("Stop") {
                                viewModel.stopRoleServer(row.role)
                            }
                            .disabled(
                                viewModel.serverState != .running
                                || !RoleServerStatusTablePolicy.canStop(
                                    row,
                                    defaultEndpoint: viewModel.serverPoolController.defaultEndpoint
                                )
                            )
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 120, alignment: .leading)
                    }
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headerText(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func portText(for row: RoleServerStatusRow) -> String {
        if let port = row.endpoint?.port {
            return "\(port)"
        }

        if let port = plannedEndpoints[row.role]?.port {
            return "\(port)"
        }

        return "—"
    }

    private func statusText(for kind: RoleServerStatusKind) -> String {
        switch kind {
        case .unassigned:
            return "Unassigned"
        case .planned:
            return "Planned"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .shared:
            return "Shared"
        case .fallback:
            return "Fallback"
        case .failed:
            return "Failed"
        case .stopped:
            return "Stopped"
        }
    }

    private func statusColor(for kind: RoleServerStatusKind) -> Color {
        switch kind {
        case .running, .shared:
            return .green
        case .fallback:
            return .orange
        case .failed:
            return .red
        default:
            return .secondary
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
                .disabled(!viewModel.canInstallSelectedSearchModel)
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

            Table(viewModel.searchResultFamilies, selection: $viewModel.selectedSearchFamilyID) {
                TableColumn("Model") { family in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(family.displayName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .textSelection(.enabled)
                        if let variant = family.selectedVariant {
                            Text(variant.summary.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        HStack(spacing: 6) {
                            ForEach(family.variants) { variant in
                                Button {
                                    viewModel.selectSearchVariant(familyID: family.id, variantID: variant.id)
                                } label: {
                                    VariantChipLabel(
                                        variant: variant,
                                        isSelected: variant.id == family.selectedVariantID
                                    )
                                }
                                .buttonStyle(.plain)
                                .help(variant.id)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
                .width(min: 560, ideal: 900)
                TableColumn("Downloads") { family in
                    Text(family.selectedVariant?.summary.downloads.map(String.init) ?? "")
                        .monospacedDigit()
                }
                .width(min: 72, ideal: 86, max: 104)
                TableColumn("Likes") { family in
                    Text(family.selectedVariant?.summary.likes.map(String.init) ?? "")
                        .monospacedDigit()
                }
                .width(min: 42, ideal: 52, max: 64)
                TableColumn("Action") { family in
                    let selectedModelID = family.selectedVariantID
                    switch viewModel.searchResultAction(for: selectedModelID) {
                    case .alreadyInstalled:
                        Text("Already installed")
                            .foregroundStyle(.secondary)
                    case .installing:
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Installing")
                        }
                    case .install:
                        Button("Install") {
                            viewModel.selectSearchVariant(familyID: family.id, variantID: selectedModelID)
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

private struct VariantChipLabel: View {
    var variant: ModelSearchVariant
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(variant.label)
                .font(.caption.weight(isSelected ? .semibold : .regular))
            switch variant.installState {
            case .installed:
                Image(systemName: "checkmark.circle.fill")
                    .imageScale(.small)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
            case .paused:
                Image(systemName: "pause.circle.fill")
                    .imageScale(.small)
            case .installing:
                ProgressView()
                    .controlSize(.mini)
            case .notInstalled:
                EmptyView()
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.65) : Color.clear, lineWidth: 1)
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
                Button("Set Default") { viewModel.setSelectedInstalledModelActive() }
                    .disabled(!viewModel.canSetSelectedInstalledModelActive)
                Button("Set Ask") { viewModel.assignSelectedInstalledModel(to: .ask) }
                    .disabled(!viewModel.canAssignSelectedInstalledModelToProviderRole)
                Button("Set Plan") { viewModel.assignSelectedInstalledModel(to: .plan) }
                    .disabled(!viewModel.canAssignSelectedInstalledModelToProviderRole)
                Button("Set Coding") { viewModel.assignSelectedInstalledModel(to: .coding) }
                    .disabled(!viewModel.canAssignSelectedInstalledModelToProviderRole)
                Button("Delete from Cache", role: .destructive) {
                    isConfirmingCacheDelete = true
                }
                .disabled(viewModel.selectedInstalledModelID == nil)
            }
            if let progress = viewModel.installedWorkspacePrimaryProgress {
                InstallProgressBanner(
                    progress: progress,
                    showsFullActivity: progress.modelID == viewModel.selectedInstalledModelID
                )
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
    var showsFullActivity = false

    private var displayedActivityRows: [ModelInstallProgress.ActivityRow] {
        showsFullActivity ? progress.fullActivityRows : progress.activityRows
    }

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
            switch progress.progressDisplayMode {
            case .determinate(let value), .phaseFallback(let value):
                ProgressView(value: value)
                    .tint(tintColor)
            case .indeterminateDownload:
                ProgressView()
                    .controlSize(.small)
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
            if !displayedActivityRows.isEmpty {
                activityRowsView
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

    @ViewBuilder
    private var activityRowsView: some View {
        if showsFullActivity {
            ScrollView(.vertical) {
                activityRowsList
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        } else {
            activityRowsList
        }
    }

    private var activityRowsList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(displayedActivityRows) { row in
                Text(row.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(showsFullActivity ? 2 : 1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
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
                    roleRow("Coding", viewModel.settings.providerRoleAssignments.coding)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Generation defaults") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        generationHeader("Role")
                            .frame(width: 64, alignment: .leading)
                        generationHeader("Temp")
                            .frame(width: 64, alignment: .leading)
                        generationHeader("Top P")
                            .frame(width: 64, alignment: .leading)
                        generationHeader("Max tokens")
                            .frame(width: 86, alignment: .leading)
                    }
                    generationRow(.ask)
                    generationRow(.plan)
                    generationRow(.coding)
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

    private func generationRow(_ role: ProviderModelRole) -> some View {
        GridRow {
            Text(role.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            TextField(
                "Temp",
                value: generationDoubleBinding(role: role, keyPath: \.temperature),
                format: .number.precision(.fractionLength(0...2))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
            TextField(
                "Top P",
                value: generationDoubleBinding(role: role, keyPath: \.topP),
                format: .number.precision(.fractionLength(0...2))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
            TextField(
                "Max",
                value: generationMaxTokensBinding(role: role),
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 86)
        }
    }

    private func generationHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func generationDoubleBinding(
        role: ProviderModelRole,
        keyPath: WritableKeyPath<ProviderGenerationSettings, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                viewModel.settings.providerGenerationDefaults.settings(for: role)[keyPath: keyPath]
            },
            set: { value in
                var settings = viewModel.settings.providerGenerationDefaults.settings(for: role)
                settings[keyPath: keyPath] = value
                viewModel.updateGenerationSettings(settings, for: role)
            }
        )
    }

    private func generationMaxTokensBinding(role: ProviderModelRole) -> Binding<Int> {
        Binding(
            get: {
                viewModel.settings.providerGenerationDefaults.settings(for: role).maxTokens
            },
            set: { value in
                var settings = viewModel.settings.providerGenerationDefaults.settings(for: role)
                settings.maxTokens = value
                viewModel.updateGenerationSettings(settings, for: role)
            }
        )
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
                    ForEach(viewModel.telemetry.logs.suffix(DashboardLayoutPolicy.recentLogsVisibleLimit)) { entry in
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
