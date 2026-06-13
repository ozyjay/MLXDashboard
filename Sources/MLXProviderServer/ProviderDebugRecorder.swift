import Foundation

public final class ProviderDebugRecorder: @unchecked Sendable {
    private let fileURL: URL
    private let isEnabled: @Sendable () -> Bool
    private let lock = NSLock()

    public init(fileURL: URL, isEnabled: @escaping @Sendable () -> Bool) {
        self.fileURL = fileURL
        self.isEnabled = isEnabled
    }

    public var isEnabledNow: Bool {
        isEnabled()
    }

    public func record(
        request: ProviderRequest,
        response: ProviderResponse,
        selectedModel: String?,
        aliasResolution: String?,
        routingDecision: [String: Any]? = nil
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
