import XCTest
import MLXCore
@testable import MLXProviderServer

final class ProviderRouterTests: XCTestCase {
    func testHealthDoesNotRequireBearerToken() async throws {
        let router = ProviderRouter(
            tokenProvider: { "secret-token" },
            upstream: FakeUpstream()
        )

        let response = try await router.handle(
            ProviderRequest(method: "GET", path: "/health", headers: [:], body: Data())
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), #"{"status":"ok"}"#)
    }

    func testProviderRejectsMissingOrWrongBearerToken() async throws {
        let router = ProviderRouter(
            tokenProvider: { "secret-token" },
            upstream: FakeUpstream()
        )

        let missing = try await router.handle(
            ProviderRequest(method: "GET", path: "/v1/models", headers: [:], body: Data())
        )
        let wrong = try await router.handle(
            ProviderRequest(method: "GET", path: "/v1/models", headers: ["authorization": "Bearer wrong"], body: Data())
        )

        XCTAssertEqual(missing.status, 401)
        XCTAssertEqual(wrong.status, 401)
    }

    func testProviderProxiesModelsAndChatCompletionsToUpstream() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            tokenProvider: { "secret-token" },
            upstream: upstream
        )
        let body = Data(#"{"messages":[{"role":"user","content":"hi"}],"stream":true}"#.utf8)

        let models = try await router.handle(
            ProviderRequest(method: "GET", path: "/v1/models", headers: ["authorization": "Bearer secret-token"], body: Data())
        )
        let chat = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: ["authorization": "Bearer secret-token"], body: body)
        )

        XCTAssertEqual(models.status, 200)
        XCTAssertEqual(String(data: models.body, encoding: .utf8), #"{"object":"list","data":[]}"#)
        XCTAssertEqual(chat.status, 200)
        XCTAssertEqual(chat.headers["content-type"], "text/event-stream")
        XCTAssertEqual(String(data: chat.body, encoding: .utf8), "data: {\"delta\":\"hi\"}\n\n")
        XCTAssertEqual(upstream.requests.map(\.path), ["/v1/models", "/v1/chat/completions"])
    }

    func testNIOProviderServerServesHealthAndTokenProtectedModels() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            tokenProvider: { "secret-token" },
            upstream: upstream
        )
        let server = NIOProviderServer(host: "127.0.0.1", port: 0, router: router)
        do {
            try server.start()
        } catch {
            throw XCTSkip("Loopback listener unavailable in this sandbox: \(error)")
        }
        defer { try? server.stop() }
        let port = try XCTUnwrap(server.boundPort)

        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        let (healthData, healthResponse) = try await URLSession.shared.data(from: healthURL)
        XCTAssertEqual((healthResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: healthData, encoding: .utf8), #"{"status":"ok"}"#)

        var modelsRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        modelsRequest.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        let (modelsData, modelsResponse) = try await URLSession.shared.data(for: modelsRequest)
        XCTAssertEqual((modelsResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: modelsData, encoding: .utf8), #"{"object":"list","data":[]}"#)
    }
}

private final class FakeUpstream: ProviderUpstreamClient, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [ProviderRequest] = []

    var requests: [ProviderRequest] {
        lock.withLock { storedRequests }
    }

    func proxy(_ request: ProviderRequest) async throws -> ProviderResponse {
        lock.withLock {
            storedRequests.append(request)
        }
        switch request.path {
        case "/v1/models":
            return ProviderResponse(status: 200, headers: ["content-type": "application/json"], body: Data(#"{"object":"list","data":[]}"#.utf8))
        case "/v1/chat/completions":
            return ProviderResponse(status: 200, headers: ["content-type": "text/event-stream"], body: Data("data: {\"delta\":\"hi\"}\n\n".utf8))
        default:
            return ProviderResponse(status: 404, headers: [:], body: Data())
        }
    }
}
