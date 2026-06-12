import Foundation

public enum ModelStatus: String, Codable, Equatable, Sendable {
    case installing
    case installed
    case paused
    case failed
    case removed
}

public struct ModelRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var status: ModelStatus
    public var localPath: String?
    public var message: String?
    public var updatedAt: Date

    public init(
        id: String,
        status: ModelStatus,
        localPath: String? = nil,
        message: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.status = status
        self.localPath = localPath
        self.message = message
        self.updatedAt = updatedAt
    }
}

public final class ModelRegistry {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public private(set) var records: [ModelRecord]

    public init(fileURL: URL = AppPaths.default.modelRegistryFile) {
        self.fileURL = fileURL
        self.records = []
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            return
        }
        let data = try Data(contentsOf: fileURL)
        records = try decoder.decode([ModelRecord].self, from: data)
    }

    public func save() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(records.sorted { $0.id < $1.id })
        try data.write(to: fileURL, options: [.atomic])
    }

    public func upsert(_ record: ModelRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort { $0.id < $1.id }
    }

    public func markRemoved(id: String) {
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].status = .removed
            records[index].updatedAt = Date()
        } else {
            upsert(ModelRecord(id: id, status: .removed))
        }
    }

    public func record(id: String) -> ModelRecord? {
        records.first { $0.id == id }
    }
}
