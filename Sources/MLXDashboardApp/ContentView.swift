import SwiftUI
import AppKit
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
        .appFont(.body)
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
    static let recentLogsVisibleLimit = 200
}

struct AppTextSizePolicy {
    static let storageKey = "MLXDashboardAppTextSizeLevel"
    static let defaultLevel = 0
    static let minimumLevel = -2
    static let maximumLevel = 3
    static let scaleFactor: CGFloat = 1.12

    static func increased(_ level: Int) -> Int {
        min(level + 1, maximumLevel)
    }

    static func decreased(_ level: Int) -> Int {
        max(level - 1, minimumLevel)
    }

    static func clamped(_ level: Int) -> Int {
        min(max(level, minimumLevel), maximumLevel)
    }

    static func pointSize(for style: AppTextStyle, level: Int) -> CGFloat {
        style.basePointSize * pow(scaleFactor, CGFloat(clamped(level)))
    }

    static func font(
        _ style: AppTextStyle,
        level: Int,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> Font {
        .system(size: pointSize(for: style, level: level), weight: weight, design: design)
    }
}

enum AppTextStyle {
    case caption
    case body
    case subheadline
    case headline
    case title3
    case title2

    var basePointSize: CGFloat {
        switch self {
        case .caption:
            return 11
        case .body, .headline:
            return 13
        case .subheadline:
            return 12
        case .title3:
            return 15
        case .title2:
            return 17
        }
    }
}

@MainActor
final class AppTextSizeController: ObservableObject {
    @Published private(set) var level: Int

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = AppTextSizePolicy.storageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.level = AppTextSizePolicy.clamped(defaults.integer(forKey: storageKey))
        defaults.set(level, forKey: storageKey)
    }

    func increase() {
        setLevel(AppTextSizePolicy.increased(level))
    }

    func decrease() {
        setLevel(AppTextSizePolicy.decreased(level))
    }

    func reset() {
        setLevel(AppTextSizePolicy.defaultLevel)
    }

    func setLevel(_ level: Int) {
        let clampedLevel = AppTextSizePolicy.clamped(level)
        self.level = clampedLevel
        defaults.set(clampedLevel, forKey: storageKey)
    }
}

private struct AppTextSizeLevelKey: EnvironmentKey {
    static let defaultValue = AppTextSizePolicy.defaultLevel
}

extension EnvironmentValues {
    var appTextSizeLevel: Int {
        get { self[AppTextSizeLevelKey.self] }
        set { self[AppTextSizeLevelKey.self] = newValue }
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.appTextSizeLevel) private var level

    let style: AppTextStyle
    let weight: Font.Weight?
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(AppTextSizePolicy.font(style, level: level, weight: weight, design: design))
    }
}

extension View {
    func appFont(
        _ style: AppTextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> some View {
        modifier(AppFontModifier(style: style, weight: weight, design: design))
    }
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
                    .appFont(.headline, weight: .semibold)
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
                .appFont(.caption)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await viewModel.refreshPythonStatus()
        }
    }
}

private struct ControllerTab: View {
    @EnvironmentObject private var viewModel: DashboardViewModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Server Controller").appFont(.title2, weight: .bold)
                TextField("Default model", text: Binding(
                    get: { viewModel.settings.activeModel ?? "" },
                    set: { viewModel.settings.activeModel = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("MLX port", value: $viewModel.settings.mlxPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 132)
                    TextField("Provider port", value: $viewModel.settings.providerPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 156)
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
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct RuntimePackageUpdatesView: View {
    @EnvironmentObject private var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.runtimePackageUpgradeSummary)
                .appFont(.subheadline, weight: .semibold)
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
            .appFont(.caption)
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
            .appFont(.caption, weight: .semibold)
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
                .appFont(.headline, weight: .semibold)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    headerText("Role")
                        .frame(width: 82, alignment: .leading)
                    headerText("Assigned model")
                        .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
                    headerText("Port")
                        .frame(width: 60, alignment: .leading)
                    headerText("Status")
                        .frame(width: 108, alignment: .leading)
                    headerText("Detail")
                        .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                    headerText("Actions")
                        .frame(width: 140, alignment: .leading)
                }

                Divider()
                    .gridCellColumns(6)

                ForEach(viewModel.roleServerStatuses) { row in
                    GridRow {
                        Text(row.role.displayName)
                            .frame(width: 82, alignment: .leading)
                        Text(row.assignedModel ?? "—")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
                        Text(portText(for: row))
                            .frame(width: 60, alignment: .leading)
                        Text(statusText(for: row.kind))
                            .foregroundStyle(statusColor(for: row.kind))
                            .frame(width: 108, alignment: .leading)
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
                        .frame(width: 140, alignment: .leading)
                    }
                }
            }
            .appFont(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headerText(_ text: String) -> some View {
        Text(text)
            .appFont(.caption, weight: .semibold)
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
                .appFont(.headline, weight: .semibold)
            Text("Standard download is recommended until Xet is tested on this network.")
                .appFont(.caption)
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
            .appFont(.caption)

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
                            .appFont(.body, weight: .medium)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        if let variant = family.selectedVariant {
                            Text(variant.summary.id)
                                .appFont(.caption)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                .appFont(.caption, weight: isSelected ? .semibold : .regular)
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
                Text("Installed Models").appFont(.title3, weight: .bold)
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
                Button("Set Default") {
                    Task { await viewModel.setSelectedInstalledModelActiveAndRestartIfRunning() }
                }
                    .disabled(!viewModel.canSetSelectedInstalledModelActive)
                Button("Set Ask") {
                    Task { await viewModel.assignSelectedInstalledModelAndRestartIfRunning(to: .ask) }
                }
                    .disabled(!viewModel.canAssignSelectedInstalledModelToProviderRole)
                Button("Set Plan") {
                    Task { await viewModel.assignSelectedInstalledModelAndRestartIfRunning(to: .plan) }
                }
                    .disabled(!viewModel.canAssignSelectedInstalledModelToProviderRole)
                Button("Set Coding") {
                    Task { await viewModel.assignSelectedInstalledModelAndRestartIfRunning(to: .coding) }
                }
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
                    .appFont(.caption)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                    .appFont(.caption, weight: .bold)
                Text(progress.stepText)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                Text(progress.modelID)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let downloadStatusText = progress.downloadStatusText {
                    Text(downloadStatusText)
                        .appFont(.caption).monospacedDigit()
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
                    .appFont(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let xetFallbackHint = progress.xetFallbackHint {
                Text(xetFallbackHint)
                    .appFont(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if !displayedActivityRows.isEmpty {
                activityRowsView
            }
            Text(progress.detail)
                .appFont(.caption)
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
                    .appFont(.caption)
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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Text("MLXChat Provider").appFont(.title2, weight: .bold)
                LabeledContent("Access", value: "Localhost only")
                GroupBox("MLXChat handoff") {
                    VStack(alignment: .leading, spacing: 8) {
                        handoffRow("MLXChat base URL", value: viewModel.providerBaseURL, copyTitle: "Copy URL")
                        handoffRow("OpenAI-compatible base URL", value: viewModel.providerOpenAIBaseURL, copyTitle: "Copy URL")
                        handoffRow("CLI smoke test", value: viewModel.providerMLXChatSmokeTestCommand, copyTitle: "Copy Command")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                                .frame(width: 76, alignment: .leading)
                            generationHeader("Temp")
                                .frame(width: 76, alignment: .leading)
                            generationHeader("Top P")
                                .frame(width: 76, alignment: .leading)
                            generationHeader("Max tokens")
                                .frame(width: 104, alignment: .leading)
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
                Text("When enabled, Dashboard writes local request and response payload bodies to the provider debug log. Headers are redacted; prompt and reply text are not.")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Debug log: \(viewModel.providerDebugLogPath)")
                    .appFont(.caption)
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
                Text("Routes").appFont(.headline, weight: .semibold)
                Text("GET /health")
                Text("GET /v1/models")
                Text("POST /v1/responses")
                Text("POST /v1/chat/completions")
                Text("POST /v1/completions")
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func handoffRow(_ label: String, value: String, copyTitle: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 180, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                copyToPasteboard(value)
            } label: {
                Label(copyTitle, systemImage: "doc.on.doc")
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @ViewBuilder
    private func roleRow(_ label: String, _ model: String?) -> some View {
        GridRow {
            Text(label)
                .appFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(model ?? "Not assigned")
                .appFont(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func generationRow(_ role: ProviderModelRole) -> some View {
        GridRow {
            Text(role.displayName)
                .appFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            TextField(
                "Temp",
                value: generationDoubleBinding(role: role, keyPath: \.temperature),
                format: .number.precision(.fractionLength(0...2))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 76)
            TextField(
                "Top P",
                value: generationDoubleBinding(role: role, keyPath: \.topP),
                format: .number.precision(.fractionLength(0...2))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 76)
            TextField(
                "Max",
                value: generationMaxTokensBinding(role: role),
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 104)
        }
    }

    private func generationHeader(_ text: String) -> some View {
        Text(text)
            .appFont(.caption, weight: .semibold)
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
            Text("Active Model").appFont(.headline, weight: .semibold)
            Text(viewModel.settings.activeModel ?? "No model selected")
                .appFont(.title3)
            Text("MLX: \(viewModel.settings.mlxBaseURL.absoluteString)")
            Text("MLXChat: \(viewModel.providerBaseURL)")
        }
        .frame(
            maxWidth: .infinity,
            minHeight: DashboardLayoutPolicy.activeModelMinHeight,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}

private struct MetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).appFont(.caption).foregroundStyle(.secondary)
            Text(value).appFont(.title3, weight: .bold).lineLimit(2)
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
            Text("Recent Logs").appFont(.headline, weight: .semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.telemetry.logs.suffix(DashboardLayoutPolicy.recentLogsVisibleLimit)) { entry in
                        Text(entry.message)
                            .appFont(.caption, design: .monospaced)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: DashboardLayoutPolicy.recentLogsMinHeight,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}
