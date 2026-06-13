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
    public let logFileURL: URL?
    private let logFileLock = NSLock()

    public init(
        startedAt: Date = Date(),
        logFileURL: URL? = AppPaths.default.logsDirectory.appending(path: "mlxdashboard.log")
    ) {
        self.startedAt = startedAt
        self.logFileURL = logFileURL
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
        let entry = LogEntry(message: message)
        logs.append(entry)
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
        persistLog(entry)
    }

    private func persistLog(_ entry: LogEntry) {
        guard let logFileURL else { return }
        logFileLock.withLock {
            do {
                try FileManager.default.createDirectory(
                    at: logFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
                let line = "\(timestamp) \(entry.message)\n"
                if FileManager.default.fileExists(atPath: logFileURL.path) {
                    let handle = try FileHandle(forWritingTo: logFileURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(line.utf8))
                    try handle.close()
                } else {
                    try Data(line.utf8).write(to: logFileURL, options: [.atomic])
                }
            } catch {
                // Telemetry should never break dashboard behavior.
            }
        }
    }
}
