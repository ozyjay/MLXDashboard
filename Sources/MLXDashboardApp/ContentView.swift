import SwiftUI
import MLXCore

struct ContentView: View {
    @EnvironmentObject private var viewModel: DashboardViewModel

    var body: some View {
        TabView {
            DashboardTab()
                .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent") }
            ControllerTab()
                .tabItem { Label("Controller", systemImage: "switch.2") }
            ModelsTab()
                .tabItem { Label("Models", systemImage: "square.stack.3d.up") }
            ProviderTab()
                .tabItem { Label("Provider", systemImage: "point.3.connected.trianglepath.dotted") }
        }
        .padding(18)
    }
}

private struct DashboardTab: View {
    @EnvironmentObject private var viewModel: DashboardViewModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 16) {
            GridRow {
                MetricTile(title: "mlx-lm", value: viewModel.serverController.state.rawValue.capitalized)
                MetricTile(title: "Provider", value: viewModel.providerStatus)
                MetricTile(title: "Requests", value: "\(viewModel.telemetry.requestCount)")
            }
            GridRow {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Active Model").font(.headline)
                    Text(viewModel.settings.activeModel ?? "No model selected")
                        .font(.title3)
                    Text("MLX: \(viewModel.settings.mlxBaseURL.absoluteString)")
                    Text("MLXChat: \(viewModel.providerBaseURL)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Stop") { viewModel.stopServer() }
                Button("Restart") { Task { await viewModel.startServer() } }
            }
            Text("Python: \(viewModel.pythonStatus)")
                .foregroundStyle(.secondary)
            HStack {
                Button("Check Python") { Task { await viewModel.refreshPythonStatus() } }
                Button("Install Packages") { Task { await viewModel.installPythonPackages() } }
            }
            Spacer()
        }
    }
}

private struct ModelsTab: View {
    @EnvironmentObject private var viewModel: DashboardViewModel
    @State private var isConfirmingCacheDelete = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Hugging Face Search").font(.headline)
                HStack {
                    TextField("Search Hugging Face MLX models", text: $viewModel.modelQuery)
                        .textFieldStyle(.roundedBorder)
                    Button("Search") { Task { await viewModel.searchModels() } }
                    Button("Check Login") { Task { await viewModel.refreshHuggingFaceAuthStatus() } }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.huggingFaceAuthMessage)
                        .foregroundStyle(.secondary)
                    if let message = viewModel.modelSearchMessage {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(message)
                                .foregroundStyle(.secondary)
                            if viewModel.shouldOfferPythonPackageInstall {
                                Button("Install Packages") {
                                    Task { await viewModel.installPythonPackages() }
                                }
                            }
                        }
                    }
                    if let message = viewModel.modelInstallMessage {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    Button("Install Selected") {
                        Task { await viewModel.installSelectedModel() }
                    }
                    .disabled(viewModel.selectedSearchModelID == nil || viewModel.isInstallingModel)
                    if viewModel.isInstallingModel {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if viewModel.shouldOfferPythonPackageInstall {
                        Button("Install Packages") {
                            Task { await viewModel.installPythonPackages() }
                        }
                    }
                }
                Table(viewModel.searchResults, selection: $viewModel.selectedSearchModelID) {
                    TableColumn("Model", value: \.id)
                    TableColumn("Downloads") { model in
                        Text(model.downloads.map(String.init) ?? "")
                    }
                    TableColumn("Likes") { model in
                        Text(model.likes.map(String.init) ?? "")
                    }
                    TableColumn("Action") { model in
                        Button("Install") {
                            viewModel.selectedSearchModelID = model.id
                            Task { await viewModel.installSelectedModel() }
                        }
                        .disabled(viewModel.isInstallingModel)
                    }
                }
            }
            .frame(minWidth: 460)

            VStack(alignment: .leading, spacing: 14) {
                Text("Installed Models").font(.headline)
                HStack {
                    Button("Scan Cache") { viewModel.scanModelCache() }
                    Button("Set Active") { viewModel.setSelectedInstalledModelActive() }
                        .disabled(viewModel.selectedInstalledModelID == nil)
                    Button("Delete from Cache", role: .destructive) {
                        isConfirmingCacheDelete = true
                    }
                    .disabled(viewModel.selectedInstalledModelID == nil)
                }
                Table(viewModel.installedModels, selection: $viewModel.selectedInstalledModelID) {
                    TableColumn("Model", value: \.id)
                    TableColumn("Status") { record in
                        Text(record.status.rawValue)
                    }
                    TableColumn("Path") { record in
                        Text(record.localPath ?? "")
                            .lineLimit(1)
                    }
                    TableColumn("Message") { record in
                        Text(record.message ?? "")
                            .lineLimit(1)
                    }
                }
            }
            .frame(minWidth: 460)
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

private struct ProviderTab: View {
    @EnvironmentObject private var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MLXChat Provider").font(.title2.bold())
            LabeledContent("Base URL", value: viewModel.providerBaseURL)
            LabeledContent("Authorization", value: "Bearer \(viewModel.tokenPreview)")
            HStack {
                Button("Start Provider") {
                    do {
                        try viewModel.startProvider()
                    } catch {
                        viewModel.telemetry.appendLog("Provider start failed: \(error)")
                    }
                }
                Button("Stop Provider") { viewModel.stopProvider() }
                Button("Regenerate Token") { viewModel.regenerateToken() }
            }
            Divider()
            Text("Routes").font(.headline)
            Text("GET /health")
            Text("GET /v1/models")
            Text("POST /v1/chat/completions")
            Text("POST /v1/completions")
            Spacer()
        }
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
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
    }
}
