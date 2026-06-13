import XCTest
import MLXCore
@testable import MLXProviderServer

final class ProviderRouterTests: XCTestCase {
    func testHealthDoesNotRequireBearerToken() async throws {
        let router = ProviderRouter(
            upstream: FakeUpstream()
        )

        let response = try await router.handle(
            ProviderRequest(method: "GET", path: "/health", headers: [:], body: Data())
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), #"{"status":"ok"}"#)
    }

    func testProviderRoutesDoNotRequireBearerToken() async throws {
        let logger = CapturingProviderLogger()
        let router = ProviderRouter(
            upstream: FakeUpstream(),
            activeModelProvider: { "mlx-community/Tiny" },
            eventLogger: logger.log
        )

        let models = try await router.handle(
            ProviderRequest(method: "GET", path: "/v1/models", headers: [:], body: Data())
        )
        let chat = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: [:],
                body: Data(#"{"messages":[{"role":"user","content":"hi"}],"stream":true}"#.utf8)
            )
        )

        XCTAssertEqual(models.status, 200)
        XCTAssertEqual(try modelIDs(in: models.body), ["mlx-community/Tiny"])
        XCTAssertEqual(chat.status, 200)
        XCTAssertFalse(logger.messages.contains { $0.localizedCaseInsensitiveContains("auth") })
    }

    func testProviderServesConfiguredActiveModelInsteadOfProxyingModels() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit" }
        )

        let models = try await router.handle(
            ProviderRequest(method: "GET", path: "/v1/models", headers: [:], body: Data())
        )

        XCTAssertEqual(models.status, 200)
        XCTAssertEqual(try modelIDs(in: models.body), ["mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit"])
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderRewritesChatCompletionModelToActiveModel() async throws {
        let upstream = FakeUpstream()
        let logger = CapturingProviderLogger()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit" },
            eventLogger: logger.log
        )
        let body = Data(#"{"model":null,"messages":[{"role":"user","content":"hi"}],"stream":true}"#.utf8)

        let chat = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )

        XCTAssertEqual(chat.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let json = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit")
        XCTAssertTrue(logger.messages.contains {
            $0 == "Provider rewrote POST /v1/chat/completions model to active model mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit"
        })
        XCTAssertTrue(logger.messages.contains {
            $0 == "Provider proxied POST /v1/chat/completions to upstream"
        })
    }

    func testProviderProxiesChatCompletionsToUpstream() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream
        )
        let body = Data(#"{"messages":[{"role":"user","content":"hi"}],"stream":true}"#.utf8)

        let chat = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )

        XCTAssertEqual(chat.status, 200)
        XCTAssertEqual(chat.headers["content-type"], "text/event-stream")
        XCTAssertEqual(String(data: chat.body, encoding: .utf8), "data: {\"delta\":\"hi\"}\n\n")
        XCTAssertEqual(upstream.requests.map(\.path), ["/v1/chat/completions"])
    }

    func testProviderNormalizesCommonOpenAICompatiblePathVariants() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
        )

        let duplicatedVersionModels = try await router.handle(
            ProviderRequest(method: "GET", path: "/v1/v1/models", headers: [:], body: Data())
        )
        let unversionedChat = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/chat/completions",
                headers: [:],
                body: Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8)
            )
        )
        let duplicatedVersionChat = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/v1/chat/completions",
                headers: [:],
                body: Data(#"{"messages":[{"role":"user","content":"hi again"}]}"#.utf8)
            )
        )

        XCTAssertEqual(duplicatedVersionModels.status, 200)
        XCTAssertEqual(try modelIDs(in: duplicatedVersionModels.body), ["mlx-community/Tiny"])
        XCTAssertEqual(unversionedChat.status, 200)
        XCTAssertEqual(duplicatedVersionChat.status, 200)
        XCTAssertEqual(upstream.requests.map(\.path), ["/v1/chat/completions", "/v1/chat/completions"])
    }

    func testNIOProviderServerServesHealthAndTokenlessModels() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
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

        let modelsURL = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let (modelsData, modelsResponse) = try await URLSession.shared.data(from: modelsURL)
        XCTAssertEqual((modelsResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try modelIDs(in: modelsData), ["mlx-community/Tiny"])
    }

    private func modelIDs(in data: Data) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = object?["data"] as? [[String: Any]]
        return models?.compactMap { $0["id"] as? String } ?? []
    }
}

private final class CapturingProviderLogger: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMessages: [String] = []

    var messages: [String] {
        lock.withLock { storedMessages }
    }

    func log(_ message: String) {
        lock.withLock {
            storedMessages.append(message)
        }
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
