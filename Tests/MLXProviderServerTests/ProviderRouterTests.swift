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
        XCTAssertEqual(try modelIDs(in: models.body), expectedModels(active: "mlx-community/Tiny"))
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
        XCTAssertEqual(try modelIDs(in: models.body), expectedModels(active: "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit"))
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderAdvertisesModeAliasesAlongsideActiveModel() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
        )

        let models = try await router.handle(
            ProviderRequest(method: "GET", path: "/v1/models", headers: [:], body: Data())
        )
        let v0Models = try await router.handle(
            ProviderRequest(method: "GET", path: "/api/v0/models", headers: [:], body: Data())
        )
        let tags = try await router.handle(
            ProviderRequest(method: "GET", path: "/api/tags", headers: [:], body: Data())
        )

        XCTAssertEqual(try modelIDs(in: models.body), ["mlx-ask", "mlx-plan", "mlx-fast", "mlx-community/Tiny"])
        XCTAssertEqual(try modelIDs(in: v0Models.body), ["mlx-ask", "mlx-plan", "mlx-fast", "mlx-community/Tiny"])

        let tagsJSON = try JSONSerialization.jsonObject(with: tags.body) as? [String: Any]
        let tagModels = try XCTUnwrap(tagsJSON?["models"] as? [[String: Any]])
        XCTAssertEqual(tagModels.compactMap { $0["name"] as? String }, ["mlx-ask", "mlx-plan", "mlx-fast", "mlx-community/Tiny"])
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderServesAliasMetadataByIDAndShow() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
        )

        let metadata = try await router.handle(
            ProviderRequest(method: "GET", path: "/api/v0/models/mlx-fast", headers: [:], body: Data())
        )
        let show = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/api/show",
                headers: [:],
                body: Data(#"{"model":"mlx-fast"}"#.utf8)
            )
        )

        XCTAssertEqual(metadata.status, 200)
        let metadataJSON = try JSONSerialization.jsonObject(with: metadata.body) as? [String: Any]
        XCTAssertEqual(metadataJSON?["id"] as? String, "mlx-fast")
        XCTAssertEqual(metadataJSON?["compatibility_type"] as? String, "mlx")

        XCTAssertEqual(show.status, 200)
        let showJSON = try JSONSerialization.jsonObject(with: show.body) as? [String: Any]
        XCTAssertEqual(showJSON?["model"] as? String, "mlx-fast")
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderServesConfiguredActiveModelByID() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit" }
        )

        let model = try await router.handle(
            ProviderRequest(
                method: "GET",
                path: "/v1/models/mlx-community%2FDevstral-Small-2-24B-Instruct-2512-4bit",
                headers: [:],
                body: Data()
            )
        )

        XCTAssertEqual(model.status, 200)
        let json = try JSONSerialization.jsonObject(with: model.body) as? [String: Any]
        XCTAssertEqual(json?["id"] as? String, "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit")
        XCTAssertEqual(json?["object"] as? String, "model")
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderServesAndroidStudioV0ModelMetadataForActiveModel() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit" }
        )

        let models = try await router.handle(
            ProviderRequest(method: "GET", path: "/api/v0/models", headers: [:], body: Data())
        )

        XCTAssertEqual(models.status, 200)
        let json = try JSONSerialization.jsonObject(with: models.body) as? [String: Any]
        let data = try XCTUnwrap(json?["data"] as? [[String: Any]])
        let model = try XCTUnwrap(data.first { $0["id"] as? String == "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit" })
        XCTAssertEqual(model["id"] as? String, "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit")
        XCTAssertEqual(model["object"] as? String, "model")
        XCTAssertEqual(model["type"] as? String, "llm")
        XCTAssertEqual(model["publisher"] as? String, "mlx-community")
        XCTAssertEqual(model["compatibility_type"] as? String, "mlx")
        XCTAssertEqual(model["state"] as? String, "loaded")
        XCTAssertEqual(model["max_context_length"] as? Int, 32768)
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderServesAndroidStudioV0ModelMetadataByID() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit" }
        )

        let response = try await router.handle(
            ProviderRequest(
                method: "GET",
                path: "/api/v0/models/mlx-community%2FDevstral-Small-2-24B-Instruct-2512-4bit",
                headers: [:],
                body: Data()
            )
        )

        XCTAssertEqual(response.status, 200)
        let model = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertEqual(model?["id"] as? String, "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit")
        XCTAssertEqual(model?["type"] as? String, "llm")
        XCTAssertEqual(model?["compatibility_type"] as? String, "mlx")
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderServesAndroidStudioTagsDiscoveryForActiveModel() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit" }
        )

        let tags = try await router.handle(
            ProviderRequest(method: "GET", path: "/api/tags", headers: [:], body: Data())
        )

        XCTAssertEqual(tags.status, 200)
        let json = try JSONSerialization.jsonObject(with: tags.body) as? [String: Any]
        let models = try XCTUnwrap(json?["models"] as? [[String: Any]])
        XCTAssertEqual(models.compactMap { $0["name"] as? String }, expectedModels(active: "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit"))
        XCTAssertEqual(models.compactMap { $0["model"] as? String }, expectedModels(active: "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit"))
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderServesAndroidStudioRunningModelsDiscoveryForActiveModel() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit" }
        )

        let ps = try await router.handle(
            ProviderRequest(method: "GET", path: "/api/ps", headers: [:], body: Data())
        )

        XCTAssertEqual(ps.status, 200)
        let json = try JSONSerialization.jsonObject(with: ps.body) as? [String: Any]
        let models = try XCTUnwrap(json?["models"] as? [[String: Any]])
        XCTAssertEqual(models.compactMap { $0["name"] as? String }, expectedModels(active: "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit"))
        XCTAssertEqual(models.compactMap { $0["model"] as? String }, expectedModels(active: "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit"))
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderServesAndroidStudioVersionAndShowDiscoveryRoutes() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit" }
        )

        let version = try await router.handle(
            ProviderRequest(method: "GET", path: "/api/version", headers: [:], body: Data())
        )
        let show = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/api/show",
                headers: [:],
                body: Data(#"{"model":"mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit"}"#.utf8)
            )
        )

        XCTAssertEqual(version.status, 200)
        let versionJSON = try JSONSerialization.jsonObject(with: version.body) as? [String: Any]
        XCTAssertEqual(versionJSON?["version"] as? String, "0.0.0")

        XCTAssertEqual(show.status, 200)
        let showJSON = try JSONSerialization.jsonObject(with: show.body) as? [String: Any]
        XCTAssertEqual(showJSON?["model"] as? String, "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit")
        XCTAssertEqual(showJSON?["license"] as? String, "")
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderServesAndroidStudioShowForDisplayModelAlias() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit" }
        )

        let show = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/api/show",
                headers: [:],
                body: Data(#"{"model":"Devstral-Small-2-24B-Instruct-2512-4bit"}"#.utf8)
            )
        )

        XCTAssertEqual(show.status, 200)
        let showJSON = try JSONSerialization.jsonObject(with: show.body) as? [String: Any]
        XCTAssertEqual(showJSON?["model"] as? String, "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit")
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderTranslatesAndroidStudioCompatibilityChatToChatCompletion() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
        )
        let body = Data(#"{"model":"ignored","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/api/chat", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        XCTAssertEqual(proxied.path, "/v1/chat/completions")
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(proxiedJSON?["model"] as? String, "mlx-community/Tiny")
        XCTAssertEqual(proxiedJSON?["stream"] as? Bool, false)
        let responseJSON = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let message = responseJSON?["message"] as? [String: Any]
        XCTAssertEqual(responseJSON?["model"] as? String, "mlx-community/Tiny")
        XCTAssertEqual(message?["role"] as? String, "assistant")
        XCTAssertEqual(message?["content"] as? String, "Hello from chat.")
        XCTAssertEqual(responseJSON?["done"] as? Bool, true)
    }

    func testProviderTranslatesAndroidStudioCompatibilityGenerateToChatCompletion() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
        )
        let body = Data(#"{"model":"ignored","prompt":"hi","stream":false}"#.utf8)

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/api/generate", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        XCTAssertEqual(proxied.path, "/v1/chat/completions")
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(proxiedJSON?["model"] as? String, "mlx-community/Tiny")
        XCTAssertEqual(proxiedJSON?["stream"] as? Bool, false)
        let messages = try XCTUnwrap(proxiedJSON?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "hi")
        let responseJSON = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertEqual(responseJSON?["model"] as? String, "mlx-community/Tiny")
        XCTAssertEqual(responseJSON?["response"] as? String, "Hello from chat.")
        XCTAssertEqual(responseJSON?["done"] as? Bool, true)
    }

    func testAndroidCompatibilityChatRoutesToAssignedRoleEndpoint() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Gemma" },
            roleAssignmentsProvider: { ProviderRoleAssignments(plan: "mlx-community/Devstral") },
            defaultEndpointProvider: {
                ProviderUpstreamEndpoint(modelID: "mlx-community/Gemma", baseURL: URL(string: "http://127.0.0.1:8080")!, port: 8080)
            },
            roleEndpointProvider: { role in
                role == .plan
                ? ProviderUpstreamEndpoint(modelID: "mlx-community/Devstral", baseURL: URL(string: "http://127.0.0.1:8081")!, port: 8081)
                : nil
            }
        )
        let body = Data(#"{"model":"mlx-plan","messages":[{"role":"user","content":"plan"}],"stream":false}"#.utf8)

        let response = try await router.handle(ProviderRequest(method: "POST", path: "/api/chat", headers: [:], body: body))

        XCTAssertEqual(response.status, 200)
        let endpoint = try XCTUnwrap(upstream.endpoints.last)
        XCTAssertEqual(endpoint.modelID, "mlx-community/Devstral")
        XCTAssertEqual(endpoint.port, 8081)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(proxiedJSON?["model"] as? String, "mlx-community/Devstral")
        let responseJSON = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertEqual(responseJSON?["model"] as? String, "mlx-community/Devstral")
    }

    func testAndroidCompatibilityGenerateRoutesToAssignedRoleEndpoint() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Gemma" },
            roleAssignmentsProvider: { ProviderRoleAssignments(plan: "mlx-community/Devstral") },
            defaultEndpointProvider: {
                ProviderUpstreamEndpoint(modelID: "mlx-community/Gemma", baseURL: URL(string: "http://127.0.0.1:8080")!, port: 8080)
            },
            roleEndpointProvider: { role in
                role == .plan
                ? ProviderUpstreamEndpoint(modelID: "mlx-community/Devstral", baseURL: URL(string: "http://127.0.0.1:8081")!, port: 8081)
                : nil
            }
        )
        let body = Data(#"{"model":"mlx-plan","prompt":"plan","stream":false}"#.utf8)

        let response = try await router.handle(ProviderRequest(method: "POST", path: "/api/generate", headers: [:], body: body))

        XCTAssertEqual(response.status, 200)
        let endpoint = try XCTUnwrap(upstream.endpoints.last)
        XCTAssertEqual(endpoint.modelID, "mlx-community/Devstral")
        XCTAssertEqual(endpoint.port, 8081)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(proxiedJSON?["model"] as? String, "mlx-community/Devstral")
        let responseJSON = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertEqual(responseJSON?["model"] as? String, "mlx-community/Devstral")
    }

    func testAndroidCompatibilityChatFailsClosedWithoutAnyAvailableEndpoint() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Gemma" },
            roleAssignmentsProvider: { ProviderRoleAssignments(plan: "mlx-community/Devstral") },
            defaultEndpointProvider: { nil },
            roleEndpointProvider: { _ in nil }
        )
        let body = Data(#"{"model":"mlx-plan","messages":[{"role":"user","content":"plan"}],"stream":false}"#.utf8)

        let response = try await router.handle(ProviderRequest(method: "POST", path: "/api/chat", headers: [:], body: body))

        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(upstream.requests.count, 0)
        XCTAssertEqual(upstream.endpoints.count, 0)
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
            $0 == "Provider streaming POST /v1/chat/completions from upstream with status 200"
        })
    }

    func testProviderResolvesModeAliasToActiveModelForChatCompletion() async throws {
        let upstream = FakeUpstream()
        let logger = CapturingProviderLogger()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" },
            eventLogger: logger.log
        )
        let body = Data(#"{"model":"mlx-fast","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)

        let chat = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )

        XCTAssertEqual(chat.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let json = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "mlx-community/Tiny")
        XCTAssertTrue(logger.messages.contains {
            $0 == "Provider resolved model alias mlx-fast to active model mlx-community/Tiny"
        })
    }

    func testProviderInjectsSelectedModelMetadataWhenDebugCaptureIsEnabled() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" },
            debugRecorder: ProviderDebugRecorder(fileURL: debugFile, isEnabled: { true })
        )
        let body = Data(#"{"model":"mlx-fast","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)

        let chat = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )

        XCTAssertEqual(chat.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let json = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        let messages = try XCTUnwrap(json?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        let systemText = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(systemText.contains("Provider selected model alias: mlx-fast."))
        XCTAssertTrue(systemText.contains("Provider inferred role: coding."))
        XCTAssertTrue(systemText.contains("Actual upstream MLX model: mlx-community/Tiny."))
        XCTAssertEqual(messages.last?["role"] as? String, "user")
        XCTAssertEqual(messages.last?["content"] as? String, "hi")
    }

    func testProviderDoesNotInjectSelectedModelMetadataWhenDebugCaptureIsDisabled() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" },
            debugRecorder: ProviderDebugRecorder(fileURL: debugFile, isEnabled: { false })
        )
        let body = Data(#"{"model":"mlx-fast","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)

        let chat = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )

        XCTAssertEqual(chat.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let json = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        let messages = try XCTUnwrap(json?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "hi")
    }

    func testProviderRoutingDecisionMapsAliasesToRolesAndDesiredModels() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
        let router = ProviderRouter(
            upstream: FakeUpstream(),
            activeModelProvider: { "mlx-community/Ask" },
            roleAssignmentsProvider: {
                ProviderRoleAssignments(
                    ask: "mlx-community/Ask",
                    plan: "mlx-community/Plan",
                    coding: "mlx-community/Coder"
                )
            },
            debugRecorder: ProviderDebugRecorder(fileURL: debugFile, isEnabled: { true })
        )

        _ = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: [:],
                body: Data(#"{"model":"mlx-ask","messages":[{"role":"user","content":"hi"}],"stream":false,"tools":[{"type":"function","function":{"name":"read_file"}}]}"#.utf8)
            )
        )

        let record = try lastDebugRecord(in: debugFile)
        let decision = try XCTUnwrap(record["routing_decision"] as? [String: Any])
        XCTAssertEqual(decision["requested_model"] as? String, "mlx-ask")
        XCTAssertEqual(decision["selected_alias"] as? String, "mlx-ask")
        XCTAssertEqual(decision["inferred_role"] as? String, "ask")
        XCTAssertEqual(decision["client_capability"] as? String, "read_only")
        XCTAssertEqual(decision["desired_role_model"] as? String, "mlx-community/Ask")
        XCTAssertEqual(decision["upstream_model"] as? String, "mlx-community/Ask")
        XCTAssertNil(decision["fallback_reason"])
    }

    func testProviderRoutingDecisionFallsBackWhenAssignedRoleModelIsNotLoaded() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
        let upstream = FakeUpstream()
        let logger = CapturingProviderLogger()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Loaded" },
            roleAssignmentsProvider: {
                ProviderRoleAssignments(coding: "mlx-community/Coder")
            },
            eventLogger: logger.log,
            debugRecorder: ProviderDebugRecorder(fileURL: debugFile, isEnabled: { true })
        )

        _ = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: [:],
                body: Data(#"{"model":"mlx-fast","messages":[{"role":"user","content":"hi"}],"stream":false,"tools":[{"type":"function","function":{"name":"write_file"}},{"type":"function","function":{"name":"gradle_build"}}]}"#.utf8)
            )
        )

        let proxied = try XCTUnwrap(upstream.requests.last)
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(proxiedJSON?["model"] as? String, "mlx-community/Loaded")
        let record = try lastDebugRecord(in: debugFile)
        let decision = try XCTUnwrap(record["routing_decision"] as? [String: Any])
        XCTAssertEqual(decision["inferred_role"] as? String, "coding")
        XCTAssertEqual(decision["client_capability"] as? String, "edit_build")
        XCTAssertEqual(decision["desired_role_model"] as? String, "mlx-community/Coder")
        XCTAssertEqual(decision["upstream_model"] as? String, "mlx-community/Loaded")
        XCTAssertEqual(decision["fallback_reason"] as? String, "role server unavailable; using active model")
        XCTAssertTrue(logger.messages.contains {
            $0 == "Provider routing fallback for mlx-fast: role server unavailable; using active model"
        })
    }

    func testProviderRoutingDecisionPlanningPromptOverridesFastAliasRole() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
        let router = ProviderRouter(
            upstream: FakeUpstream(),
            activeModelProvider: { "mlx-community/Loaded" },
            roleAssignmentsProvider: {
                ProviderRoleAssignments(plan: "mlx-community/Plan", coding: "mlx-community/Coder")
            },
            debugRecorder: ProviderDebugRecorder(fileURL: debugFile, isEnabled: { true })
        )

        _ = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: [:],
                body: Data(#"{"model":"mlx-fast","messages":[{"role":"developer","content":"You are in PLANNING mode. Think first."},{"role":"user","content":"hi"}],"stream":false,"tools":[{"type":"function","function":{"name":"write_file"}}]}"#.utf8)
            )
        )

        let record = try lastDebugRecord(in: debugFile)
        let decision = try XCTUnwrap(record["routing_decision"] as? [String: Any])
        XCTAssertEqual(decision["selected_alias"] as? String, "mlx-fast")
        XCTAssertEqual(decision["inferred_role"] as? String, "plan")
        XCTAssertEqual(decision["desired_role_model"] as? String, "mlx-community/Plan")
        XCTAssertEqual(decision["upstream_model"] as? String, "mlx-community/Loaded")
    }

    func testRoleAliasRoutesToAssignedUpstreamEndpoint() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Gemma" },
            roleAssignmentsProvider: {
                ProviderRoleAssignments(plan: "mlx-community/Devstral")
            },
            defaultEndpointProvider: {
                ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Gemma",
                    baseURL: URL(string: "http://127.0.0.1:8080")!,
                    port: 8080
                )
            },
            roleEndpointProvider: { role in
                guard role == .plan else { return nil }
                return ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Devstral",
                    baseURL: URL(string: "http://127.0.0.1:8081")!,
                    port: 8081
                )
            }
        )

        let response = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: [:],
                body: Data(#"{"model":"mlx-plan","messages":[{"role":"user","content":"plan this change"}],"stream":false}"#.utf8)
            )
        )

        XCTAssertEqual(response.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let endpoint = try XCTUnwrap(upstream.endpoints.last)
        XCTAssertEqual(endpoint.modelID, "mlx-community/Devstral")
        XCTAssertEqual(endpoint.port, 8081)
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(proxiedJSON?["model"] as? String, "mlx-community/Devstral")
    }

    func testRoleAliasFallsBackToDefaultEndpointWhenRoleEndpointMissing() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
        let upstream = FakeUpstream()
        let logger = CapturingProviderLogger()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Gemma" },
            roleAssignmentsProvider: {
                ProviderRoleAssignments(plan: "mlx-community/Devstral")
            },
            defaultEndpointProvider: {
                ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Gemma",
                    baseURL: URL(string: "http://127.0.0.1:8080")!,
                    port: 8080
                )
            },
            roleEndpointProvider: { _ in nil },
            eventLogger: logger.log,
            debugRecorder: ProviderDebugRecorder(fileURL: debugFile, isEnabled: { true })
        )

        let response = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: [:],
                body: Data(#"{"model":"mlx-plan","messages":[{"role":"user","content":"plan this change"}],"stream":false}"#.utf8)
            )
        )

        XCTAssertEqual(response.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let endpoint = try XCTUnwrap(upstream.endpoints.last)
        XCTAssertEqual(endpoint.modelID, "mlx-community/Gemma")
        XCTAssertEqual(endpoint.port, 8080)
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(proxiedJSON?["model"] as? String, "mlx-community/Gemma")

        let record = try lastDebugRecord(in: debugFile)
        let decision = try XCTUnwrap(record["routing_decision"] as? [String: Any])
        XCTAssertEqual(decision["fallback_reason"] as? String, "role server unavailable; using active model")
        XCTAssertTrue(logger.messages.contains { $0.contains("role server unavailable; using active model") })
    }

    func testEndpointAwareRouterReturnsUnavailableWhenDefaultEndpointMissing() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Gemma" },
            roleAssignmentsProvider: { ProviderRoleAssignments(plan: "mlx-community/Devstral") },
            defaultEndpointProvider: { nil },
            roleEndpointProvider: { _ in nil }
        )

        let response = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: [:],
                body: Data(#"{"model":"mlx-plan","messages":[{"role":"user","content":"plan"}],"stream":false}"#.utf8)
            )
        )

        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(upstream.requests.count, 0)
        XCTAssertEqual(upstream.endpoints.count, 0)
    }

    func testEndpointAwareRouterRecordsUnavailableRoutingWithoutInventedEndpoint() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Gemma" },
            roleAssignmentsProvider: { ProviderRoleAssignments(plan: "mlx-community/Devstral") },
            defaultEndpointProvider: { nil },
            roleEndpointProvider: { _ in nil },
            debugRecorder: ProviderDebugRecorder(fileURL: debugFile, isEnabled: { true })
        )

        let response = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: [:],
                body: Data(#"{"model":"mlx-plan","messages":[{"role":"user","content":"plan"}],"stream":false}"#.utf8)
            )
        )

        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(upstream.requests.count, 0)
        XCTAssertEqual(upstream.endpoints.count, 0)

        let record = try lastDebugRecord(in: debugFile)
        let decision = try XCTUnwrap(record["routing_decision"] as? [String: Any])
        XCTAssertEqual(decision["selected_alias"] as? String, "mlx-plan")
        XCTAssertEqual(decision["inferred_role"] as? String, "plan")
        XCTAssertEqual(decision["desired_role_model"] as? String, "mlx-community/Devstral")
        XCTAssertEqual(decision["fallback_reason"] as? String, "no upstream endpoint available")
        XCTAssertNil(decision["upstream_base_url"])
        XCTAssertNil(decision["upstream_port"])
    }

    func testLegacyRouterDoesNotReportSyntheticEndpointMetadata() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Loaded" },
            roleAssignmentsProvider: { ProviderRoleAssignments(plan: "mlx-community/Plan") },
            debugRecorder: ProviderDebugRecorder(fileURL: debugFile, isEnabled: { true })
        )

        _ = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: [:],
                body: Data(#"{"model":"mlx-plan","messages":[{"role":"user","content":"plan"}],"stream":false}"#.utf8)
            )
        )

        XCTAssertEqual(upstream.requests.count, 1)
        let record = try lastDebugRecord(in: debugFile)
        let decision = try XCTUnwrap(record["routing_decision"] as? [String: Any])
        XCTAssertEqual(decision["upstream_model"] as? String, "mlx-community/Loaded")
        XCTAssertNil(decision["upstream_base_url"])
        XCTAssertNil(decision["upstream_port"])
    }

    func testRoutingDebugPayloadIncludesUpstreamEndpointFields() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
        let router = ProviderRouter(
            upstream: FakeUpstream(),
            activeModelProvider: { "mlx-community/Gemma" },
            roleAssignmentsProvider: {
                ProviderRoleAssignments(plan: "mlx-community/Devstral")
            },
            defaultEndpointProvider: {
                ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Gemma",
                    baseURL: URL(string: "http://127.0.0.1:8080")!,
                    port: 8080
                )
            },
            roleEndpointProvider: { _ in nil },
            debugRecorder: ProviderDebugRecorder(fileURL: debugFile, isEnabled: { true })
        )

        _ = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: [:],
                body: Data(#"{"model":"mlx-plan","messages":[{"role":"user","content":"plan this change"}],"stream":false}"#.utf8)
            )
        )

        let record = try lastDebugRecord(in: debugFile)
        let decision = try XCTUnwrap(record["routing_decision"] as? [String: Any])
        XCTAssertEqual(decision["selected_alias"] as? String, "mlx-plan")
        XCTAssertEqual(decision["inferred_role"] as? String, "plan")
        XCTAssertEqual(decision["desired_role_model"] as? String, "mlx-community/Devstral")
        XCTAssertEqual(decision["upstream_model"] as? String, "mlx-community/Gemma")
        XCTAssertEqual(decision["upstream_base_url"] as? String, "http://127.0.0.1:8080")
        XCTAssertEqual(decision["upstream_port"] as? Int, 8080)
        XCTAssertEqual(decision["fallback_reason"] as? String, "role server unavailable; using active model")
    }

    func testProviderDebugMetadataIncludesRoutingDecisionWhenCaptureIsEnabled() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Loaded" },
            roleAssignmentsProvider: {
                ProviderRoleAssignments(coding: "mlx-community/Coder")
            },
            debugRecorder: ProviderDebugRecorder(fileURL: debugFile, isEnabled: { true })
        )

        _ = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: [:],
                body: Data(#"{"model":"mlx-fast","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)
            )
        )

        let proxied = try XCTUnwrap(upstream.requests.last)
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        let messages = try XCTUnwrap(proxiedJSON?["messages"] as? [[String: Any]])
        let systemText = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(systemText.contains("Provider selected model alias: mlx-fast."))
        XCTAssertTrue(systemText.contains("Provider inferred role: coding."))
        XCTAssertTrue(systemText.contains("Desired role model: mlx-community/Coder."))
        XCTAssertTrue(systemText.contains("Actual upstream MLX model: mlx-community/Loaded."))
        XCTAssertTrue(systemText.contains("Fallback reason: role server unavailable; using active model."))
    }

    func testProviderDebugRecorderWritesFullLocalPayloadWithRedactedHeaders() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" },
            debugRecorder: ProviderDebugRecorder(fileURL: debugFile, isEnabled: { true })
        )
        let body = Data(#"{"model":"mlx-fast","messages":[{"role":"user","content":"secret prompt"}],"stream":false}"#.utf8)

        let response = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: ["authorization": "Bearer secret-token", "content-type": "application/json"],
                body: body
            )
        )

        XCTAssertEqual(response.status, 200)
        let line = try XCTUnwrap(String(contentsOf: debugFile, encoding: .utf8).split(separator: "\n").last)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(record["method"] as? String, "POST")
        XCTAssertEqual(record["path"] as? String, "/v1/chat/completions")
        XCTAssertEqual(record["selected_model"] as? String, "mlx-fast")
        XCTAssertEqual(record["response_status"] as? Int, 200)
        XCTAssertEqual(record["alias_resolution"] as? String, "mlx-fast -> mlx-community/Tiny")
        XCTAssertTrue((record["request_body_text"] as? String)?.contains("secret prompt") == true)
        XCTAssertTrue((record["response_body_text"] as? String)?.contains("Hello from chat.") == true)
        XCTAssertEqual(record["top_level_keys"] as? [String], ["messages", "model", "stream"])
        let headers = try XCTUnwrap(record["headers"] as? [String: String])
        XCTAssertEqual(headers["authorization"], "<redacted>")
        XCTAssertEqual(headers["content-type"], "application/json")
        XCTAssertFalse(String(line).contains("secret-token"))
    }

    func testProviderDebugRecorderSkipsPayloadWhenDisabled() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
        let router = ProviderRouter(
            upstream: FakeUpstream(),
            activeModelProvider: { "mlx-community/Tiny" },
            debugRecorder: ProviderDebugRecorder(fileURL: debugFile, isEnabled: { false })
        )

        _ = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: [:],
                body: Data(#"{"model":"mlx-fast","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: debugFile.path))
    }

    func testProviderLogsUpstreamErrorStatusForProxiedRequests() async throws {
        let upstream = FakeUpstream(notFoundBody: Data(#"{"detail":"missing route"}"#.utf8))
        let logger = CapturingProviderLogger()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" },
            eventLogger: logger.log
        )
        let body = Data(
            #"{"messages":[{"role":"user","content":"secret prompt"}],"metadata":{"source":"android-studio"},"parallel_tool_calls":true,"stream":true,"tool_choice":"auto","tools":[]}"#.utf8
        )

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/completions", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 404)
        XCTAssertTrue(logger.messages.contains {
            $0 == "Provider streaming POST /v1/completions from upstream with status 404"
        })
        XCTAssertTrue(logger.messages.contains {
            $0 == #"Provider upstream error body for POST /v1/completions status 404: {"detail":"missing route"}"#
        })
        XCTAssertTrue(logger.messages.contains {
            $0 == "Provider upstream request summary for POST /v1/completions: keys=[messages,metadata,model,stream], model=mlx-community/Tiny, stream=true, message_count=2"
        })
        XCTAssertFalse(logger.messages.contains { $0.contains("secret prompt") })
    }

    func testProviderNormalizesStructuredChatMessagesForMLXUpstream() async throws {
        let upstream = FakeUpstream()
        let logger = CapturingProviderLogger()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" },
            eventLogger: logger.log
        )
        let body = Data(
            #"{"messages":[{"role":"developer","content":"Be concise."},{"role":"user","content":[{"type":"input_text","text":"hi"}]}],"stream":false}"#.utf8
        )

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        let messages = try XCTUnwrap(proxiedJSON?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "Be concise.")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "hi")
        XCTAssertTrue(logger.messages.contains {
            $0 == "Provider normalized POST /v1/chat/completions messages for MLX upstream compatibility"
        })
    }

    func testProviderNormalizesAgentHistoryToAlternatingMLXMessages() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
        )
        let body = Data(
            #"{"messages":[{"role":"developer","content":"Be concise."},{"role":"system","content":"Use local tools when helpful."},{"role":"user","content":"hi"},{"role":"user","content":[{"type":"text","text":"extra context"}]},{"role":"assistant","content":"thinking"},{"role":"assistant","content":"answer draft"},{"role":"tool","content":"tool result"},{"role":"user","content":"final question"}],"stream":true,"tools":[{"type":"function","function":{"name":"read_file"}}],"tool_choice":"auto"}"#.utf8
        )

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        let messages = try XCTUnwrap(proxiedJSON?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(
            messages[0]["content"] as? String,
            "Tool calls are not available through this local MLX provider. Answer in text instead of calling tools.\n\nBe concise.\n\nUse local tools when helpful."
        )
        XCTAssertEqual(messages[1]["content"] as? String, "hi\n\nextra context")
        XCTAssertEqual(messages[2]["content"] as? String, "thinking\n\nanswer draft")
        XCTAssertEqual(messages[3]["content"] as? String, "tool result\n\nfinal question")
    }

    func testProviderRemovesToolFieldsForTextOnlyMLXUpstream() async throws {
        let upstream = FakeUpstream()
        let logger = CapturingProviderLogger()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" },
            eventLogger: logger.log
        )
        let body = Data(
            #"{"messages":[{"role":"user","content":"list files"}],"parallel_tool_calls":true,"stream":true,"stream_options":{"include_usage":true},"tool_choice":"auto","tools":[{"type":"function","function":{"name":"list_files"}}]}"#.utf8
        )

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertNil(proxiedJSON?["tools"])
        XCTAssertNil(proxiedJSON?["tool_choice"])
        XCTAssertNil(proxiedJSON?["parallel_tool_calls"])
        XCTAssertNil(proxiedJSON?["stream_options"])
        let messages = try XCTUnwrap(proxiedJSON?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.first?["content"] as? String, "Tool calls are not available through this local MLX provider. Answer in text instead of calling tools.")
        XCTAssertTrue(logger.messages.contains {
            $0 == "Provider removed tool-calling fields for MLX upstream compatibility"
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
        let stream = try XCTUnwrap(String(data: chat.body, encoding: .utf8))
        XCTAssertTrue(stream.contains(#""content":"Hel""#))
        XCTAssertTrue(stream.contains("data: [DONE]"))
        XCTAssertEqual(upstream.requests.map(\.path), ["/v1/chat/completions"])
    }

    func testProviderTranslatesSimpleResponsesRequestToChatCompletion() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
        )
        let body = Data(#"{"model":"ignored-by-dashboard","input":"hi","temperature":0.2,"max_output_tokens":32}"#.utf8)

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/responses", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        XCTAssertEqual(proxied.path, "/v1/chat/completions")
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(proxiedJSON?["model"] as? String, "mlx-community/Tiny")
        XCTAssertEqual(proxiedJSON?["temperature"] as? Double, 0.2)
        XCTAssertEqual(proxiedJSON?["max_tokens"] as? Int, 32)
        let messages = try XCTUnwrap(proxiedJSON?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "hi")

        let responseJSON = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertEqual(responseJSON?["object"] as? String, "response")
        XCTAssertEqual(responseJSON?["status"] as? String, "completed")
        XCTAssertEqual(responseJSON?["model"] as? String, "mlx-community/Tiny")
        XCTAssertEqual(try outputText(in: response.body), "Hello from chat.")
    }

    func testResponsesRouteToAssignedRoleEndpoint() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Gemma" },
            roleAssignmentsProvider: { ProviderRoleAssignments(plan: "mlx-community/Devstral") },
            defaultEndpointProvider: {
                ProviderUpstreamEndpoint(modelID: "mlx-community/Gemma", baseURL: URL(string: "http://127.0.0.1:8080")!, port: 8080)
            },
            roleEndpointProvider: { role in
                role == .plan
                ? ProviderUpstreamEndpoint(modelID: "mlx-community/Devstral", baseURL: URL(string: "http://127.0.0.1:8081")!, port: 8081)
                : nil
            }
        )
        let body = Data(#"{"model":"mlx-plan","input":"plan","temperature":0.2,"max_output_tokens":32}"#.utf8)

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/responses", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 200)
        let endpoint = try XCTUnwrap(upstream.endpoints.last)
        XCTAssertEqual(endpoint.modelID, "mlx-community/Devstral")
        XCTAssertEqual(endpoint.port, 8081)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(proxiedJSON?["model"] as? String, "mlx-community/Devstral")
        let responseJSON = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertEqual(responseJSON?["model"] as? String, "mlx-community/Devstral")
    }

    func testProviderTranslatesResponsesInputMessagesToChatCompletion() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
        )
        let body = Data(
            #"{"instructions":"Be brief.","input":[{"role":"user","content":[{"type":"input_text","text":"hi"}]}]}"#.utf8
        )

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/responses", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        XCTAssertEqual(proxied.path, "/v1/chat/completions")
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        let messages = try XCTUnwrap(proxiedJSON?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "Be brief.")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "hi")
        XCTAssertEqual(try outputText(in: response.body), "Hello from chat.")
    }

    func testProviderTranslatesStreamingResponsesToResponsesEvents() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
        )
        let body = Data(#"{"input":"hi","stream":true}"#.utf8)

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/responses", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-type"], "text/event-stream")
        let stream = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        XCTAssertTrue(stream.contains("event: response.output_text.delta"))
        XCTAssertTrue(stream.contains(#""delta":"Hel""#))
        XCTAssertTrue(stream.contains(#""delta":"lo""#))
        XCTAssertTrue(stream.contains("event: response.completed"))
        XCTAssertTrue(stream.contains(#""text":"Hello""#))
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
        let apiPrefixedModels = try await router.handle(
            ProviderRequest(method: "GET", path: "/api/v1/models", headers: [:], body: Data())
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
        XCTAssertEqual(try modelIDs(in: duplicatedVersionModels.body), expectedModels(active: "mlx-community/Tiny"))
        XCTAssertEqual(apiPrefixedModels.status, 200)
        XCTAssertEqual(try modelIDs(in: apiPrefixedModels.body), expectedModels(active: "mlx-community/Tiny"))
        XCTAssertEqual(unversionedChat.status, 200)
        XCTAssertEqual(duplicatedVersionChat.status, 200)
        XCTAssertEqual(upstream.requests.map(\.path), ["/v1/chat/completions", "/v1/chat/completions"])
    }

    func testProviderNormalizesTrailingSlashPathVariants() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
        )

        let responses = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/responses/",
                headers: [:],
                body: Data(#"{"input":"hi"}"#.utf8)
            )
        )
        let chat = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions/",
                headers: [:],
                body: Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8)
            )
        )

        XCTAssertEqual(responses.status, 200)
        XCTAssertEqual(chat.status, 200)
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
        XCTAssertEqual(try modelIDs(in: modelsData), expectedModels(active: "mlx-community/Tiny"))

        var responsesRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        responsesRequest.httpMethod = "POST"
        responsesRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        responsesRequest.httpBody = Data(#"{"input":"hi"}"#.utf8)
        let (responsesData, responsesResponse) = try await URLSession.shared.data(for: responsesRequest)
        XCTAssertEqual((responsesResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try outputText(in: responsesData), "Hello from chat.")
    }

    func testNIOProviderServerStreamsChatChunksAsTheyArrive() async throws {
        let upstream = DelayedStreamingUpstream()
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

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(#"{"messages":[{"role":"user","content":"hi"}],"stream":true}"#.utf8)

        let start = Date()
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        var iterator = bytes.lines.makeAsyncIterator()
        let firstLine = try await iterator.next()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(firstLine, #"data: {"choices":[{"delta":{"content":"Hel"},"finish_reason":null}]}"#)
        XCTAssertLessThan(elapsed, 0.8)
    }

    private func modelIDs(in data: Data) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = object?["data"] as? [[String: Any]]
        return models?.compactMap { $0["id"] as? String } ?? []
    }

    private func expectedModels(active: String) -> [String] {
        ["mlx-ask", "mlx-plan", "mlx-fast", active]
    }

    private func outputText(in data: Data) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let output = object?["output"] as? [[String: Any]]
        let message = output?.first
        let content = message?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String
    }

    private func lastDebugRecord(in fileURL: URL) throws -> [String: Any] {
        let line = try XCTUnwrap(String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n").last)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MLXProviderServerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

private final class FakeUpstream: ProviderUpstreamClient, ProviderUpstreamProxyClient, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [ProviderRequest] = []
    private var storedEndpoints: [ProviderUpstreamEndpoint] = []
    private let notFoundBody: Data

    init(notFoundBody: Data = Data()) {
        self.notFoundBody = notFoundBody
    }

    var requests: [ProviderRequest] {
        lock.withLock { storedRequests }
    }

    var endpoints: [ProviderUpstreamEndpoint] {
        lock.withLock { storedEndpoints }
    }

    func proxy(_ request: ProviderRequest) async throws -> ProviderResponse {
        lock.withLock {
            storedRequests.append(request)
        }
        return try await proxyResponse(for: request)
    }

    func proxy(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint) async throws -> ProviderResponse {
        lock.withLock {
            storedRequests.append(request)
            storedEndpoints.append(endpoint)
        }
        return try await proxyResponse(for: request)
    }

    func proxyStream(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint) async throws -> ProviderStreamedResponse {
        let response = try await proxy(request, to: endpoint)
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            if !response.body.isEmpty {
                continuation.yield(response.body)
            }
            continuation.finish()
        }
        return ProviderStreamedResponse(status: response.status, headers: response.headers, chunks: chunks)
    }

    private func proxyResponse(for request: ProviderRequest) async throws -> ProviderResponse {
        switch request.path {
        case "/v1/models":
            return ProviderResponse(status: 200, headers: ["content-type": "application/json"], body: Data(#"{"object":"list","data":[]}"#.utf8))
        case "/v1/chat/completions":
            if let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
               object["stream"] as? Bool == false || object["stream"] == nil {
                return ProviderResponse(
                    status: 200,
                    headers: ["content-type": "application/json"],
                    body: Data(
                        #"{"id":"chatcmpl-test","object":"chat.completion","created":1,"model":"mlx-community/Tiny","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"Hello from chat."}}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}"#.utf8
                    )
                )
            }
            let stream = """
            data: {"choices":[{"delta":{"content":"Hel"},"finish_reason":null}]}

            data: {"choices":[{"delta":{"content":"lo"},"finish_reason":null}]}

            data: [DONE]

            """
            return ProviderResponse(status: 200, headers: ["content-type": "text/event-stream"], body: Data(stream.utf8))
        default:
            return ProviderResponse(status: 404, headers: [:], body: notFoundBody)
        }
    }
}

private final class DelayedStreamingUpstream: ProviderUpstreamClient, @unchecked Sendable {
    func proxy(_ request: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(status: 500, headers: [:], body: Data())
    }

    func proxyStream(_ request: ProviderRequest) async throws -> ProviderStreamedResponse {
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            Task {
                continuation.yield(Data(#"data: {"choices":[{"delta":{"content":"Hel"},"finish_reason":null}]}"#.utf8))
                continuation.yield(Data("\n\n".utf8))
                try await Task.sleep(nanoseconds: 1_500_000_000)
                continuation.yield(Data(#"data: {"choices":[{"delta":{"content":"lo"},"finish_reason":null}]}"#.utf8))
                continuation.yield(Data("\n\n".utf8))
                continuation.yield(Data("data: [DONE]\n\n".utf8))
                continuation.finish()
            }
        }
        return ProviderStreamedResponse(status: 200, headers: ["content-type": "text/event-stream"], chunks: chunks)
    }
}
