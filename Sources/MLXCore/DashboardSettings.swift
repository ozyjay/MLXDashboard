import Foundation

public enum ProviderModelRole: String, Codable, Equatable, Sendable {
    case ask
    case plan
    case coding
}

public struct ProviderRoleAssignments: Codable, Equatable, Sendable {
    public var ask: String?
    public var plan: String?
    public var coding: String?

    public init(ask: String? = nil, plan: String? = nil, coding: String? = nil) {
        self.ask = ask
        self.plan = plan
        self.coding = coding
    }

    public func model(for role: ProviderModelRole) -> String? {
        switch role {
        case .ask:
            ask
        case .plan:
            plan
        case .coding:
            coding
        }
    }

    public mutating func setModel(_ model: String?, for role: ProviderModelRole) {
        switch role {
        case .ask:
            ask = model
        case .plan:
            plan = model
        case .coding:
            coding = model
        }
    }
}

public struct DashboardSettings: Codable, Equatable, Sendable {
    public static let localMLXHost = "127.0.0.1"

    public var activeModel: String?
    public var mlxHost: String
    public var mlxPort: Int
    public var providerHost: String
    public var providerPort: Int
    public var serverFlags: [String]
    public var providerDebugCaptureEnabled: Bool
    public var providerRoleAssignments: ProviderRoleAssignments

    public init(
        activeModel: String? = nil,
        mlxHost: String = "127.0.0.1",
        mlxPort: Int = 8080,
        providerHost: String = "127.0.0.1",
        providerPort: Int = 8123,
        serverFlags: [String] = [],
        providerDebugCaptureEnabled: Bool = true,
        providerRoleAssignments: ProviderRoleAssignments = ProviderRoleAssignments()
    ) {
        self.activeModel = activeModel
        self.mlxHost = mlxHost
        self.mlxPort = mlxPort
        self.providerHost = providerHost
        self.providerPort = providerPort
        self.serverFlags = serverFlags
        self.providerDebugCaptureEnabled = providerDebugCaptureEnabled
        self.providerRoleAssignments = providerRoleAssignments
    }

    private enum CodingKeys: String, CodingKey {
        case activeModel
        case mlxHost
        case mlxPort
        case providerHost
        case providerPort
        case serverFlags
        case providerDebugCaptureEnabled
        case providerRoleAssignments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.activeModel = try container.decodeIfPresent(String.self, forKey: .activeModel)
        self.mlxHost = try container.decodeIfPresent(String.self, forKey: .mlxHost) ?? "127.0.0.1"
        self.mlxPort = try container.decodeIfPresent(Int.self, forKey: .mlxPort) ?? 8080
        self.providerHost = try container.decodeIfPresent(String.self, forKey: .providerHost) ?? "127.0.0.1"
        self.providerPort = try container.decodeIfPresent(Int.self, forKey: .providerPort) ?? 8123
        self.serverFlags = try container.decodeIfPresent([String].self, forKey: .serverFlags) ?? []
        self.providerDebugCaptureEnabled = try container.decodeIfPresent(Bool.self, forKey: .providerDebugCaptureEnabled) ?? true
        self.providerRoleAssignments = try container.decodeIfPresent(ProviderRoleAssignments.self, forKey: .providerRoleAssignments) ?? ProviderRoleAssignments()
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
