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
            serverFlags: ["--trust-remote-code"]
        )

        try store.save(settings)

        let reloaded = try store.load()
        XCTAssertEqual(reloaded.activeModel, "mlx-community/Qwen3-8B-4bit")
        XCTAssertEqual(reloaded.mlxPort, 8080)
        XCTAssertEqual(reloaded.providerPort, 8123)
        XCTAssertEqual(reloaded.serverFlags, ["--trust-remote-code"])
    }

    func testMLXBaseURLUsesLocalhostEvenIfPersistedHostIsUnsafe() {
        let settings = DashboardSettings(mlxHost: "0.0.0.0", mlxPort: 8080)

        XCTAssertEqual(settings.mlxBaseURL.absoluteString, "http://127.0.0.1:8080")
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
