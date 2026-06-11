import Foundation
import Combine

public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), message: String) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
    }
}

public final class TelemetryStore: ObservableObject {
    @Published public private(set) var requestCount: Int
    @Published public private(set) var latencies: [TimeInterval]
    @Published public private(set) var logs: [LogEntry]
    public let startedAt: Date

    public init(startedAt: Date = Date()) {
        self.startedAt = startedAt
        self.requestCount = 0
        self.latencies = []
        self.logs = []
    }

    public var uptime: TimeInterval {
        Date().timeIntervalSince(startedAt)
    }

    public var averageLatency: TimeInterval? {
        guard !latencies.isEmpty else { return nil }
        return latencies.reduce(0, +) / Double(latencies.count)
    }

    public func recordRequest(latency: TimeInterval) {
        requestCount += 1
        latencies.append(latency)
        if latencies.count > 200 {
            latencies.removeFirst(latencies.count - 200)
        }
    }

    public func appendLog(_ message: String) {
        logs.append(LogEntry(message: message))
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }
}
