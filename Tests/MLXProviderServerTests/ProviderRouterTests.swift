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

        XCTAssertEqual(try modelIDs(in: models.body), ["mlx-ask", "mlx-plan", "mlx-coding", "mlx-community/Tiny"])
        XCTAssertEqual(try modelIDs(in: v0Models.body), ["mlx-ask", "mlx-plan", "mlx-coding", "mlx-community/Tiny"])

        let tagsJSON = try JSONSerialization.jsonObject(with: tags.body) as? [String: Any]
        let tagModels = try XCTUnwrap(tagsJSON?["models"] as? [[String: Any]])
        XCTAssertEqual(tagModels.compactMap { $0["name"] as? String }, ["mlx-ask", "mlx-plan", "mlx-coding", "mlx-community/Tiny"])
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderServesAliasMetadataByIDAndShow() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
        )

        let metadata = try await router.handle(
            ProviderRequest(method: "GET", path: "/api/v0/models/mlx-coding", headers: [:], body: Data())
        )
        let show = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/api/show",
                headers: [:],
                body: Data(#"{"model":"mlx-coding"}"#.utf8)
            )
        )

        XCTAssertEqual(metadata.status, 200)
        let metadataJSON = try JSONSerialization.jsonObject(with: metadata.body) as? [String: Any]
        XCTAssertEqual(metadataJSON?["id"] as? String, "mlx-coding")
        XCTAssertEqual(metadataJSON?["compatibility_type"] as? String, "mlx")

        XCTAssertEqual(show.status, 200)
        let showJSON = try JSONSerialization.jsonObject(with: show.body) as? [String: Any]
        XCTAssertEqual(showJSON?["model"] as? String, "mlx-coding")
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderAliasMetadataIncludesActiveModelFallbackRoutingState() async throws {
        let router = ProviderRouter(
            upstream: FakeUpstream(),
            activeModelProvider: { "mlx-community/Gemma" },
            roleAssignmentsProvider: {
                ProviderRoleAssignments(coding: "mlx-community/Coder")
            },
            defaultEndpointProvider: {
                ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Gemma",
                    baseURL: URL(string: "http://127.0.0.1:8080")!,
                    port: 8080
                )
            },
            roleEndpointProvider: { _ in nil }
        )

        let metadata = try await router.handle(
            ProviderRequest(method: "GET", path: "/provider/v1/models/mlx-coding", headers: [:], body: Data())
        )

        XCTAssertEqual(metadata.status, 200)
        let metadataJSON = try JSONSerialization.jsonObject(with: metadata.body) as? [String: Any]
        XCTAssertEqual(metadataJSON?["id"] as? String, "mlx-coding")
        XCTAssertEqual(metadataJSON?["role"] as? String, "coding")
        XCTAssertEqual(metadataJSON?["resolved_model"] as? String, "mlx-community/Coder")
        XCTAssertEqual(metadataJSON?["effective_model"] as? String, "mlx-community/Gemma")
        XCTAssertEqual(metadataJSON?["routing_state"] as? String, "active_model_fallback")
        XCTAssertEqual(metadataJSON?["effective_port"] as? Int, 8080)
        XCTAssertEqual(metadataJSON?["fallback_reason"] as? String, "role server unavailable; using active model")
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
        XCTAssertEqual(model["generation_type"] as? String, "text")
        XCTAssertEqual(model["model_family"] as? String, "chat")
        XCTAssertEqual(model["state"] as? String, "loaded")
        XCTAssertEqual(model["max_context_length"] as? Int, 32768)
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderServesCanonicalProviderModelMetadataRoutes() async throws {
        let upstream = FakeUpstream()
        let logger = CapturingProviderLogger()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit" },
            eventLogger: logger.log
        )

        let models = try await router.handle(
            ProviderRequest(method: "GET", path: "/provider/v1/models", headers: [:], body: Data())
        )
        let model = try await router.handle(
            ProviderRequest(
                method: "GET",
                path: "/provider/v1/models/mlx-community%2FDevstral-Small-2-24B-Instruct-2512-4bit",
                headers: [:],
                body: Data()
            )
        )

        XCTAssertEqual(models.status, 200)
        let modelsJSON = try JSONSerialization.jsonObject(with: models.body) as? [String: Any]
        let data = try XCTUnwrap(modelsJSON?["data"] as? [[String: Any]])
        XCTAssertEqual(data.compactMap { $0["id"] as? String }, expectedModels(active: "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit"))

        XCTAssertEqual(model.status, 200)
        let modelJSON = try JSONSerialization.jsonObject(with: model.body) as? [String: Any]
        XCTAssertEqual(modelJSON?["id"] as? String, "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit")
        XCTAssertEqual(modelJSON?["generation_type"] as? String, "text")
        XCTAssertEqual(modelJSON?["model_family"] as? String, "chat")
        XCTAssertEqual(modelJSON?["state"] as? String, "loaded")
        XCTAssertTrue(logger.messages.contains("Provider served GET /provider/v1/models"))
        XCTAssertTrue(logger.messages.contains("Provider served GET /provider/v1/models/mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit"))
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderMetadataForAliasesFollowsAssignedRoleModels() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit" },
            modelMetadataProvider: {
                [
                    "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit": .inferred(
                        modelID: "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit",
                        modelType: "mistral3"
                    ),
                    "mlx-community/Nemotron-Labs-Diffusion-3B-4bit": .inferred(
                        modelID: "mlx-community/Nemotron-Labs-Diffusion-3B-4bit",
                        modelType: "nemotron_labs_diffusion"
                    )
                ]
            },
            roleAssignmentsProvider: {
                ProviderRoleAssignments(
                    ask: "mlx-community/Nemotron-Labs-Diffusion-3B-4bit",
                    plan: "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit",
                    coding: "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit"
                )
            }
        )

        let response = try await router.handle(
            ProviderRequest(method: "GET", path: "/provider/v1/models", headers: [:], body: Data())
        )

        XCTAssertEqual(response.status, 200)
        let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let data = try XCTUnwrap(json?["data"] as? [[String: Any]])
        let ask = try XCTUnwrap(data.first { $0["id"] as? String == "mlx-ask" })
        let plan = try XCTUnwrap(data.first { $0["id"] as? String == "mlx-plan" })
        let coding = try XCTUnwrap(data.first { $0["id"] as? String == "mlx-coding" })
        XCTAssertEqual(ask["generation_type"] as? String, "text")
        XCTAssertEqual(ask["model_family"] as? String, "diffusion_text")
        XCTAssertEqual(ask["state"] as? String, "loaded")
        XCTAssertEqual(plan["model_family"] as? String, "chat")
        XCTAssertEqual(coding["model_family"] as? String, "chat")
        XCTAssertEqual(upstream.requests, [])
    }

    func testOpenAIModelsExposeAliasMetadataFromAssignedRoleModels() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/gpt-oss-20b-MXFP4-Q8" },
            modelMetadataProvider: {
                [
                    "mlx-community/gpt-oss-20b-MXFP4-Q8": .inferred(modelID: "mlx-community/gpt-oss-20b-MXFP4-Q8"),
                    "mlx-community/Qwen3.6-35B-A3B-4bit": .inferred(modelID: "mlx-community/Qwen3.6-35B-A3B-4bit"),
                    "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit": .inferred(modelID: "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit")
                ]
            },
            roleAssignmentsProvider: {
                ProviderRoleAssignments(
                    ask: "mlx-community/gpt-oss-20b-MXFP4-Q8",
                    plan: "mlx-community/Qwen3.6-35B-A3B-4bit",
                    coding: "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit"
                )
            }
        )

        let response = try await router.handle(
            ProviderRequest(method: "GET", path: "/v1/models", headers: [:], body: Data())
        )
        let askResponse = try await router.handle(
            ProviderRequest(method: "GET", path: "/v1/models/mlx-ask", headers: [:], body: Data())
        )

        XCTAssertEqual(response.status, 200)
        let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let data = try XCTUnwrap(json?["data"] as? [[String: Any]])
        let ask = try XCTUnwrap(data.first { $0["id"] as? String == "mlx-ask" })
        let plan = try XCTUnwrap(data.first { $0["id"] as? String == "mlx-plan" })
        let coding = try XCTUnwrap(data.first { $0["id"] as? String == "mlx-coding" })
        XCTAssertEqual(ask["object"] as? String, "model")
        XCTAssertEqual(ask["owned_by"] as? String, "mlx-community")
        XCTAssertEqual(ask["publisher"] as? String, "mlx-community")
        XCTAssertEqual(ask["arch"] as? String, "gpt-oss")
        XCTAssertEqual(ask["quantization"] as? String, "MXFP4-Q8")
        XCTAssertEqual(ask["resolved_model"] as? String, "mlx-community/gpt-oss-20b-MXFP4-Q8")
        XCTAssertEqual(ask["role"] as? String, "ask")
        XCTAssertEqual(plan["arch"] as? String, "qwen")
        XCTAssertEqual(plan["quantization"] as? String, "4bit")
        XCTAssertEqual(plan["resolved_model"] as? String, "mlx-community/Qwen3.6-35B-A3B-4bit")
        XCTAssertEqual(coding["arch"] as? String, "devstral")
        XCTAssertEqual(coding["resolved_model"] as? String, "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit")

        XCTAssertEqual(askResponse.status, 200)
        let askDetail = try JSONSerialization.jsonObject(with: askResponse.body) as? [String: Any]
        XCTAssertEqual(askDetail?["id"] as? String, "mlx-ask")
        XCTAssertEqual(askDetail?["resolved_model"] as? String, "mlx-community/gpt-oss-20b-MXFP4-Q8")
        XCTAssertEqual(askDetail?["arch"] as? String, "gpt-oss")
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderServesTextDiffusionMetadataWhenRunnable() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Diffusion-Gemma" },
            modelMetadataProvider: {
                [
                    "mlx-community/Diffusion-Gemma": ProviderModelMetadata(modelFamily: .diffusionText)
                ]
            }
        )

        let response = try await router.handle(
            ProviderRequest(method: "GET", path: "/api/v0/models/mlx-community%2FDiffusion-Gemma", headers: [:], body: Data())
        )

        XCTAssertEqual(response.status, 200)
        let model = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertEqual(model?["id"] as? String, "mlx-community/Diffusion-Gemma")
        XCTAssertEqual(model?["generation_type"] as? String, "text")
        XCTAssertEqual(model?["model_family"] as? String, "diffusion_text")
        XCTAssertEqual(model?["state"] as? String, "loaded")
        XCTAssertNil(model?["unsupported_reason"])
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderServesUnsupportedTextDiffusionMetadataFromV0ModelsWithoutChangingV1Models() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" },
            modelMetadataProvider: {
                [
                    "mlx-community/Diffusion-Gemma": ProviderModelMetadata(
                        modelFamily: .diffusionText,
                        state: .unsupported,
                        unsupportedReason: "Unsupported by installed mlx-lm: diffusion_gemma"
                    )
                ]
            }
        )

        let v1Models = try await router.handle(
            ProviderRequest(method: "GET", path: "/v1/models", headers: [:], body: Data())
        )
        let v0Models = try await router.handle(
            ProviderRequest(method: "GET", path: "/api/v0/models", headers: [:], body: Data())
        )

        XCTAssertEqual(try modelIDs(in: v1Models.body), ["mlx-ask", "mlx-plan", "mlx-coding", "mlx-community/Tiny"])

        let json = try JSONSerialization.jsonObject(with: v0Models.body) as? [String: Any]
        let data = try XCTUnwrap(json?["data"] as? [[String: Any]])
        XCTAssertEqual(data.compactMap { $0["id"] as? String }, ["mlx-ask", "mlx-plan", "mlx-coding", "mlx-community/Tiny", "mlx-community/Diffusion-Gemma"])
        let unsupported = try XCTUnwrap(data.first { $0["id"] as? String == "mlx-community/Diffusion-Gemma" })
        XCTAssertEqual(unsupported["generation_type"] as? String, "text")
        XCTAssertEqual(unsupported["model_family"] as? String, "diffusion_text")
        XCTAssertEqual(unsupported["state"] as? String, "unsupported")
        XCTAssertEqual(unsupported["unsupported_reason"] as? String, "Unsupported by installed mlx-lm: diffusion_gemma")
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderV0ModelsExcludesLoadedMetadataOnlyModelsButIncludesUnsupportedModels() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" },
            modelMetadataProvider: {
                [
                    "mlx-community/Other-Installed": ProviderModelMetadata(),
                    "mlx-community/Diffusion-Gemma": ProviderModelMetadata(
                        modelFamily: .diffusionText,
                        state: .unsupported,
                        unsupportedReason: "Unsupported by installed mlx-lm: diffusion_gemma"
                    )
                ]
            }
        )

        let response = try await router.handle(
            ProviderRequest(method: "GET", path: "/api/v0/models", headers: [:], body: Data())
        )

        XCTAssertEqual(response.status, 200)
        let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let data = try XCTUnwrap(json?["data"] as? [[String: Any]])
        XCTAssertEqual(
            data.compactMap { $0["id"] as? String },
            ["mlx-ask", "mlx-plan", "mlx-coding", "mlx-community/Tiny", "mlx-community/Diffusion-Gemma"]
        )
        XCTAssertNil(data.first { $0["id"] as? String == "mlx-community/Other-Installed" })
        let unsupported = try XCTUnwrap(data.first { $0["id"] as? String == "mlx-community/Diffusion-Gemma" })
        XCTAssertEqual(unsupported["state"] as? String, "unsupported")
        XCTAssertEqual(unsupported["unsupported_reason"] as? String, "Unsupported by installed mlx-lm: diffusion_gemma")
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderV1ModelsOnlyAdvertisesLoadedModels() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Missing" },
            modelMetadataProvider: {
                [
                    "mlx-community/Missing": ProviderModelMetadata(
                        state: .notInstalled,
                        unavailableReason: "Model is not installed in the local Hugging Face cache."
                    )
                ]
            }
        )

        let v1Models = try await router.handle(
            ProviderRequest(method: "GET", path: "/v1/models", headers: [:], body: Data())
        )
        let apiV1Models = try await router.handle(
            ProviderRequest(method: "GET", path: "/api/v1/models", headers: [:], body: Data())
        )

        XCTAssertEqual(v1Models.status, 200)
        XCTAssertEqual(try modelIDs(in: v1Models.body), [])
        XCTAssertEqual(apiV1Models.status, 200)
        XCTAssertEqual(try modelIDs(in: apiV1Models.body), [])
        XCTAssertEqual(upstream.requests, [])
    }

    func testProviderV0ModelsMarksActiveAliasesNotInstalledWhenActiveModelIsNotInstalled() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Missing" },
            modelMetadataProvider: {
                [
                    "mlx-community/Missing": ProviderModelMetadata(
                        state: .notInstalled,
                        unavailableReason: "Model is not installed in the local Hugging Face cache."
                    )
                ]
            }
        )

        let response = try await router.handle(
            ProviderRequest(method: "GET", path: "/api/v0/models", headers: [:], body: Data())
        )

        XCTAssertEqual(response.status, 200)
        let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let data = try XCTUnwrap(json?["data"] as? [[String: Any]])
        XCTAssertEqual(data.compactMap { $0["id"] as? String }, ["mlx-ask", "mlx-plan", "mlx-coding", "mlx-community/Missing"])
        for model in data {
            XCTAssertEqual(model["state"] as? String, "not_installed")
            XCTAssertEqual(model["reason"] as? String, "Model is not installed in the local Hugging Face cache.")
        }
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

    func testAndroidCompatibilityChatDebugCaptureUsesSelectedRoleEndpointDecision() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
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
            },
            debugRecorder: ProviderDebugRecorder(fileURL: debugFile, isEnabled: { true })
        )
        let body = Data(#"{"model":"mlx-plan","messages":[{"role":"user","content":"plan"}],"stream":false}"#.utf8)

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/api/chat", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 200)
        let record = try lastDebugRecord(in: debugFile)
        let decision = try XCTUnwrap(record["routing_decision"] as? [String: Any])
        XCTAssertEqual(decision["selected_alias"] as? String, "mlx-plan")
        XCTAssertEqual(decision["inferred_role"] as? String, "plan")
        XCTAssertEqual(decision["upstream_model"] as? String, "mlx-community/Devstral")
        XCTAssertEqual(decision["upstream_base_url"] as? String, "http://127.0.0.1:8081")
        XCTAssertEqual(decision["upstream_port"] as? Int, 8081)
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
        let body = Data(#"{"model":"mlx-coding","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)

        let chat = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )

        XCTAssertEqual(chat.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let json = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "mlx-community/Tiny")
        XCTAssertTrue(logger.messages.contains {
            $0 == "Provider resolved model alias mlx-coding to active model mlx-community/Tiny"
        })
    }

    func testProviderAcceptsLegacyFastAliasForChatCompletion() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
        )
        let body = Data(#"{"model":"mlx-fast","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)

        let chat = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )
        let metadata = try await router.handle(
            ProviderRequest(method: "GET", path: "/api/v0/models/mlx-fast", headers: [:], body: Data())
        )

        XCTAssertEqual(chat.status, 200)
        XCTAssertEqual(metadata.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let json = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "mlx-community/Tiny")
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
        let body = Data(#"{"model":"mlx-coding","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)

        let chat = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )

        XCTAssertEqual(chat.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let json = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        let messages = try XCTUnwrap(json?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        let systemText = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(systemText.contains("Provider selected model alias: mlx-coding."))
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
        let body = Data(#"{"model":"mlx-coding","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)

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
                body: Data(#"{"model":"mlx-coding","messages":[{"role":"user","content":"hi"}],"stream":false,"tools":[{"type":"function","function":{"name":"write_file"}},{"type":"function","function":{"name":"gradle_build"}}]}"#.utf8)
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
            $0 == "Provider routing fallback for mlx-coding: role server unavailable; using active model"
        })
    }

    func testProviderRoutingDecisionPlanningPromptOverridesCodingAliasRole() async throws {
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
                body: Data(#"{"model":"mlx-coding","messages":[{"role":"developer","content":"You are in PLANNING mode. Think first."},{"role":"user","content":"hi"}],"stream":false,"tools":[{"type":"function","function":{"name":"write_file"}}]}"#.utf8)
            )
        )

        let record = try lastDebugRecord(in: debugFile)
        let decision = try XCTUnwrap(record["routing_decision"] as? [String: Any])
        XCTAssertEqual(decision["selected_alias"] as? String, "mlx-coding")
        XCTAssertEqual(decision["inferred_role"] as? String, "plan")
        XCTAssertEqual(decision["desired_role_model"] as? String, "mlx-community/Plan")
        XCTAssertEqual(decision["upstream_model"] as? String, "mlx-community/Loaded")
    }

    func testProviderAppliesRoleGenerationDefaultsToAliasRequests() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Plan" },
            roleAssignmentsProvider: {
                ProviderRoleAssignments(plan: "mlx-community/Plan")
            },
            generationDefaultsProvider: {
                ProviderRoleGenerationDefaults(
                    plan: ProviderGenerationSettings(temperature: 0.2, topP: 0.95, maxTokens: 4096)
                )
            }
        )

        _ = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: [:],
                body: Data(#"{"model":"mlx-plan","messages":[{"role":"user","content":"plan this"}],"stream":false}"#.utf8)
            )
        )

        let proxied = try XCTUnwrap(upstream.requests.last)
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(proxiedJSON?["model"] as? String, "mlx-community/Plan")
        XCTAssertEqual(proxiedJSON?["temperature"] as? Double, 0.2)
        XCTAssertEqual(proxiedJSON?["top_p"] as? Double, 0.95)
        XCTAssertEqual(proxiedJSON?["max_tokens"] as? Int, 4096)
    }

    func testProviderRoleGenerationDefaultsDoNotOverrideClientParameters() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Coder" },
            roleAssignmentsProvider: {
                ProviderRoleAssignments(coding: "mlx-community/Coder")
            },
            generationDefaultsProvider: {
                ProviderRoleGenerationDefaults(
                    coding: ProviderGenerationSettings(temperature: 0.0, topP: 1.0, maxTokens: 2048)
                )
            }
        )

        _ = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: [:],
                body: Data(#"{"model":"mlx-coding","messages":[{"role":"user","content":"code this"}],"stream":false,"temperature":0.7,"max_tokens":128}"#.utf8)
            )
        )

        let proxied = try XCTUnwrap(upstream.requests.last)
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(proxiedJSON?["model"] as? String, "mlx-community/Coder")
        XCTAssertEqual(proxiedJSON?["temperature"] as? Double, 0.7)
        XCTAssertEqual(proxiedJSON?["top_p"] as? Double, 1.0)
        XCTAssertEqual(proxiedJSON?["max_tokens"] as? Int, 128)
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

    func testModeAdviceUsesAskRoleEndpointAndReturnsParsedPlanAdvice() async throws {
        let upstream = FakeUpstream(
            chatCompletionBody: Data(
                #"{"id":"chat","choices":[{"message":{"role":"assistant","content":"{\"mode\":\"plan\",\"confidence\":0.86,\"reason\":\"The prompt asks for implementation planning.\"}"}}]}"#.utf8
            )
        )
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Ask" },
            roleAssignmentsProvider: { ProviderRoleAssignments(ask: "mlx-community/Ask") },
            defaultEndpointProvider: {
                ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Ask",
                    baseURL: URL(string: "http://127.0.0.1:8080")!,
                    port: 8080
                )
            },
            roleEndpointProvider: { role in
                guard role == .ask else { return nil }
                return ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Ask",
                    baseURL: URL(string: "http://127.0.0.1:8080")!,
                    port: 8080
                )
            }
        )

        let response = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/provider/v1/mode-advice",
                headers: [:],
                body: Data(#"{"input":"plan how to create a python script","selected_model":"mlx-ask"}"#.utf8)
            )
        )

        XCTAssertEqual(response.status, 200)
        let advice = try jsonObject(in: response.body)
        XCTAssertEqual(advice["suggested_mode"] as? String, "plan")
        XCTAssertEqual(advice["current_mode"] as? String, "ask")
        XCTAssertEqual(advice["confidence"] as? Double, 0.86)
        XCTAssertEqual(advice["should_suggest_switch"] as? Bool, true)
        XCTAssertEqual(advice["reason"] as? String, "The prompt asks for implementation planning.")
        let endpoint = try XCTUnwrap(upstream.endpoints.last)
        XCTAssertEqual(endpoint.modelID, "mlx-community/Ask")
        let classifierRequest = try XCTUnwrap(upstream.requests.last)
        let classifierJSON = try jsonObject(in: classifierRequest.body)
        XCTAssertEqual(classifierJSON["model"] as? String, "mlx-community/Ask")
        XCTAssertEqual(classifierJSON["temperature"] as? Int, 0)
        XCTAssertEqual(classifierJSON["max_tokens"] as? Int, 128)
        XCTAssertEqual(classifierJSON["stream"] as? Bool, false)
    }

    func testModeAdviceDoesNotSuggestSwitchWhenAdviceMatchesSelectedMode() async throws {
        let upstream = FakeUpstream(
            chatCompletionBody: Data(
                #"{"choices":[{"message":{"content":"{\"mode\":\"plan\",\"confidence\":0.91,\"reason\":\"Planning request.\"}"}}]}"#.utf8
            )
        )
        let router = modeAdviceRouter(upstream: upstream)

        let response = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/provider/v1/mode-advice",
                headers: [:],
                body: Data(#"{"input":"plan this","selected_model":"mlx-plan"}"#.utf8)
            )
        )

        let advice = try jsonObject(in: response.body)
        XCTAssertEqual(advice["suggested_mode"] as? String, "plan")
        XCTAssertEqual(advice["current_mode"] as? String, "plan")
        XCTAssertEqual(advice["should_suggest_switch"] as? Bool, false)
    }

    func testModeAdviceDoesNotSuggestSwitchForLowConfidenceAdvice() async throws {
        let upstream = FakeUpstream(
            chatCompletionBody: Data(
                #"{"choices":[{"message":{"content":"{\"mode\":\"coding\",\"confidence\":0.4,\"reason\":\"Maybe code.\"}"}}]}"#.utf8
            )
        )
        let router = modeAdviceRouter(upstream: upstream)

        let response = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/provider/v1/mode-advice",
                headers: [:],
                body: Data(#"{"input":"maybe implement this","selected_model":"mlx-ask"}"#.utf8)
            )
        )

        let advice = try jsonObject(in: response.body)
        XCTAssertEqual(advice["suggested_mode"] as? String, "coding")
        XCTAssertEqual(advice["confidence"] as? Double, 0.4)
        XCTAssertEqual(advice["should_suggest_switch"] as? Bool, false)
    }

    func testModeAdviceReturnsUnknownWhenClassifierJSONIsMalformed() async throws {
        let upstream = FakeUpstream(
            chatCompletionBody: Data(
                #"{"choices":[{"message":{"content":"not json"}}]}"#.utf8
            )
        )
        let router = modeAdviceRouter(upstream: upstream)

        let response = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/provider/v1/mode-advice",
                headers: [:],
                body: Data(#"{"input":"plan this","selected_model":"mlx-ask"}"#.utf8)
            )
        )

        XCTAssertEqual(response.status, 200)
        let advice = try jsonObject(in: response.body)
        XCTAssertEqual(advice["suggested_mode"] as? String, "unknown")
        XCTAssertEqual(advice["confidence"] as? Double, 0)
        XCTAssertEqual(advice["should_suggest_switch"] as? Bool, false)
    }

    func testModeAdviceParsesChannelMarkedFinalJSON() async throws {
        let upstream = FakeUpstream(
            chatCompletionBody: Data(
                #"{"choices":[{"message":{"content":"<|channel|>analysis<|message|>Classify the request.<|end|><|channel|>final<|message|>{\"mode\":\"plan\",\"confidence\":0.84,\"reason\":\"The prompt asks for planning.\"}<|end|>"}}]}"#.utf8
            )
        )
        let router = modeAdviceRouter(upstream: upstream)

        let response = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/provider/v1/mode-advice",
                headers: [:],
                body: Data(#"{"input":"plan how to make a paper aeroplane","selected_model":"mlx-ask"}"#.utf8)
            )
        )

        XCTAssertEqual(response.status, 200)
        let advice = try jsonObject(in: response.body)
        XCTAssertEqual(advice["suggested_mode"] as? String, "plan")
        XCTAssertEqual(advice["confidence"] as? Double, 0.84)
        XCTAssertEqual(advice["reason"] as? String, "The prompt asks for planning.")
        XCTAssertEqual(advice["should_suggest_switch"] as? Bool, true)
    }

    func testModeAdviceReturnsUnknownWhenClassifierTimesOut() async throws {
        let upstream = SlowModeAdviceUpstream(delayNanoseconds: 200_000_000)
        let logger = CapturingProviderLogger()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Ask" },
            roleAssignmentsProvider: { ProviderRoleAssignments(ask: "mlx-community/Ask") },
            defaultEndpointProvider: {
                ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Ask",
                    baseURL: URL(string: "http://127.0.0.1:8080")!,
                    port: 8080
                )
            },
            roleEndpointProvider: { role in
                guard role == .ask else { return nil }
                return ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Ask",
                    baseURL: URL(string: "http://127.0.0.1:8080")!,
                    port: 8080
                )
            },
            modeAdviceTimeoutNanoseconds: 50_000_000,
            eventLogger: logger.log
        )

        let response = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/provider/v1/mode-advice",
                headers: [:],
                body: Data(#"{"input":"write the implementation","selected_model":"mlx-ask"}"#.utf8)
            )
        )

        XCTAssertEqual(response.status, 200)
        let advice = try jsonObject(in: response.body)
        XCTAssertEqual(advice["suggested_mode"] as? String, "unknown")
        XCTAssertEqual(advice["confidence"] as? Double, 0)
        XCTAssertEqual(advice["should_suggest_switch"] as? Bool, false)
        XCTAssertEqual(advice["reason"] as? String, "Mode advice timed out.")
        XCTAssertTrue(logger.messages.contains {
            $0 == "Provider mode advice unavailable: Mode advice timed out."
        })
    }

    func testModeAdviceReturnsUnknownWhenAskEndpointIsMissing() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Default" },
            roleAssignmentsProvider: { ProviderRoleAssignments(ask: "mlx-community/Ask") },
            defaultEndpointProvider: {
                ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Default",
                    baseURL: URL(string: "http://127.0.0.1:8080")!,
                    port: 8080
                )
            },
            roleEndpointProvider: { _ in nil }
        )

        let response = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/provider/v1/mode-advice",
                headers: [:],
                body: Data(#"{"input":"plan this","selected_model":"mlx-ask"}"#.utf8)
            )
        )

        XCTAssertEqual(response.status, 200)
        let advice = try jsonObject(in: response.body)
        XCTAssertEqual(advice["suggested_mode"] as? String, "unknown")
        XCTAssertEqual(advice["confidence"] as? Double, 0)
        XCTAssertEqual(advice["should_suggest_switch"] as? Bool, false)
        XCTAssertEqual(upstream.requests.count, 0)
    }

    func testModeAdviceWritesDebugMetadataWhenCaptureIsEnabled() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
        let upstream = FakeUpstream(
            chatCompletionBody: Data(
                #"{"choices":[{"message":{"content":"{\"mode\":\"coding\",\"confidence\":0.8,\"reason\":\"The prompt asks to write code.\"}"}}]}"#.utf8
            )
        )
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Ask" },
            roleAssignmentsProvider: { ProviderRoleAssignments(ask: "mlx-community/Ask") },
            defaultEndpointProvider: {
                ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Ask",
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
                path: "/provider/v1/mode-advice",
                headers: [:],
                body: Data(#"{"input":"write a function","selected_model":"mlx-ask"}"#.utf8)
            )
        )

        let record = try lastDebugRecord(in: debugFile)
        let advice = try XCTUnwrap(record["mode_advice"] as? [String: Any])
        XCTAssertEqual(advice["suggested_mode"] as? String, "coding")
        XCTAssertEqual(advice["should_suggest_switch"] as? Bool, true)
    }

    func testModeAdviceRejectsInvalidRequests() async throws {
        let router = modeAdviceRouter(upstream: FakeUpstream())

        let invalidJSON = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/provider/v1/mode-advice",
                headers: [:],
                body: Data("not json".utf8)
            )
        )
        let missingInput = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/provider/v1/mode-advice",
                headers: [:],
                body: Data(#"{"selected_model":"mlx-ask"}"#.utf8)
            )
        )

        XCTAssertEqual(invalidJSON.status, 400)
        XCTAssertEqual(missingInput.status, 400)
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

    func testMissingRoleEndpointFallbackReasonMentionsDefaultEndpointWhenDefaultDiffersFromActive() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
        let logger = CapturingProviderLogger()
        let router = ProviderRouter(
            upstream: FakeUpstream(),
            activeModelProvider: { "mlx-community/Active" },
            roleAssignmentsProvider: { ProviderRoleAssignments(plan: "mlx-community/Plan") },
            defaultEndpointProvider: {
                ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Default",
                    baseURL: URL(string: "http://127.0.0.1:8085")!,
                    port: 8085
                )
            },
            roleEndpointProvider: { _ in nil },
            eventLogger: logger.log,
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

        let record = try lastDebugRecord(in: debugFile)
        let decision = try XCTUnwrap(record["routing_decision"] as? [String: Any])
        XCTAssertEqual(decision["upstream_model"] as? String, "mlx-community/Default")
        XCTAssertEqual(decision["fallback_reason"] as? String, "role server unavailable; using default endpoint")
        XCTAssertTrue(logger.messages.contains { $0.contains("role server unavailable; using default endpoint") })
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
                body: Data(#"{"model":"mlx-coding","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)
            )
        )

        let proxied = try XCTUnwrap(upstream.requests.last)
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        let messages = try XCTUnwrap(proxiedJSON?["messages"] as? [[String: Any]])
        let systemText = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(systemText.contains("Provider selected model alias: mlx-coding."))
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
        let body = Data(#"{"model":"mlx-coding","messages":[{"role":"user","content":"secret prompt"}],"stream":false}"#.utf8)

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
        XCTAssertEqual(record["selected_model"] as? String, "mlx-coding")
        XCTAssertEqual(record["response_status"] as? Int, 200)
        XCTAssertEqual(record["alias_resolution"] as? String, "mlx-coding -> mlx-community/Tiny")
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
                body: Data(#"{"model":"mlx-coding","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: debugFile.path))
    }

    func testProviderDebugRecorderRotatesPayloadLogAndKeepsHeadersRedacted() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
        let recorder = ProviderDebugRecorder(
            fileURL: debugFile,
            isEnabled: { true },
            maxBytes: 360,
            retainedFileCount: 2
        )
        let request = ProviderRequest(
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["authorization": "Bearer secret-token", "content-type": "application/json"],
            body: Data(#"{"model":"mlx-coding","messages":[{"role":"user","content":"secret prompt that is deliberately long enough to rotate quickly"}],"stream":false}"#.utf8)
        )
        let response = ProviderResponse(
            status: 200,
            headers: ["content-type": "application/json"],
            body: Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)
        )

        for index in 0..<5 {
            recorder.record(
                request: request,
                response: response,
                selectedModel: "mlx-coding-\(index)",
                aliasResolution: nil
            )
        }

        let rotated1 = URL(fileURLWithPath: debugFile.path + ".1")
        let rotated2 = URL(fileURLWithPath: debugFile.path + ".2")
        let rotated3 = URL(fileURLWithPath: debugFile.path + ".3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: debugFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated2.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotated3.path))

        let combined = try [debugFile, rotated1, rotated2]
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(combined.contains(#""authorization":"<redacted>""#))
        XCTAssertFalse(combined.contains("secret-token"))
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

    func testProviderLogsThrownUpstreamFailuresForProxiedRequests() async throws {
        let upstream = ThrowingUpstream(errorDescription: "diffusion server returned 502: model timed out")
        let logger = CapturingProviderLogger()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit" },
            roleAssignmentsProvider: {
                ProviderRoleAssignments(ask: "mlx-community/Nemotron-Labs-Diffusion-3B-4bit")
            },
            defaultEndpointProvider: {
                ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit",
                    baseURL: URL(string: "http://127.0.0.1:8080")!,
                    port: 8080
                )
            },
            roleEndpointProvider: { role in
                role == .ask
                ? ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Nemotron-Labs-Diffusion-3B-4bit",
                    baseURL: URL(string: "http://127.0.0.1:8081")!,
                    port: 8081
                )
                : nil
            },
            eventLogger: logger.log
        )
        let body = Data(#"{"model":"mlx-ask","messages":[{"role":"user","content":"secret prompt"}],"stream":false}"#.utf8)

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 502)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), #"{"error":"bad gateway"}"#)
        XCTAssertTrue(logger.messages.contains {
            $0 == "Provider upstream request failed for POST /v1/chat/completions: diffusion server returned 502: model timed out"
        })
        XCTAssertTrue(logger.messages.contains {
            $0 == "Provider upstream request summary for POST /v1/chat/completions: keys=[max_tokens,messages,model,stream,temperature,top_p], model=mlx-community/Nemotron-Labs-Diffusion-3B-4bit, stream=false, message_count=1"
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

    func testProviderNormalizesAssistantChannelMarkersIntoThinkingAndContent() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
        )
        let body = Data(
            #"{"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"<|channel|>analysis<|message|>first thought<|end|><|channel|>final<|message|>first answer<|end|>"},{"role":"assistant","content":"<|channel|>analysis<|message|>second thought<|end|><|channel|>final<|message|>second answer<|end|>"}],"stream":false}"#.utf8
        )

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        let messages = try XCTUnwrap(proxiedJSON?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant"])
        XCTAssertEqual(messages[1]["content"] as? String, "first answer\n\nsecond answer")
        XCTAssertEqual(messages[1]["thinking"] as? String, "first thought\n\nsecond thought")
        let proxiedText = String(data: proxied.body, encoding: .utf8) ?? ""
        XCTAssertFalse(proxiedText.contains("<|channel|>"))
        XCTAssertFalse(proxiedText.contains("<|message|>"))
        XCTAssertFalse(proxiedText.contains("<|end|>"))
    }

    func testProviderNormalizesChannelMarkedAssistantChatCompletionResponse() async throws {
        let upstream = FakeUpstream(
            chatCompletionBody: Data(
                #"{"id":"chatcmpl-test","object":"chat.completion","created":1,"model":"mlx-community/Tiny","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"<|channel|>analysis<|message|>Need to answer briefly.<|end|><|start|>assistant<|channel|>final<|message|>ok<|end|>"}}]}"#.utf8
            )
        )
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
        )

        let response = try await router.handle(
            ProviderRequest(
                method: "POST",
                path: "/v1/chat/completions",
                headers: [:],
                body: Data(#"{"model":"mlx-community/Tiny","messages":[{"role":"user","content":"Say ok only."}],"stream":false}"#.utf8)
            )
        )

        XCTAssertEqual(response.status, 200)
        let responseJSON = try jsonObject(in: response.body)
        let choices = try XCTUnwrap(responseJSON["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "ok")
        XCTAssertEqual(message["reasoning"] as? String, "Need to answer briefly.")
        let responseText = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertFalse(responseText.contains("<|channel|>"))
        XCTAssertFalse(responseText.contains("<|message|>"))
        XCTAssertFalse(responseText.contains("<|end|>"))
        XCTAssertFalse(responseText.contains("<|start|>"))
    }

    func testProviderStripsChannelMarkersFromNonAssistantMessages() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Tiny" }
        )
        let body = Data(
            #"{"messages":[{"role":"user","content":"<|channel|>analysis<|message|>draft context<|end|><|channel|>final<|message|>Please answer<|end|>"}],"stream":false}"#.utf8
        )

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 200)
        let proxied = try XCTUnwrap(upstream.requests.last)
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        let messages = try XCTUnwrap(proxiedJSON?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "draft context\n\nPlease answer")
        XCTAssertNil(messages[0]["thinking"])
        let proxiedText = String(data: proxied.body, encoding: .utf8) ?? ""
        XCTAssertFalse(proxiedText.contains("<|channel|>"))
        XCTAssertFalse(proxiedText.contains("<|message|>"))
        XCTAssertFalse(proxiedText.contains("<|end|>"))
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

    func testProviderRoutesRunnableTextDiffusionChatCompletionsAsText() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Diffusion-Gemma" },
            modelMetadataProvider: {
                [
                    "mlx-community/Diffusion-Gemma": ProviderModelMetadata(modelFamily: .diffusionText)
                ]
            }
        )
        let body = Data(#"{"model":"mlx-community/Diffusion-Gemma","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 200)
        let responseJSON = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let choices = try XCTUnwrap(responseJSON?["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "Hello from chat.")
        let proxied = try XCTUnwrap(upstream.requests.last)
        XCTAssertEqual(proxied.path, "/v1/chat/completions")
        let proxiedJSON = try JSONSerialization.jsonObject(with: proxied.body) as? [String: Any]
        XCTAssertEqual(proxiedJSON?["model"] as? String, "mlx-community/Diffusion-Gemma")
    }

    func testProviderStreamsRunnableTextDiffusionChatCompletionsAsOpenAITextDeltas() async throws {
        let upstream = FakeUpstream()
        let router = ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Diffusion-Gemma" },
            modelMetadataProvider: {
                [
                    "mlx-community/Diffusion-Gemma": ProviderModelMetadata(modelFamily: .diffusionText)
                ]
            }
        )
        let body = Data(#"{"model":"mlx-community/Diffusion-Gemma","messages":[{"role":"user","content":"hi"}],"stream":true}"#.utf8)

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-type"], "text/event-stream")
        let stream = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        XCTAssertTrue(stream.contains(#"data: {"choices":[{"delta":{"content":"Hel"},"finish_reason":null}]}"#))
        XCTAssertTrue(stream.contains(#"data: {"choices":[{"delta":{"content":"lo"},"finish_reason":null}]}"#))
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

    func testResponsesDebugCaptureUsesSelectedRoleEndpointDecision() async throws {
        let root = try temporaryDirectory()
        let debugFile = root.appending(path: "provider-debug.jsonl")
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
            },
            debugRecorder: ProviderDebugRecorder(fileURL: debugFile, isEnabled: { true })
        )
        let body = Data(#"{"model":"mlx-plan","input":"plan","temperature":0.2,"max_output_tokens":32}"#.utf8)

        let response = try await router.handle(
            ProviderRequest(method: "POST", path: "/v1/responses", headers: [:], body: body)
        )

        XCTAssertEqual(response.status, 200)
        let record = try lastDebugRecord(in: debugFile)
        let decision = try XCTUnwrap(record["routing_decision"] as? [String: Any])
        XCTAssertEqual(decision["selected_alias"] as? String, "mlx-plan")
        XCTAssertEqual(decision["inferred_role"] as? String, "plan")
        XCTAssertEqual(decision["upstream_model"] as? String, "mlx-community/Devstral")
        XCTAssertEqual(decision["upstream_base_url"] as? String, "http://127.0.0.1:8081")
        XCTAssertEqual(decision["upstream_port"] as? Int, 8081)
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
        ["mlx-ask", "mlx-plan", "mlx-coding", active]
    }

    private func outputText(in data: Data) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let output = object?["output"] as? [[String: Any]]
        let message = output?.first
        let content = message?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String
    }

    private func jsonObject(in data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func modeAdviceRouter(upstream: FakeUpstream) -> ProviderRouter {
        ProviderRouter(
            upstream: upstream,
            activeModelProvider: { "mlx-community/Ask" },
            roleAssignmentsProvider: { ProviderRoleAssignments(ask: "mlx-community/Ask") },
            defaultEndpointProvider: {
                ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Ask",
                    baseURL: URL(string: "http://127.0.0.1:8080")!,
                    port: 8080
                )
            },
            roleEndpointProvider: { role in
                guard role == .ask else { return nil }
                return ProviderUpstreamEndpoint(
                    modelID: "mlx-community/Ask",
                    baseURL: URL(string: "http://127.0.0.1:8080")!,
                    port: 8080
                )
            }
        )
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
    private let chatCompletionBody: Data
    private let chatCompletionStatus: Int

    init(
        notFoundBody: Data = Data(),
        chatCompletionBody: Data = Data(
            #"{"id":"chatcmpl-test","object":"chat.completion","created":1,"model":"mlx-community/Tiny","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"Hello from chat."}}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}"#.utf8
        ),
        chatCompletionStatus: Int = 200
    ) {
        self.notFoundBody = notFoundBody
        self.chatCompletionBody = chatCompletionBody
        self.chatCompletionStatus = chatCompletionStatus
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
                    status: chatCompletionStatus,
                    headers: ["content-type": "application/json"],
                    body: chatCompletionBody
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

private struct ThrowingUpstream: ProviderUpstreamProxyClient {
    let errorDescription: String

    func proxy(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint) async throws -> ProviderResponse {
        throw UpstreamFailure(description: errorDescription)
    }

    func proxyStream(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint) async throws -> ProviderStreamedResponse {
        throw UpstreamFailure(description: errorDescription)
    }

    private struct UpstreamFailure: LocalizedError {
        let description: String

        var errorDescription: String? {
            description
        }
    }
}

private final class SlowModeAdviceUpstream: ProviderUpstreamProxyClient, @unchecked Sendable {
    let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func proxy(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint) async throws -> ProviderResponse {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return ProviderResponse(
            status: 200,
            headers: ["content-type": "application/json"],
            body: Data(
                #"{"choices":[{"message":{"content":"{\"mode\":\"coding\",\"confidence\":0.92,\"reason\":\"Slow but valid.\"}"}}]}"#.utf8
            )
        )
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
