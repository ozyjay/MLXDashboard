import Foundation
import MLXCore

public struct ProviderRouter: Sendable {
    private static let modeAliases = ["mlx-ask", "mlx-plan", "mlx-fast"]
    private static let compatibilityBaseURL = URL(string: "http://127.0.0.1:8080")!

    private let upstream: any ProviderUpstreamProxyClient
    private let legacyUpstream: (any ProviderUpstreamClient)?
    private let activeModelProvider: @Sendable () -> String?
    private let roleAssignmentsProvider: @Sendable () -> ProviderRoleAssignments
    private let defaultEndpointProvider: @Sendable () -> ProviderUpstreamEndpoint?
    private let roleEndpointProvider: @Sendable (ProviderModelRole) -> ProviderUpstreamEndpoint?
    private let eventLogger: @Sendable (String) -> Void
    private let debugRecorder: ProviderDebugRecorder?
    // Android Studio probes these local-provider discovery paths before using OpenAI-compatible chat routes.
    private let allowedPaths: Set<String> = [
        "/api/chat",
        "/api/generate",
        "/api/ps",
        "/api/show",
        "/api/tags",
        "/api/v0/models",
        "/api/version",
        "/v1/models",
        "/v1/chat/completions",
        "/v1/completions",
        "/v1/responses"
    ]

    public init(
        upstream: any ProviderUpstreamProxyClient,
        activeModelProvider: @escaping @Sendable () -> String? = { nil },
        roleAssignmentsProvider: @escaping @Sendable () -> ProviderRoleAssignments = { ProviderRoleAssignments() },
        defaultEndpointProvider: @escaping @Sendable () -> ProviderUpstreamEndpoint?,
        roleEndpointProvider: @escaping @Sendable (ProviderModelRole) -> ProviderUpstreamEndpoint?,
        eventLogger: @escaping @Sendable (String) -> Void = { _ in },
        debugRecorder: ProviderDebugRecorder? = nil
    ) {
        self.init(
            upstream: upstream,
            legacyUpstream: nil,
            activeModelProvider: activeModelProvider,
            roleAssignmentsProvider: roleAssignmentsProvider,
            defaultEndpointProvider: defaultEndpointProvider,
            roleEndpointProvider: roleEndpointProvider,
            eventLogger: eventLogger,
            debugRecorder: debugRecorder
        )
    }

    public init(
        upstream: any ProviderUpstreamClient,
        activeModelProvider: @escaping @Sendable () -> String? = { nil },
        roleAssignmentsProvider: @escaping @Sendable () -> ProviderRoleAssignments = { ProviderRoleAssignments() },
        eventLogger: @escaping @Sendable (String) -> Void = { _ in },
        debugRecorder: ProviderDebugRecorder? = nil
    ) {
        self.init(
            upstream: ProviderUpstreamClientAdapter(upstream: upstream),
            legacyUpstream: upstream,
            activeModelProvider: activeModelProvider,
            roleAssignmentsProvider: roleAssignmentsProvider,
            defaultEndpointProvider: { nil },
            roleEndpointProvider: { _ in nil },
            eventLogger: eventLogger,
            debugRecorder: debugRecorder
        )
    }

    private init(
        upstream: any ProviderUpstreamProxyClient,
        legacyUpstream: (any ProviderUpstreamClient)?,
        activeModelProvider: @escaping @Sendable () -> String?,
        roleAssignmentsProvider: @escaping @Sendable () -> ProviderRoleAssignments,
        defaultEndpointProvider: @escaping @Sendable () -> ProviderUpstreamEndpoint?,
        roleEndpointProvider: @escaping @Sendable (ProviderModelRole) -> ProviderUpstreamEndpoint?,
        eventLogger: @escaping @Sendable (String) -> Void,
        debugRecorder: ProviderDebugRecorder?
    ) {
        self.upstream = upstream
        self.legacyUpstream = legacyUpstream
        self.activeModelProvider = activeModelProvider
        self.roleAssignmentsProvider = roleAssignmentsProvider
        self.defaultEndpointProvider = defaultEndpointProvider
        self.roleEndpointProvider = roleEndpointProvider
        self.eventLogger = eventLogger
        self.debugRecorder = debugRecorder
    }

    public func handle(_ request: ProviderRequest) async throws -> ProviderResponse {
        switch try await route(request) {
        case .buffered(let response):
            return response
        case .streamed(let response):
            var body = Data()
            for try await chunk in response.chunks {
                body.append(chunk)
            }
            return ProviderResponse(status: response.status, headers: response.headers, body: body)
        }
    }

    public func route(_ request: ProviderRequest) async throws -> ProviderRouteResult {
        let request = requestWithCanonicalPath(request)
        let debugContext = debugContext(for: request)

        func finish(_ response: ProviderResponse, context: ProviderDebugContext = debugContext) -> ProviderRouteResult {
            debugRecorder?.record(
                request: request,
                response: response,
                selectedModel: context.selectedModel,
                aliasResolution: context.aliasResolution,
                routingDecision: context.routingDecision?.debugPayload
            )
            return .buffered(response)
        }

        func logStreamErrorIfNeeded(response: ProviderStreamedResponse, body: Data, upstreamRequest: ProviderRequest?) {
            guard response.status >= 400 else { return }
            eventLogger("Provider upstream error body for \(request.method) \(request.path) status \(response.status): \(sanitizedErrorBody(body))")
            if let upstreamRequest {
                eventLogger("Provider upstream request summary for \(request.method) \(request.path): \(requestSummary(from: upstreamRequest.body))")
            }
        }

        func finishStream(
            _ response: ProviderStreamedResponse,
            context: ProviderDebugContext = debugContext,
            upstreamRequest: ProviderRequest? = nil
        ) -> ProviderRouteResult {
            guard let debugRecorder else {
                let chunks = AsyncThrowingStream<Data, Error> { continuation in
                    Task {
                        var body = Data()
                        do {
                            for try await chunk in response.chunks {
                                body.append(chunk)
                                continuation.yield(chunk)
                            }
                            logStreamErrorIfNeeded(response: response, body: body, upstreamRequest: upstreamRequest)
                            continuation.finish()
                        } catch {
                            logStreamErrorIfNeeded(response: response, body: body, upstreamRequest: upstreamRequest)
                            continuation.finish(throwing: error)
                        }
                    }
                }
                return .streamed(ProviderStreamedResponse(status: response.status, headers: response.headers, chunks: chunks))
            }

            let chunks = AsyncThrowingStream<Data, Error> { continuation in
                Task {
                    var body = Data()
                    do {
                        for try await chunk in response.chunks {
                            body.append(chunk)
                            continuation.yield(chunk)
                        }
                        logStreamErrorIfNeeded(response: response, body: body, upstreamRequest: upstreamRequest)
                        debugRecorder.record(
                            request: request,
                            response: ProviderResponse(status: response.status, headers: response.headers, body: body),
                            selectedModel: context.selectedModel,
                            aliasResolution: context.aliasResolution,
                            routingDecision: context.routingDecision?.debugPayload
                        )
                        continuation.finish()
                    } catch {
                        logStreamErrorIfNeeded(response: response, body: body, upstreamRequest: upstreamRequest)
                        debugRecorder.record(
                            request: request,
                            response: ProviderResponse(status: response.status, headers: response.headers, body: body),
                            selectedModel: context.selectedModel,
                            aliasResolution: context.aliasResolution,
                            routingDecision: context.routingDecision?.debugPayload
                        )
                        continuation.finish(throwing: error)
                    }
                }
            }
            return .streamed(ProviderStreamedResponse(status: response.status, headers: response.headers, chunks: chunks))
        }

        logIncomingRequestSummary(request)

        if request.method == "GET", request.path == "/health" {
            eventLogger("Provider health check")
            return finish(json(status: 200, #"{"status":"ok"}"#))
        }

        if request.method == "GET", let requestedModel = requestedModelID(from: request.path) {
            eventLogger("Provider served GET /v1/models/\(requestedModel)")
            return finish(modelResponse(for: requestedModel))
        }

        if request.method == "GET", let requestedModel = androidStudioV0ModelID(from: request.path) {
            eventLogger("Provider served Android Studio compatibility GET /api/v0/models/\(requestedModel)")
            return finish(androidStudioV0ModelResponse(for: requestedModel))
        }

        guard allowedPaths.contains(request.path) else {
            eventLogger("Provider rejected \(request.method) \(request.path): unsupported route")
            return finish(json(status: 404, #"{"error":"not found"}"#))
        }

        if request.method == "GET", request.path == "/v1/models" {
            eventLogger("Provider served GET /v1/models")
            return finish(modelsResponse())
        }

        if request.method == "GET", request.path == "/api/v0/models" {
            eventLogger("Provider served Android Studio compatibility GET /api/v0/models")
            return finish(androidStudioV0ModelsResponse())
        }

        if request.method == "GET", request.path == "/api/tags" {
            eventLogger("Provider served Android Studio compatibility GET /api/tags")
            return finish(androidStudioTagsResponse())
        }

        if request.method == "GET", request.path == "/api/ps" {
            eventLogger("Provider served Android Studio compatibility GET /api/ps")
            return finish(androidStudioRunningModelsResponse())
        }

        if request.method == "GET", request.path == "/api/version" {
            eventLogger("Provider served Android Studio compatibility GET /api/version")
            return finish(json(status: 200, #"{"version":"0.0.0"}"#))
        }

        if request.method == "POST", request.path == "/api/show" {
            eventLogger("Provider served Android Studio compatibility POST /api/show")
            return finish(androidStudioShowResponse(request))
        }

        if request.method == "POST", request.path == "/api/chat" {
            eventLogger("Provider translated Android Studio compatibility POST /api/chat to chat completions")
            return finish(try await androidStudioChatResponse(request))
        }

        if request.method == "POST", request.path == "/api/generate" {
            eventLogger("Provider translated Android Studio compatibility POST /api/generate to chat completions")
            return finish(try await androidStudioGenerateResponse(request))
        }

        if request.method == "POST", request.path == "/v1/responses" {
            eventLogger("Provider translated POST /v1/responses to chat completions")
            return finish(try await responseFromChatCompletion(request))
        }

        let routed = requestWithSelectedUpstreamIfAvailable(request)
        let proxiedRequest = routed.request
        let upstreamEndpoint = routed.upstreamEndpoint ?? defaultUpstreamEndpoint()
        if shouldStream(proxiedRequest) {
            let response = try await proxyStream(proxiedRequest, to: upstreamEndpoint)
            eventLogger("Provider streaming \(request.method) \(request.path) from upstream with status \(response.status)")
            return finishStream(response, context: routed.debugContext, upstreamRequest: proxiedRequest)
        }

        let response = try await proxy(proxiedRequest, to: upstreamEndpoint)
        eventLogger("Provider proxied \(request.method) \(request.path) to upstream with status \(response.status)")
        if response.status >= 400 {
            eventLogger("Provider upstream error body for \(request.method) \(request.path) status \(response.status): \(sanitizedErrorBody(response.body))")
            eventLogger("Provider upstream request summary for \(request.method) \(request.path): \(requestSummary(from: proxiedRequest.body))")
        }
        return finish(response, context: routed.debugContext)
    }

    private func requestWithCanonicalPath(_ request: ProviderRequest) -> ProviderRequest {
        let canonicalPath = canonicalPath(for: request.path)
        guard canonicalPath != request.path else { return request }
        eventLogger("Provider normalized \(request.method) \(request.path) to \(canonicalPath)")
        return ProviderRequest(method: request.method, path: canonicalPath, headers: request.headers, body: request.body)
    }

    private func canonicalPath(for path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/api/v0/models" || path.hasPrefix("/api/v0/models/") {
            return path
        }
        while path.hasPrefix("/api/v0/") {
            path = String(path.dropFirst("/api/v0".count))
        }
        while path.hasPrefix("/api/v1/") {
            path = String(path.dropFirst("/api".count))
        }
        while path.hasPrefix("/v1/v1/") {
            path = "/v1/" + String(path.dropFirst("/v1/v1/".count))
        }
        switch path {
        case "/chat":
            return "/api/chat"
        case "/generate":
            return "/api/generate"
        case "/ps":
            return "/api/ps"
        case "/show":
            return "/api/show"
        case "/tags":
            return "/api/tags"
        case "/version":
            return "/api/version"
        case "/models":
            return "/v1/models"
        case let unversionedModelPath where unversionedModelPath.hasPrefix("/models/"):
            return "/v1" + unversionedModelPath
        case "/chat/completions":
            return "/v1/chat/completions"
        case "/completions":
            return "/v1/completions"
        case "/responses":
            return "/v1/responses"
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

    private func shouldStream(_ request: ProviderRequest) -> Bool {
        guard request.method == "POST",
              request.path == "/v1/chat/completions" || request.path == "/v1/completions",
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        else { return false }
        return object["stream"] as? Bool == true
    }

    private func activeModel() -> String? {
        activeModelProvider().flatMap { $0.isEmpty ? nil : $0 }
    }

    private func compatibilityEndpoint(for modelID: String) -> ProviderUpstreamEndpoint {
        ProviderUpstreamEndpoint(modelID: modelID, baseURL: Self.compatibilityBaseURL, port: nil)
    }

    private func defaultUpstreamEndpoint() -> ProviderUpstreamEndpoint? {
        if let endpoint = defaultEndpointProvider() {
            return endpoint
        }
        guard let activeModel = activeModel() else { return nil }
        return compatibilityEndpoint(for: activeModel)
    }

    private func proxy(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint?) async throws -> ProviderResponse {
        if let endpoint {
            return try await upstream.proxy(request, to: endpoint)
        }
        if let legacyUpstream {
            return try await legacyUpstream.proxy(request)
        }
        return json(status: 503, #"{"error":"no upstream endpoint available"}"#)
    }

    private func proxyStream(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint?) async throws -> ProviderStreamedResponse {
        if let endpoint {
            return try await upstream.proxyStream(request, to: endpoint)
        }
        if let legacyUpstream {
            return try await legacyUpstream.proxyStream(request)
        }
        return ProviderStreamedResponse(
            status: 503,
            headers: ["content-type": "application/json"],
            chunks: AsyncThrowingStream { continuation in
                continuation.yield(Data(#"{"error":"no upstream endpoint available"}"#.utf8))
                continuation.finish()
            }
        )
    }

    private func advertisedModels() -> [String] {
        guard let activeModel = activeModel() else { return [] }
        return (Self.modeAliases + [activeModel]).reduce(into: []) { models, model in
            if !models.contains(model) {
                models.append(model)
            }
        }
    }

    private func isAdvertisedModel(_ model: String) -> Bool {
        advertisedModels().contains(model)
    }

    private func aliasResolution(for selectedModel: String?) -> String? {
        guard let selectedModel,
              Self.modeAliases.contains(selectedModel),
              let activeModel = activeModel()
        else { return nil }
        return "\(selectedModel) -> \(activeModel)"
    }

    private func debugContext(for request: ProviderRequest) -> ProviderDebugContext {
        let selectedModel = selectedModel(from: request.body)
        return ProviderDebugContext(
            selectedModel: selectedModel,
            aliasResolution: aliasResolution(for: selectedModel),
            routingDecision: nil
        )
    }

    private func selectedModel(from body: Data) -> String? {
        decodedObject(from: body)?["model"] as? String
    }

    private func logIncomingRequestSummary(_ request: ProviderRequest) {
        guard request.method == "POST", !request.body.isEmpty else { return }
        eventLogger("Provider received \(request.method) \(request.path): \(requestSummary(from: request.body))")
    }

    private func modelsResponse() -> ProviderResponse {
        let models = advertisedModels()
        guard !models.isEmpty else {
            return json(status: 200, #"{"object":"list","data":[]}"#)
        }

        let payload: [String: Any] = [
            "object": "list",
            "data": models.map { model in
                [
                    "id": model,
                    "object": "model"
                ]
            }
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(#"{"object":"list","data":[]}"#.utf8)
        return ProviderResponse(status: 200, headers: ["content-type": "application/json"], body: data)
    }

    private func androidStudioV0ModelsResponse() -> ProviderResponse {
        let models = advertisedModels()
        guard !models.isEmpty else {
            return json(status: 200, #"{"object":"list","data":[]}"#)
        }

        let payload: [String: Any] = [
            "object": "list",
            "data": models.map(androidStudioV0ModelPayload)
        ]
        return jsonResponse(payload)
    }

    private func androidStudioV0ModelResponse(for requestedModel: String) -> ProviderResponse {
        guard isAdvertisedModel(requestedModel) else {
            return json(status: 404, #"{"error":"not found"}"#)
        }

        return jsonResponse(androidStudioV0ModelPayload(requestedModel))
    }

    private func androidStudioV0ModelPayload(_ model: String) -> [String: Any] {
        [
            "id": model,
            "object": "model",
            "type": "llm",
            "publisher": publisher(for: model),
            "arch": architecture(for: model),
            "compatibility_type": "mlx",
            "quantization": quantization(for: model),
            "state": "loaded",
            "max_context_length": 32768
        ]
    }

    private func publisher(for model: String) -> String {
        model.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
    }

    private func architecture(for model: String) -> String {
        let lowercased = model.lowercased()
        if lowercased.contains("devstral") { return "devstral" }
        if lowercased.contains("qwen") { return "qwen" }
        if lowercased.contains("llama") { return "llama" }
        if lowercased.contains("gemma") { return "gemma" }
        if lowercased.contains("mistral") { return "mistral" }
        return "mlx"
    }

    private func quantization(for model: String) -> String {
        let lowercased = model.lowercased()
        if lowercased.contains("4bit") { return "4bit" }
        if lowercased.contains("8bit") { return "8bit" }
        return ""
    }

    private func androidStudioTagsResponse() -> ProviderResponse {
        let models = advertisedModels()
        guard !models.isEmpty else {
            return json(status: 200, #"{"models":[]}"#)
        }

        let payload: [String: Any] = [
            "models": models.map { model in
                [
                    "name": model,
                    "model": model,
                    "modified_at": "1970-01-01T00:00:00Z",
                    "size": 0,
                    "digest": ""
                ]
            }
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(#"{"models":[]}"#.utf8)
        return ProviderResponse(status: 200, headers: ["content-type": "application/json"], body: data)
    }

    private func androidStudioRunningModelsResponse() -> ProviderResponse {
        let models = advertisedModels()
        guard !models.isEmpty else {
            return json(status: 200, #"{"models":[]}"#)
        }

        let payload: [String: Any] = [
            "models": models.map { model in
                [
                    "name": model,
                    "model": model,
                    "size": 0,
                    "digest": "",
                    "details": [
                        "format": "mlx",
                        "family": "mlx",
                        "families": ["mlx"],
                        "parameter_size": "",
                        "quantization_level": ""
                    ],
                    "expires_at": compatibilityTimestamp(),
                    "size_vram": 0
                ]
            }
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(#"{"models":[]}"#.utf8)
        return ProviderResponse(status: 200, headers: ["content-type": "application/json"], body: data)
    }

    private func androidStudioShowResponse(_ request: ProviderRequest) -> ProviderResponse {
        let requestedModel = decodedObject(from: request.body)?["model"] as? String
        let model: String
        if let requestedModel, isAdvertisedModel(requestedModel) {
            model = requestedModel
        } else {
            model = activeModel() ?? requestedModel ?? "local"
        }

        let payload: [String: Any] = [
            "model": model,
            "license": "",
            "modelfile": "",
            "parameters": "",
            "template": "",
            "details": [
                "format": "mlx",
                "family": "mlx",
                "families": ["mlx"],
                "parameter_size": "",
                "quantization_level": ""
            ],
            "model_info": [:],
            "capabilities": ["completion"]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(#"{"license":""}"#.utf8)
        return ProviderResponse(status: 200, headers: ["content-type": "application/json"], body: data)
    }

    private func androidStudioChatResponse(_ request: ProviderRequest) async throws -> ProviderResponse {
        guard let object = decodedObject(from: request.body) else {
            return json(status: 400, #"{"error":"invalid chat request"}"#)
        }

        let requestedModel = object["model"] as? String
        if aliasResolution(for: requestedModel) != nil,
           let activeModel = activeModel() {
            eventLogger("Provider resolved model alias \(requestedModel ?? "") to active model \(activeModel)")
        }
        let model = defaultUpstreamEndpoint()?.modelID ?? activeModel() ?? requestedModel ?? "local"
        let messages = object["messages"] as? [[String: Any]] ?? []
        let stream = object["stream"] as? Bool ?? true
        let chatResponse = try await proxyChatCompletion(model: model, messages: messages, stream: stream, headers: request.headers)
        guard chatResponse.status >= 200, chatResponse.status < 300 else {
            return chatResponse
        }

        if stream {
            return androidStudioStreamingChatResponse(model: model, chatBody: chatResponse.body)
        }

        let text = assistantText(fromChatCompletionBody: chatResponse.body)
        let payload: [String: Any] = [
            "model": model,
            "created_at": compatibilityTimestamp(),
            "message": [
                "role": "assistant",
                "content": text
            ],
            "done": true,
            "done_reason": "stop",
            "total_duration": 0,
            "load_duration": 0,
            "prompt_eval_count": usagePayload(fromChatCompletionBody: chatResponse.body)["input_tokens"] ?? 0,
            "eval_count": usagePayload(fromChatCompletionBody: chatResponse.body)["output_tokens"] ?? 0,
            "eval_duration": 0
        ]
        return jsonResponse(payload)
    }

    private func androidStudioGenerateResponse(_ request: ProviderRequest) async throws -> ProviderResponse {
        guard let object = decodedObject(from: request.body) else {
            return json(status: 400, #"{"error":"invalid generate request"}"#)
        }

        let requestedModel = object["model"] as? String
        if aliasResolution(for: requestedModel) != nil,
           let activeModel = activeModel() {
            eventLogger("Provider resolved model alias \(requestedModel ?? "") to active model \(activeModel)")
        }
        let model = defaultUpstreamEndpoint()?.modelID ?? activeModel() ?? requestedModel ?? "local"
        let prompt = object["prompt"] as? String ?? ""
        let stream = object["stream"] as? Bool ?? true
        let chatResponse = try await proxyChatCompletion(
            model: model,
            messages: [["role": "user", "content": prompt]],
            stream: stream,
            headers: request.headers
        )
        guard chatResponse.status >= 200, chatResponse.status < 300 else {
            return chatResponse
        }

        if stream {
            return androidStudioStreamingGenerateResponse(model: model, chatBody: chatResponse.body)
        }

        let text = assistantText(fromChatCompletionBody: chatResponse.body)
        let payload: [String: Any] = [
            "model": model,
            "created_at": compatibilityTimestamp(),
            "response": text,
            "done": true,
            "done_reason": "stop",
            "context": [],
            "total_duration": 0,
            "load_duration": 0,
            "prompt_eval_count": usagePayload(fromChatCompletionBody: chatResponse.body)["input_tokens"] ?? 0,
            "eval_count": usagePayload(fromChatCompletionBody: chatResponse.body)["output_tokens"] ?? 0,
            "eval_duration": 0
        ]
        return jsonResponse(payload)
    }

    private func proxyChatCompletion(
        model: String,
        messages: [[String: Any]],
        stream: Bool,
        headers: [String: String]
    ) async throws -> ProviderResponse {
        let chatBody = try JSONSerialization.data(
            withJSONObject: [
                "model": model,
                "messages": messages,
                "stream": stream
            ]
        )
        let request = ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: headers, body: chatBody)
        return try await proxy(request, to: defaultUpstreamEndpoint())
    }

    private func androidStudioStreamingChatResponse(model: String, chatBody: Data) -> ProviderResponse {
        var stream = Data()
        let deltas = outputTextDeltas(fromChatCompletionBody: chatBody)
        for delta in deltas where !delta.isEmpty {
            appendJSONLine(
                [
                    "model": model,
                    "created_at": compatibilityTimestamp(),
                    "message": [
                        "role": "assistant",
                        "content": delta
                    ],
                    "done": false
                ],
                to: &stream
            )
        }
        appendJSONLine(
            [
                "model": model,
                "created_at": compatibilityTimestamp(),
                "message": [
                    "role": "assistant",
                    "content": ""
                ],
                "done": true,
                "done_reason": "stop"
            ],
            to: &stream
        )
        return ProviderResponse(status: 200, headers: ["content-type": "application/x-ndjson"], body: stream)
    }

    private func androidStudioStreamingGenerateResponse(model: String, chatBody: Data) -> ProviderResponse {
        var stream = Data()
        let deltas = outputTextDeltas(fromChatCompletionBody: chatBody)
        for delta in deltas where !delta.isEmpty {
            appendJSONLine(
                [
                    "model": model,
                    "created_at": compatibilityTimestamp(),
                    "response": delta,
                    "done": false
                ],
                to: &stream
            )
        }
        appendJSONLine(
            [
                "model": model,
                "created_at": compatibilityTimestamp(),
                "response": "",
                "done": true,
                "done_reason": "stop"
            ],
            to: &stream
        )
        return ProviderResponse(status: 200, headers: ["content-type": "application/x-ndjson"], body: stream)
    }

    private func appendJSONLine(_ payload: [String: Any], to stream: inout Data) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        stream.append(data)
        stream.append(Data("\n".utf8))
    }

    private func jsonResponse(_ payload: [String: Any]) -> ProviderResponse {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(#"{}"#.utf8)
        return ProviderResponse(status: 200, headers: ["content-type": "application/json"], body: data)
    }

    private func decodedObject(from body: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private func compatibilityTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func requestedModelID(from path: String) -> String? {
        let prefix = "/v1/models/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        let encodedModel = String(path.dropFirst(prefix.count))
        return encodedModel.removingPercentEncoding ?? encodedModel
    }

    private func androidStudioV0ModelID(from path: String) -> String? {
        let prefix = "/api/v0/models/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        let encodedModel = String(path.dropFirst(prefix.count))
        return encodedModel.removingPercentEncoding ?? encodedModel
    }

    private func modelResponse(for requestedModel: String) -> ProviderResponse {
        guard isAdvertisedModel(requestedModel) else {
            return json(status: 404, #"{"error":"not found"}"#)
        }

        let payload: [String: Any] = [
            "id": requestedModel,
            "object": "model"
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(#"{"object":"model"}"#.utf8)
        return ProviderResponse(status: 200, headers: ["content-type": "application/json"], body: data)
    }

    private func requestWithSelectedUpstreamIfAvailable(_ request: ProviderRequest) -> (
        request: ProviderRequest,
        debugContext: ProviderDebugContext,
        upstreamEndpoint: ProviderUpstreamEndpoint?
    ) {
        let selectedModel = selectedModel(from: request.body)
        var debugContext = ProviderDebugContext(
            selectedModel: selectedModel,
            aliasResolution: aliasResolution(for: selectedModel),
            routingDecision: nil
        )
        guard request.method == "POST",
              request.path == "/v1/chat/completions" || request.path == "/v1/completions",
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        else { return (request, debugContext, nil) }

        var payload = object
        let routingDecision = routingDecision(
            selectedModel: selectedModel,
            payload: object,
            defaultEndpoint: defaultUpstreamEndpoint()
        )
        let upstreamEndpoint = routingDecision.upstreamEndpoint
        debugContext.routingDecision = routingDecision
        if let selectedModel,
           Self.modeAliases.contains(selectedModel) {
            debugContext.aliasResolution = "\(selectedModel) -> \(routingDecision.upstreamModel)"
            if routingDecision.upstreamModel == activeModel() {
                eventLogger("Provider resolved model alias \(selectedModel) to active model \(routingDecision.upstreamModel)")
            } else {
                eventLogger("Provider resolved model alias \(selectedModel) to upstream model \(routingDecision.upstreamModel)")
            }
        }
        if let selectedAlias = routingDecision.selectedAlias {
            if let fallbackReason = routingDecision.fallbackReason {
                eventLogger("Provider routing fallback for \(selectedAlias): \(fallbackReason)")
            }
            let portText = routingDecision.upstreamEndpoint?.port.map { ", port=\($0)" } ?? ""
            let fallbackText = routingDecision.fallbackReason.map { ", fallback=\($0)" } ?? ""
            eventLogger(
                "Provider routing decision for \(selectedAlias): role=\(routingDecision.inferredRole?.rawValue ?? "none"), capability=\(routingDecision.clientCapability.rawValue), upstream=\(routingDecision.upstreamModel)\(portText)\(fallbackText)"
            )
        }
        guard let upstreamEndpoint else {
            return (request, debugContext, nil)
        }
        payload["model"] = upstreamEndpoint.modelID
        if routingDecision.shouldInjectMetadata,
           debugRecorder?.isEnabledNow == true {
            prependSystemMessage(
                routingDecision.metadataMessage,
                to: &payload
            )
            eventLogger("Provider injected selected model metadata for \(routingDecision.selectedAlias ?? routingDecision.requestedModel ?? "unknown")")
        }
        if let normalizedMessages = normalizedMessages(from: payload["messages"]) {
            payload["messages"] = normalizedMessages
            eventLogger("Provider normalized \(request.method) \(request.path) messages for MLX upstream compatibility")
        }
        if removeToolCallingFields(from: &payload) {
            prependSystemMessage(
                "Tool calls are not available through this local MLX provider. Answer in text instead of calling tools.",
                to: &payload
            )
            eventLogger("Provider removed tool-calling fields for MLX upstream compatibility")
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return (request, debugContext, upstreamEndpoint)
        }
        if upstreamEndpoint.modelID == activeModel() {
            eventLogger("Provider rewrote \(request.method) \(request.path) model to active model \(upstreamEndpoint.modelID)")
        } else {
            let portText = upstreamEndpoint.port.map { " on port \($0)" } ?? ""
            eventLogger("Provider rewrote \(request.method) \(request.path) model to upstream model \(upstreamEndpoint.modelID)\(portText)")
        }

        return (
            ProviderRequest(method: request.method, path: request.path, headers: request.headers, body: body),
            debugContext,
            upstreamEndpoint
        )
    }

    private func routingDecision(
        selectedModel: String?,
        payload: [String: Any],
        defaultEndpoint: ProviderUpstreamEndpoint?
    ) -> ProviderRoutingDecision {
        let selectedAlias = selectedModel.flatMap { Self.modeAliases.contains($0) ? $0 : nil }
        let aliasRole = selectedAlias.flatMap(role(forAlias:))
        let inferredRole: ProviderModelRole?
        if containsPlanningModePrompt(in: payload["messages"]) {
            inferredRole = .plan
        } else {
            inferredRole = aliasRole
        }
        let desiredRoleModel = inferredRole.flatMap { roleAssignmentsProvider().model(for: $0) }
        let selectedEndpoint: ProviderUpstreamEndpoint?
        let fallbackReason: String?
        if let inferredRole, let desiredRoleModel {
            let roleEndpoint = roleEndpointProvider(inferredRole).flatMap { endpoint in
                endpoint.modelID == desiredRoleModel ? endpoint : nil
            }
            if let roleEndpoint {
                selectedEndpoint = roleEndpoint
                fallbackReason = nil
            } else if let defaultEndpoint, defaultEndpoint.modelID == desiredRoleModel {
                selectedEndpoint = defaultEndpoint
                fallbackReason = nil
            } else {
                selectedEndpoint = defaultEndpoint
                fallbackReason = defaultEndpoint == nil ? nil : "role server unavailable; using active model"
            }
        } else if inferredRole != nil, desiredRoleModel == nil {
            selectedEndpoint = defaultEndpoint
            fallbackReason = "no model assigned for inferred role"
        } else {
            selectedEndpoint = defaultEndpoint
            fallbackReason = nil
        }
        return ProviderRoutingDecision(
            requestedModel: selectedModel,
            selectedAlias: selectedAlias,
            inferredRole: inferredRole,
            clientCapability: clientCapability(from: payload["tools"]),
            desiredRoleModel: desiredRoleModel,
            upstreamEndpoint: selectedEndpoint,
            fallbackReason: fallbackReason
        )
    }

    private func role(forAlias alias: String) -> ProviderModelRole? {
        switch alias {
        case "mlx-ask":
            .ask
        case "mlx-plan":
            .plan
        case "mlx-fast":
            .coding
        default:
            nil
        }
    }

    private func clientCapability(from toolsValue: Any?) -> ProviderClientCapability {
        guard let tools = toolsValue as? [[String: Any]], !tools.isEmpty else {
            return .unknown
        }
        let toolNames = tools.compactMap { tool -> String? in
            guard let function = tool["function"] as? [String: Any] else { return nil }
            return function["name"] as? String
        }
        if toolNames.contains(where: { ["write_file", "gradle_sync", "gradle_build"].contains($0) }) {
            return .editBuild
        }
        return .readOnly
    }

    private func containsPlanningModePrompt(in messagesValue: Any?) -> Bool {
        guard let messages = messagesValue as? [[String: Any]] else { return false }
        return messages.contains { message in
            guard let role = message["role"] as? String,
                  role == "developer" || role == "system",
                  let text = normalizedContent(message["content"] ?? "")
            else { return false }
            return text.contains("You are in PLANNING mode") || text.contains("Mode: PLANNING")
        }
    }

    private func removeToolCallingFields(from payload: inout [String: Any]) -> Bool {
        let toolFields = ["tools", "tool_choice", "parallel_tool_calls", "stream_options"]
        var removed = false
        for field in toolFields where payload[field] != nil {
            payload.removeValue(forKey: field)
            removed = true
        }
        return removed
    }

    private func prependSystemMessage(_ text: String, to payload: inout [String: Any]) {
        var messages = payload["messages"] as? [[String: Any]] ?? []
        if let first = messages.first,
           first["role"] as? String == "system",
           let existing = first["content"] as? String {
            messages[0]["content"] = "\(text)\n\n\(existing)"
        } else {
            messages.insert(["role": "system", "content": text], at: 0)
        }
        payload["messages"] = messages
    }

    private func normalizedMessages(from value: Any?) -> [[String: Any]]? {
        guard let messages = value as? [[String: Any]] else { return nil }

        var changed = false
        let normalized = messages.map { message -> [String: Any] in
            var next = message
            if let role = message["role"] as? String,
               role == "developer" || role == "system" {
                next["role"] = "system"
                changed = true
            } else if message["role"] as? String == "tool" {
                next["role"] = "user"
                changed = true
            }
            if let content = message["content"], let text = normalizedContent(content), !(content is String) {
                next["content"] = text
                changed = true
            }
            return next
        }
        let coalesced = coalescedAlternatingMessages(normalized)
        if coalesced.count != normalized.count {
            changed = true
        }
        return changed ? coalesced : nil
    }

    private func coalescedAlternatingMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var systemTexts: [String] = []
        var nonSystemMessages: [[String: Any]] = []

        for message in messages {
            if message["role"] as? String == "system" {
                if let content = message["content"] as? String, !content.isEmpty {
                    systemTexts.append(content)
                }
            } else {
                nonSystemMessages.append(message)
            }
        }

        var result: [[String: Any]] = []
        if !systemTexts.isEmpty {
            result.append(["role": "system", "content": systemTexts.joined(separator: "\n\n")])
        }
        for message in nonSystemMessages {
            var next = message
            let role = next["role"] as? String
            if role != "assistant" {
                next["role"] = "user"
            }
            if let last = result.last,
               last["role"] as? String == next["role"] as? String {
                result[result.count - 1] = mergedMessage(last, next)
            } else {
                result.append(next)
            }
        }
        return result
    }

    private func normalizedContent(_ content: Any) -> String? {
        if let text = content as? String {
            return text
        }
        guard let parts = content as? [[String: Any]] else { return nil }
        return parts.compactMap { part -> String? in
            if let text = part["text"] as? String {
                return text
            }
            if let text = part["content"] as? String {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }

    private func mergedMessage(_ first: [String: Any], _ second: [String: Any]) -> [String: Any] {
        var merged = first
        let firstContent = first["content"] as? String ?? ""
        let secondContent = second["content"] as? String ?? ""
        switch (firstContent.isEmpty, secondContent.isEmpty) {
        case (true, false):
            merged["content"] = secondContent
        case (false, false):
            merged["content"] = "\(firstContent)\n\n\(secondContent)"
        default:
            break
        }
        return merged
    }

    private func sanitizedErrorBody(_ body: Data) -> String {
        guard !body.isEmpty else { return "<empty>" }
        let text = String(data: body, encoding: .utf8) ?? "<\(body.count) non-utf8 bytes>"
        let normalized = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 500
        guard normalized.count > limit else { return normalized }
        return "\(normalized.prefix(limit))..."
    }

    private func requestSummary(from body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return "body=non-json bytes=\(body.count)"
        }

        var parts: [String] = [
            "keys=[\(object.keys.sorted().joined(separator: ","))]"
        ]
        if let model = object["model"] as? String {
            parts.append("model=\(model)")
        }
        if let stream = object["stream"] as? Bool {
            parts.append("stream=\(stream)")
        }
        if let messages = object["messages"] as? [[String: Any]] {
            parts.append("message_count=\(messages.count)")
        }
        if let tools = object["tools"] as? [Any] {
            parts.append("tools=\(tools.count)")
        } else if let tools = object["tools"] {
            parts.append("tools=\(jsonTypeDescription(tools))")
        }
        if let responseFormat = object["response_format"] as? [String: Any] {
            parts.append("response_format_keys=[\(responseFormat.keys.sorted().joined(separator: ","))]")
        }
        return parts.joined(separator: ", ")
    }

    private func jsonTypeDescription(_ value: Any) -> String {
        switch value {
        case is NSNull:
            return "null"
        case is String:
            return "string"
        case is Bool:
            return "bool"
        case is NSNumber:
            return "number"
        case is [Any]:
            return "array"
        case is [String: Any]:
            return "object"
        default:
            return String(describing: type(of: value))
        }
    }

    private func responseFromChatCompletion(_ request: ProviderRequest) async throws -> ProviderResponse {
        guard let responseRequest = try? decodeResponsesRequest(from: request.body) else {
            return json(status: 400, #"{"error":"invalid responses request"}"#)
        }

        let model = defaultUpstreamEndpoint()?.modelID ?? activeModelProvider().flatMap { $0.isEmpty ? nil : $0 } ?? responseRequest.model ?? "local"
        let chatPayload = responseRequest.chatCompletionPayload(model: model)
        let chatBody = try JSONSerialization.data(withJSONObject: chatPayload)
        let chatRequest = ProviderRequest(
            method: "POST",
            path: "/v1/chat/completions",
            headers: request.headers,
            body: chatBody
        )
        let chatResponse = try await proxy(chatRequest, to: defaultUpstreamEndpoint())
        guard chatResponse.status >= 200, chatResponse.status < 300 else {
            return chatResponse
        }

        if responseRequest.stream {
            return streamingResponsesResponse(model: model, chatBody: chatResponse.body)
        }

        let assistantText = assistantText(fromChatCompletionBody: chatResponse.body)
        let payload = responsesPayload(model: model, outputText: assistantText, chatBody: chatResponse.body)
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(#"{"object":"response","status":"completed","output":[]}"#.utf8)
        return ProviderResponse(status: 200, headers: ["content-type": "application/json"], body: data)
    }

    private func decodeResponsesRequest(from body: Data) throws -> ResponsesCompatibilityRequest {
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard let object else { throw ResponsesCompatibilityError.invalidBody }
        return ResponsesCompatibilityRequest(object: object)
    }

    private func assistantText(fromChatCompletionBody body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let firstChoice = choices.first
        else { return "" }

        if let message = firstChoice["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        if let text = firstChoice["text"] as? String {
            return text
        }
        return ""
    }

    private func streamingResponsesResponse(model: String, chatBody: Data) -> ProviderResponse {
        let responseID = "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let messageID = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let createdAt = Int(Date().timeIntervalSince1970)
        let deltas = outputTextDeltas(fromChatCompletionBody: chatBody)
        let outputText = deltas.joined()

        var stream = Data()
        appendEvent(
            name: "response.created",
            payload: [
                "type": "response.created",
                "response": responseEnvelope(id: responseID, model: model, createdAt: createdAt, status: "in_progress", output: [])
            ],
            to: &stream
        )
        appendEvent(
            name: "response.output_item.added",
            payload: [
                "type": "response.output_item.added",
                "output_index": 0,
                "item": [
                    "id": messageID,
                    "type": "message",
                    "status": "in_progress",
                    "role": "assistant",
                    "content": []
                ]
            ],
            to: &stream
        )
        appendEvent(
            name: "response.content_part.added",
            payload: [
                "type": "response.content_part.added",
                "item_id": messageID,
                "output_index": 0,
                "content_index": 0,
                "part": [
                    "type": "output_text",
                    "text": "",
                    "annotations": []
                ]
            ],
            to: &stream
        )
        for delta in deltas where !delta.isEmpty {
            appendEvent(
                name: "response.output_text.delta",
                payload: [
                    "type": "response.output_text.delta",
                    "item_id": messageID,
                    "output_index": 0,
                    "content_index": 0,
                    "delta": delta
                ],
                to: &stream
            )
        }
        let contentPart: [String: Any] = [
            "type": "output_text",
            "text": outputText,
            "annotations": []
        ]
        let outputItem: [String: Any] = [
            "id": messageID,
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [contentPart]
        ]
        appendEvent(
            name: "response.output_text.done",
            payload: [
                "type": "response.output_text.done",
                "item_id": messageID,
                "output_index": 0,
                "content_index": 0,
                "text": outputText
            ],
            to: &stream
        )
        appendEvent(
            name: "response.content_part.done",
            payload: [
                "type": "response.content_part.done",
                "item_id": messageID,
                "output_index": 0,
                "content_index": 0,
                "part": contentPart
            ],
            to: &stream
        )
        appendEvent(
            name: "response.output_item.done",
            payload: [
                "type": "response.output_item.done",
                "output_index": 0,
                "item": outputItem
            ],
            to: &stream
        )
        appendEvent(
            name: "response.completed",
            payload: [
                "type": "response.completed",
                "response": responseEnvelope(
                    id: responseID,
                    model: model,
                    createdAt: createdAt,
                    status: "completed",
                    output: [outputItem],
                    usage: usagePayload(fromChatCompletionBody: chatBody)
                )
            ],
            to: &stream
        )

        return ProviderResponse(status: 200, headers: ["content-type": "text/event-stream"], body: stream)
    }

    private func appendEvent(name: String, payload: [String: Any], to stream: inout Data) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return }
        stream.append(Data("event: \(name)\n".utf8))
        stream.append(Data("data: \(json)\n\n".utf8))
    }

    private func outputTextDeltas(fromChatCompletionBody body: Data) -> [String] {
        if let text = assistantTextIfJSONChatCompletion(from: body) {
            return [text]
        }

        guard let streamText = String(data: body, encoding: .utf8) else { return [] }
        return streamText
            .components(separatedBy: "\n\n")
            .flatMap { block -> [String] in
                block
                    .split(separator: "\n")
                    .compactMap { line -> String? in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { return nil }
                        let payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }
                        return chatCompletionDelta(from: data)
                    }
            }
    }

    private func assistantTextIfJSONChatCompletion(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["choices"] != nil
        else { return nil }
        return assistantText(fromChatCompletionBody: body)
    }

    private func chatCompletionDelta(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let delta = object["delta"] as? String {
            return delta
        }
        guard let choices = object["choices"] as? [[String: Any]],
              let firstChoice = choices.first
        else { return nil }
        if let delta = firstChoice["delta"] as? [String: Any],
           let content = delta["content"] as? String {
            return content
        }
        return firstChoice["text"] as? String
    }

    private func responseEnvelope(
        id: String,
        model: String,
        createdAt: Int,
        status: String,
        output: [[String: Any]],
        usage: [String: Any]? = nil
    ) -> [String: Any] {
        [
            "id": id,
            "object": "response",
            "created_at": createdAt,
            "status": status,
            "error": NSNull(),
            "incomplete_details": NSNull(),
            "model": model,
            "output": output,
            "parallel_tool_calls": true,
            "previous_response_id": NSNull(),
            "tool_choice": "none",
            "tools": [],
            "usage": usage ?? [
                "input_tokens": 0,
                "output_tokens": 0,
                "total_tokens": 0
            ]
        ]
    }

    private func responsesPayload(model: String, outputText: String, chatBody: Data) -> [String: Any] {
        let createdAt = Int(Date().timeIntervalSince1970)
        return [
            "id": "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
            "object": "response",
            "created_at": createdAt,
            "status": "completed",
            "error": NSNull(),
            "incomplete_details": NSNull(),
            "model": model,
            "output": [
                [
                    "id": "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
                    "type": "message",
                    "status": "completed",
                    "role": "assistant",
                    "content": [
                        [
                            "type": "output_text",
                            "text": outputText,
                            "annotations": []
                        ]
                    ]
                ]
            ],
            "parallel_tool_calls": true,
            "previous_response_id": NSNull(),
            "tool_choice": "none",
            "tools": [],
            "usage": usagePayload(fromChatCompletionBody: chatBody)
        ]
    }

    private func usagePayload(fromChatCompletionBody body: Data) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let usage = object["usage"] as? [String: Any]
        else {
            return [
                "input_tokens": 0,
                "output_tokens": 0,
                "total_tokens": 0
            ]
        }

        let inputTokens = usage["prompt_tokens"] as? Int ?? 0
        let outputTokens = usage["completion_tokens"] as? Int ?? 0
        let totalTokens = usage["total_tokens"] as? Int ?? inputTokens + outputTokens
        return [
            "input_tokens": inputTokens,
            "output_tokens": outputTokens,
            "output_tokens_details": [
                "reasoning_tokens": 0
            ],
            "total_tokens": totalTokens
        ]
    }
}

private struct ProviderDebugContext {
    var selectedModel: String?
    var aliasResolution: String?
    var routingDecision: ProviderRoutingDecision?
}

private enum ProviderClientCapability: String {
    case unknown
    case readOnly = "read_only"
    case editBuild = "edit_build"
}

private struct ProviderRoutingDecision {
    var requestedModel: String?
    var selectedAlias: String?
    var inferredRole: ProviderModelRole?
    var clientCapability: ProviderClientCapability
    var desiredRoleModel: String?
    var upstreamEndpoint: ProviderUpstreamEndpoint?
    var fallbackReason: String?

    var upstreamModel: String {
        upstreamEndpoint?.modelID ?? desiredRoleModel ?? requestedModel ?? "local"
    }

    var shouldInjectMetadata: Bool {
        selectedAlias != nil || inferredRole != nil
    }

    var metadataMessage: String {
        let aliasText = selectedAlias ?? requestedModel ?? "none"
        let roleText = inferredRole?.rawValue ?? "none"
        let desiredText = desiredRoleModel ?? "none"
        let fallbackText = fallbackReason ?? "none"
        return [
            "Provider selected model alias: \(aliasText).",
            "Provider inferred role: \(roleText).",
            "Desired role model: \(desiredText).",
            "Actual upstream MLX model: \(upstreamModel).",
            "Fallback reason: \(fallbackText)."
        ].joined(separator: " ")
    }

    var debugPayload: [String: Any] {
        var payload: [String: Any] = [
            "client_capability": clientCapability.rawValue,
            "upstream_model": upstreamModel
        ]
        if let upstreamEndpoint {
            payload["upstream_base_url"] = upstreamEndpoint.baseURL.absoluteString
            if let port = upstreamEndpoint.port {
                payload["upstream_port"] = port
            }
        }
        if let requestedModel {
            payload["requested_model"] = requestedModel
        }
        if let selectedAlias {
            payload["selected_alias"] = selectedAlias
        }
        if let inferredRole {
            payload["inferred_role"] = inferredRole.rawValue
        }
        if let desiredRoleModel {
            payload["desired_role_model"] = desiredRoleModel
        }
        if let fallbackReason {
            payload["fallback_reason"] = fallbackReason
        }
        return payload
    }
}

private struct ProviderUpstreamClientAdapter: ProviderUpstreamProxyClient {
    let upstream: any ProviderUpstreamClient

    func proxy(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint) async throws -> ProviderResponse {
        try await upstream.proxy(request)
    }

    func proxyStream(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint) async throws -> ProviderStreamedResponse {
        try await upstream.proxyStream(request)
    }
}

private enum ResponsesCompatibilityError: Error {
    case invalidBody
}

private struct ResponsesCompatibilityRequest {
    let model: String?
    let messages: [[String: Any]]
    let temperature: Any?
    let topP: Any?
    let maxOutputTokens: Any?
    let stream: Bool

    init(object: [String: Any]) {
        self.model = object["model"] as? String
        self.temperature = object["temperature"]
        self.topP = object["top_p"]
        self.maxOutputTokens = object["max_output_tokens"]
        self.stream = object["stream"] as? Bool ?? false

        var messages: [[String: Any]] = []
        if let instructions = object["instructions"] as? String, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        messages.append(contentsOf: Self.messages(from: object["input"]))
        if messages.isEmpty {
            messages.append(["role": "user", "content": ""])
        }
        self.messages = messages
    }

    func chatCompletionPayload(model: String) -> [String: Any] {
        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream
        ]
        if let temperature {
            payload["temperature"] = temperature
        }
        if let topP {
            payload["top_p"] = topP
        }
        if let maxOutputTokens {
            payload["max_tokens"] = maxOutputTokens
        }
        return payload
    }

    private static func messages(from input: Any?) -> [[String: Any]] {
        if let text = input as? String {
            return [["role": "user", "content": text]]
        }
        if let items = input as? [[String: Any]] {
            return items.compactMap(message)
        }
        return []
    }

    private static func message(from item: [String: Any]) -> [String: Any]? {
        let role = item["role"] as? String ?? "user"
        let contentText = text(from: item["content"])
        return ["role": role, "content": contentText]
    }

    private static func text(from content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { part -> String? in
                if let text = part["text"] as? String {
                    return text
                }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }
}
