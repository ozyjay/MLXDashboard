import XCTest
@testable import MLXCore

final class CorePersistenceTests: XCTestCase {
    func testSettingsStorePersistsDashboardSettings() throws {
        let root = try temporaryDirectory()
        let store = SettingsStore(fileURL: root.appending(path: "config/settings.json"))
        let settings = DashboardSettings(
            activeModel: "mlx-community/Qwen3-8B-4bit",
            mlxHost: "127.0.0.1",
            mlxPort: 8080,
            providerHost: "127.0.0.1",
            providerPort: 8123,
            serverFlags: ["--trust-remote-code"],
            providerDebugCaptureEnabled: false,
            providerRoleAssignments: ProviderRoleAssignments(
                ask: "mlx-community/Ask",
                plan: "mlx-community/Plan",
                coding: "mlx-community/Coder"
            )
        )

        try store.save(settings)

        let reloaded = try store.load()
        XCTAssertEqual(reloaded.activeModel, "mlx-community/Qwen3-8B-4bit")
        XCTAssertEqual(reloaded.mlxPort, 8080)
        XCTAssertEqual(reloaded.providerPort, 8123)
        XCTAssertEqual(reloaded.serverFlags, ["--trust-remote-code"])
        XCTAssertFalse(reloaded.providerDebugCaptureEnabled)
        XCTAssertEqual(reloaded.providerRoleAssignments.ask, "mlx-community/Ask")
        XCTAssertEqual(reloaded.providerRoleAssignments.plan, "mlx-community/Plan")
        XCTAssertEqual(reloaded.providerRoleAssignments.coding, "mlx-community/Coder")
    }

    func testSettingsStorePersistsDownloadSettings() throws {
        let root = try temporaryDirectory()
        let store = SettingsStore(fileURL: root.appending(path: "config/settings.json"))
        let settings = DashboardSettings(
            downloadSettings: HuggingFaceDownloadSettings(
                mode: .xetCustom,
                xetConcurrency: 3,
                downloadTimeoutSeconds: 120,
                etagTimeoutSeconds: 45
            )
        )

        try store.save(settings)

        let reloaded = try store.load()
        XCTAssertEqual(reloaded.downloadSettings.mode, .xetCustom)
        XCTAssertEqual(reloaded.downloadSettings.xetConcurrency, 3)
        XCTAssertEqual(reloaded.downloadSettings.downloadTimeoutSeconds, 120)
        XCTAssertEqual(reloaded.downloadSettings.etagTimeoutSeconds, 45)
    }

    func testMLXBaseURLUsesLocalhostEvenIfPersistedHostIsUnsafe() {
        let settings = DashboardSettings(mlxHost: "0.0.0.0", mlxPort: 8080)

        XCTAssertEqual(settings.mlxBaseURL.absoluteString, "http://127.0.0.1:8080")
    }

    func testDashboardSettingsDefaultsProviderDebugCaptureOn() {
        XCTAssertTrue(DashboardSettings().providerDebugCaptureEnabled)
    }

    func testDashboardSettingsDefaultsProviderRoleAssignmentsEmptyWhenMissing() throws {
        let json = Data(
            #"{"activeModel":"mlx-community/Tiny","mlxHost":"127.0.0.1","mlxPort":8080,"providerHost":"127.0.0.1","providerPort":8123,"serverFlags":[],"providerDebugCaptureEnabled":true}"#.utf8
        )

        let settings = try JSONDecoder().decode(DashboardSettings.self, from: json)

        XCTAssertEqual(settings.activeModel, "mlx-community/Tiny")
        XCTAssertEqual(settings.providerRoleAssignments, ProviderRoleAssignments())
    }

    func testDashboardSettingsDefaultsDownloadSettingsWhenMissing() throws {
        let json = Data(
            #"{"activeModel":"mlx-community/Tiny","mlxHost":"127.0.0.1","mlxPort":8080,"providerHost":"127.0.0.1","providerPort":8123,"serverFlags":[],"providerDebugCaptureEnabled":true,"providerRoleAssignments":{}}"#.utf8
        )

        let settings = try JSONDecoder().decode(DashboardSettings.self, from: json)

        XCTAssertEqual(settings.downloadSettings, .standardDefault)
    }

    func testDashboardSettingsDefaultsPartialDownloadSettingsFields() throws {
        let json = Data(
            #"{"activeModel":"mlx-community/Tiny","mlxHost":"127.0.0.1","mlxPort":8080,"providerHost":"127.0.0.1","providerPort":8123,"serverFlags":[],"providerDebugCaptureEnabled":true,"providerRoleAssignments":{},"downloadSettings":{"mode":"xetCustom"}}"#.utf8
        )

        let settings = try JSONDecoder().decode(DashboardSettings.self, from: json)

        XCTAssertEqual(settings.downloadSettings.mode, .xetCustom)
        XCTAssertEqual(settings.downloadSettings.xetConcurrency, 4)
        XCTAssertEqual(settings.downloadSettings.downloadTimeoutSeconds, 60)
        XCTAssertEqual(settings.downloadSettings.etagTimeoutSeconds, 30)
    }

    func testDownloadSettingsClampsCustomValues() {
        let settings = HuggingFaceDownloadSettings(
            mode: .xetCustom,
            xetConcurrency: 50,
            downloadTimeoutSeconds: 2,
            etagTimeoutSeconds: 999
        ).validated()

        XCTAssertEqual(settings.xetConcurrency, 16)
        XCTAssertEqual(settings.downloadTimeoutSeconds, 10)
        XCTAssertEqual(settings.etagTimeoutSeconds, 120)
    }

    func testTokenStoreCreatesStableTokenAndCanRegenerate() throws {
        let store = EphemeralProviderTokenStore()

        let first = try store.token()
        let second = try store.token()
        XCTAssertEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.count, 32)

        let regenerated = try store.regenerateToken()
        XCTAssertNotEqual(first, regenerated)
        XCTAssertEqual(try store.token(), regenerated)
    }

    func testModelRegistryPersistsInstalledFailedAndRemovedRecords() throws {
        let root = try temporaryDirectory()
        let registry = ModelRegistry(fileURL: root.appending(path: "models/registry.json"))

        registry.upsert(ModelRecord(id: "mlx-community/Small", status: .installed, localPath: "/cache/small"))
        registry.upsert(ModelRecord(id: "mlx-community/Broken", status: .failed, localPath: nil, message: "download failed"))
        registry.markRemoved(id: "mlx-community/Small")
        try registry.save()

        let reloaded = ModelRegistry(fileURL: root.appending(path: "models/registry.json"))
        try reloaded.load()
        XCTAssertEqual(reloaded.records.count, 2)
        XCTAssertEqual(reloaded.record(id: "mlx-community/Small")?.status, .removed)
        XCTAssertEqual(reloaded.record(id: "mlx-community/Broken")?.message, "download failed")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MLXCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
