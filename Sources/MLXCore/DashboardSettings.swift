import Foundation

public struct DashboardSettings: Codable, Equatable, Sendable {
    public static let localMLXHost = "127.0.0.1"

    public var activeModel: String?
    public var mlxHost: String
    public var mlxPort: Int
    public var providerHost: String
    public var providerPort: Int
    public var serverFlags: [String]

    public init(
        activeModel: String? = nil,
        mlxHost: String = "127.0.0.1",
        mlxPort: Int = 8080,
        providerHost: String = "127.0.0.1",
        providerPort: Int = 8123,
        serverFlags: [String] = []
    ) {
        self.activeModel = activeModel
        self.mlxHost = mlxHost
        self.mlxPort = mlxPort
        self.providerHost = providerHost
        self.providerPort = providerPort
        self.serverFlags = serverFlags
    }

    public var providerBaseURL: URL {
        URL(string: "http://\(providerHost):\(providerPort)/v1")!
    }

    public var mlxBaseURL: URL {
        URL(string: "http://\(Self.localMLXHost):\(mlxPort)")!
    }
}

public final class SettingsStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL = AppPaths.default.settingsFile) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public func load() throws -> DashboardSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return DashboardSettings()
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(DashboardSettings.self, from: data)
    }

    public func save(_ settings: DashboardSettings) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: [.atomic])
    }
}
