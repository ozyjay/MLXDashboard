import Foundation

public struct ProviderRouter: Sendable {
    private let tokenProvider: @Sendable () throws -> String
    private let upstream: any ProviderUpstreamClient
    private let allowedPaths: Set<String> = [
        "/v1/models",
        "/v1/chat/completions",
        "/v1/completions"
    ]

    public init(
        tokenProvider: @escaping @Sendable () throws -> String,
        upstream: any ProviderUpstreamClient
    ) {
        self.tokenProvider = tokenProvider
        self.upstream = upstream
    }

    public func handle(_ request: ProviderRequest) async throws -> ProviderResponse {
        if request.method == "GET", request.path == "/health" {
            return json(status: 200, #"{"status":"ok"}"#)
        }

        guard allowedPaths.contains(request.path) else {
            return json(status: 404, #"{"error":"not found"}"#)
        }

        guard try isAuthorized(request) else {
            return json(status: 401, #"{"error":"unauthorized"}"#)
        }

        return try await upstream.proxy(request)
    }

    private func isAuthorized(_ request: ProviderRequest) throws -> Bool {
        guard let authorization = request.header("authorization") else {
            return false
        }
        return authorization == "Bearer \(try tokenProvider())"
    }

    private func json(status: Int, _ body: String) -> ProviderResponse {
        ProviderResponse(
            status: status,
            headers: ["content-type": "application/json"],
            body: Data(body.utf8)
        )
    }
}
