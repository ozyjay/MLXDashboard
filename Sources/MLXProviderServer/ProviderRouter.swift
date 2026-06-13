import Foundation

public struct ProviderRouter: Sendable {
    private let upstream: any ProviderUpstreamClient
    private let activeModelProvider: @Sendable () -> String?
    private let eventLogger: @Sendable (String) -> Void
    private let allowedPaths: Set<String> = [
        "/v1/models",
        "/v1/chat/completions",
        "/v1/completions"
    ]

    public init(
        upstream: any ProviderUpstreamClient,
        activeModelProvider: @escaping @Sendable () -> String? = { nil },
        eventLogger: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.upstream = upstream
        self.activeModelProvider = activeModelProvider
        self.eventLogger = eventLogger
    }

    public func handle(_ request: ProviderRequest) async throws -> ProviderResponse {
        let request = requestWithCanonicalPath(request)

        if request.method == "GET", request.path == "/health" {
            eventLogger("Provider health check")
            return json(status: 200, #"{"status":"ok"}"#)
        }

        guard allowedPaths.contains(request.path) else {
            eventLogger("Provider rejected \(request.method) \(request.path): unsupported route")
            return json(status: 404, #"{"error":"not found"}"#)
        }

        if request.method == "GET", request.path == "/v1/models" {
            eventLogger("Provider served GET /v1/models")
            return modelsResponse()
        }

        let proxiedRequest = requestWithActiveModelIfAvailable(request)
        eventLogger("Provider proxied \(request.method) \(request.path) to upstream")
        return try await upstream.proxy(proxiedRequest)
    }

    private func requestWithCanonicalPath(_ request: ProviderRequest) -> ProviderRequest {
        let canonicalPath = canonicalPath(for: request.path)
        guard canonicalPath != request.path else { return request }
        eventLogger("Provider normalized \(request.method) \(request.path) to \(canonicalPath)")
        return ProviderRequest(method: request.method, path: canonicalPath, headers: request.headers, body: request.body)
    }

    private func canonicalPath(for path: String) -> String {
        var path = path
        while path.hasPrefix("/v1/v1/") {
            path = "/v1/" + String(path.dropFirst("/v1/v1/".count))
        }
        switch path {
        case "/models":
            return "/v1/models"
        case "/chat/completions":
            return "/v1/chat/completions"
        case "/completions":
            return "/v1/completions"
        default:
            return path
        }
    }

    private func json(status: Int, _ body: String) -> ProviderResponse {
        ProviderResponse(
            status: status,
            headers: ["content-type": "application/json"],
            body: Data(body.utf8)
        )
    }

    private func modelsResponse() -> ProviderResponse {
        guard let activeModel = activeModelProvider(), !activeModel.isEmpty else {
            return json(status: 200, #"{"object":"list","data":[]}"#)
        }

        let payload: [String: Any] = [
            "object": "list",
            "data": [
                [
                    "id": activeModel,
                    "object": "model"
                ]
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(#"{"object":"list","data":[]}"#.utf8)
        return ProviderResponse(status: 200, headers: ["content-type": "application/json"], body: data)
    }

    private func requestWithActiveModelIfAvailable(_ request: ProviderRequest) -> ProviderRequest {
        guard request.method == "POST",
              request.path == "/v1/chat/completions" || request.path == "/v1/completions",
              let activeModel = activeModelProvider(),
              !activeModel.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        else { return request }

        var payload = object
        payload["model"] = activeModel
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return request }
        eventLogger("Provider rewrote \(request.method) \(request.path) model to active model \(activeModel)")

        return ProviderRequest(method: request.method, path: request.path, headers: request.headers, body: body)
    }
}
