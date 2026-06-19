import Foundation

public final class ProviderDebugRecorder: @unchecked Sendable {
    private let fileURL: URL
    private let isEnabled: @Sendable () -> Bool
    private let maxBytes: Int
    private let retainedFileCount: Int
    private let lock = NSLock()

    public init(
        fileURL: URL,
        isEnabled: @escaping @Sendable () -> Bool,
        maxBytes: Int = 5_000_000,
        retainedFileCount: Int = 3
    ) {
        self.fileURL = fileURL
        self.isEnabled = isEnabled
        self.maxBytes = maxBytes
        self.retainedFileCount = retainedFileCount
    }

    public var isEnabledNow: Bool {
        isEnabled()
    }

    public func record(
        request: ProviderRequest,
        response: ProviderResponse,
        selectedModel: String?,
        aliasResolution: String?,
        routingDecision: [String: Any]? = nil,
        modeAdvice: [String: Any]? = nil
    ) {
        guard isEnabled() else { return }

        let requestObject = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "method": request.method,
            "path": request.path,
            "headers": redactedHeaders(request.headers),
            "top_level_keys": requestObject?.keys.sorted() ?? [],
            "request_body_bytes": request.body.count,
            "response_status": response.status,
            "response_body_bytes": response.body.count
        ]
        if let selectedModel {
            payload["selected_model"] = selectedModel
        }
        if let aliasResolution {
            payload["alias_resolution"] = aliasResolution
        }
        if let routingDecision {
            payload["routing_decision"] = routingDecision
        }
        if let modeAdvice {
            payload["mode_advice"] = modeAdvice
        }
        if let requestText = String(data: request.body, encoding: .utf8) {
            payload["request_body_text"] = requestText
        }
        if let responseText = String(data: response.body, encoding: .utf8) {
            payload["response_body_text"] = responseText
        }

        appendJSONLine(payload)
    }

    private func appendJSONLine(_ payload: [String: Any]) {
        lock.withLock {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                var line = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                line.append(Data("\n".utf8))
                try rotateIfNeeded(incomingByteCount: line.count)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                    try handle.close()
                } else {
                    try line.write(to: fileURL, options: [.atomic])
                }
            } catch {
                // Provider diagnostics must never break request handling.
            }
        }
    }

    private func rotateIfNeeded(incomingByteCount: Int) throws {
        guard maxBytes > 0,
              FileManager.default.fileExists(atPath: fileURL.path)
        else { return }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let currentSize = attributes[.size] as? Int ?? 0
        guard currentSize + incomingByteCount > maxBytes else { return }

        if retainedFileCount <= 0 {
            try FileManager.default.removeItem(at: fileURL)
            return
        }

        let oldest = rotatedURL(index: retainedFileCount)
        if FileManager.default.fileExists(atPath: oldest.path) {
            try FileManager.default.removeItem(at: oldest)
        }

        if retainedFileCount > 1 {
            for index in stride(from: retainedFileCount - 1, through: 1, by: -1) {
                let source = rotatedURL(index: index)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let destination = rotatedURL(index: index + 1)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }

        let firstRotation = rotatedURL(index: 1)
        if FileManager.default.fileExists(atPath: firstRotation.path) {
            try FileManager.default.removeItem(at: firstRotation)
        }
        try FileManager.default.moveItem(at: fileURL, to: firstRotation)
    }

    private func rotatedURL(index: Int) -> URL {
        URL(fileURLWithPath: "\(fileURL.path).\(index)")
    }

    private func redactedHeaders(_ headers: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: headers.map { name, value in
            let lowercased = name.lowercased()
            let shouldRedact = lowercased.contains("authorization")
                || lowercased.contains("api-key")
                || lowercased.contains("api_key")
                || lowercased.contains("token")
                || lowercased.contains("secret")
            return (name, shouldRedact ? "<redacted>" : value)
        })
    }
}
