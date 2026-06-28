import Foundation
import MLXCore

public struct ProviderRouter: Sendable {
    private static let modeAliases = ["mlx-ask", "mlx-plan", "mlx-coding"]
    private static let legacyModeAliases = ["mlx-fast"]
    private static let acceptedModeAliases = modeAliases + legacyModeAliases

    private let upstream: any ProviderUpstreamProxyClient
    private let legacyUpstream: (any ProviderUpstreamClient)?
    private let activeModelProvider: @Sendable () -> String?
    private let modelMetadataProvider: @Sendable () -> [String: ProviderModelMetadata]
    private let roleAssignmentsProvider: @Sendable () -> ProviderRoleAssignments
    private let generationDefaultsProvider: @Sendable () -> ProviderRoleGenerationDefaults
    private let modeAdviceStrategyProvider: @Sendable () -> ModeAdviceStrategy
    private let defaultEndpointProvider: @Sendable () -> ProviderUpstreamEndpoint?
    private let roleEndpointProvider: @Sendable (ProviderModelRole) -> ProviderUpstreamEndpoint?
    private let modeAdviceTimeoutNanoseconds: UInt64
    private let eventLogger: @Sendable (String) -> Void
    private let debugRecorder: ProviderDebugRecorder?
    // Local provider discovery paths complement the OpenAI-compatible chat routes.
    private let allowedPaths: Set<String> = [
        "/api/chat",
        "/api/generate",
        "/api/ps",
        "/api/show",
        "/api/tags",
        "/api/v0/models",
        "/api/version",
        "/provider/v1/mode-advice",
        "/provider/v1/models",
        "/v1/models",
        "/v1/chat/completions",
        "/v1/completions",
        "/v1/responses"
    ]

    public init(
        upstream: any ProviderUpstreamProxyClient,
        activeModelProvider: @escaping @Sendable () -> String? = { nil },
        modelMetadataProvider: @escaping @Sendable () -> [String: ProviderModelMetadata] = { [:] },
        roleAssignmentsProvider: @escaping @Sendable () -> ProviderRoleAssignments = { ProviderRoleAssignments() },
        generationDefaultsProvider: @escaping @Sendable () -> ProviderRoleGenerationDefaults = { .recommendedDefault },
        modeAdviceStrategyProvider: @escaping @Sendable () -> ModeAdviceStrategy = { .automatic },
        defaultEndpointProvider: @escaping @Sendable () -> ProviderUpstreamEndpoint?,
        roleEndpointProvider: @escaping @Sendable (ProviderModelRole) -> ProviderUpstreamEndpoint?,
        modeAdviceTimeoutNanoseconds: UInt64 = 6_000_000_000,
        eventLogger: @escaping @Sendable (String) -> Void = { _ in },
        debugRecorder: ProviderDebugRecorder? = nil
    ) {
        self.init(
            upstream: upstream,
            legacyUpstream: nil,
            activeModelProvider: activeModelProvider,
            modelMetadataProvider: modelMetadataProvider,
            roleAssignmentsProvider: roleAssignmentsProvider,
            generationDefaultsProvider: generationDefaultsProvider,
            modeAdviceStrategyProvider: modeAdviceStrategyProvider,
            defaultEndpointProvider: defaultEndpointProvider,
            roleEndpointProvider: roleEndpointProvider,
            modeAdviceTimeoutNanoseconds: modeAdviceTimeoutNanoseconds,
            eventLogger: eventLogger,
            debugRecorder: debugRecorder
        )
    }

    public init(
        upstream: any ProviderUpstreamClient,
        activeModelProvider: @escaping @Sendable () -> String? = { nil },
        modelMetadataProvider: @escaping @Sendable () -> [String: ProviderModelMetadata] = { [:] },
        roleAssignmentsProvider: @escaping @Sendable () -> ProviderRoleAssignments = { ProviderRoleAssignments() },
        generationDefaultsProvider: @escaping @Sendable () -> ProviderRoleGenerationDefaults = { .recommendedDefault },
        modeAdviceStrategyProvider: @escaping @Sendable () -> ModeAdviceStrategy = { .automatic },
        modeAdviceTimeoutNanoseconds: UInt64 = 6_000_000_000,
        eventLogger: @escaping @Sendable (String) -> Void = { _ in },
        debugRecorder: ProviderDebugRecorder? = nil
    ) {
        self.init(
            upstream: ProviderUpstreamClientAdapter(upstream: upstream),
            legacyUpstream: upstream,
            activeModelProvider: activeModelProvider,
            modelMetadataProvider: modelMetadataProvider,
            roleAssignmentsProvider: roleAssignmentsProvider,
            generationDefaultsProvider: generationDefaultsProvider,
            modeAdviceStrategyProvider: modeAdviceStrategyProvider,
            defaultEndpointProvider: { nil },
            roleEndpointProvider: { _ in nil },
            modeAdviceTimeoutNanoseconds: modeAdviceTimeoutNanoseconds,
            eventLogger: eventLogger,
            debugRecorder: debugRecorder
        )
    }

    private init(
        upstream: any ProviderUpstreamProxyClient,
        legacyUpstream: (any ProviderUpstreamClient)?,
        activeModelProvider: @escaping @Sendable () -> String?,
        modelMetadataProvider: @escaping @Sendable () -> [String: ProviderModelMetadata],
        roleAssignmentsProvider: @escaping @Sendable () -> ProviderRoleAssignments,
        generationDefaultsProvider: @escaping @Sendable () -> ProviderRoleGenerationDefaults,
        modeAdviceStrategyProvider: @escaping @Sendable () -> ModeAdviceStrategy,
        defaultEndpointProvider: @escaping @Sendable () -> ProviderUpstreamEndpoint?,
        roleEndpointProvider: @escaping @Sendable (ProviderModelRole) -> ProviderUpstreamEndpoint?,
        modeAdviceTimeoutNanoseconds: UInt64,
        eventLogger: @escaping @Sendable (String) -> Void,
        debugRecorder: ProviderDebugRecorder?
    ) {
        self.upstream = upstream
        self.legacyUpstream = legacyUpstream
        self.activeModelProvider = activeModelProvider
        self.modelMetadataProvider = modelMetadataProvider
        self.roleAssignmentsProvider = roleAssignmentsProvider
        self.generationDefaultsProvider = generationDefaultsProvider
        self.modeAdviceStrategyProvider = modeAdviceStrategyProvider
        self.defaultEndpointProvider = defaultEndpointProvider
        self.roleEndpointProvider = roleEndpointProvider
        self.modeAdviceTimeoutNanoseconds = modeAdviceTimeoutNanoseconds
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
                routingDecision: context.routingDecision?.debugPayload,
                modeAdvice: context.modeAdvice?.debugPayload
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
                            routingDecision: context.routingDecision?.debugPayload,
                            modeAdvice: context.modeAdvice?.debugPayload
                        )
                        continuation.finish()
                    } catch {
                        logStreamErrorIfNeeded(response: response, body: body, upstreamRequest: upstreamRequest)
                        debugRecorder.record(
                            request: request,
                            response: ProviderResponse(status: response.status, headers: response.headers, body: body),
                            selectedModel: context.selectedModel,
                            aliasResolution: context.aliasResolution,
                            routingDecision: context.routingDecision?.debugPayload,
                            modeAdvice: context.modeAdvice?.debugPayload
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

        if request.method == "GET", let requestedModel = providerMetadataModelID(from: request.path) {
            eventLogger("Provider served GET /provider/v1/models/\(requestedModel)")
            return finish(androidStudioV0ModelResponse(for: requestedModel))
        }

        if request.method == "GET", let requestedModel = androidStudioV0ModelID(from: request.path) {
            eventLogger("Provider served legacy provider metadata GET /api/v0/models/\(requestedModel)")
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
            eventLogger("Provider served legacy provider metadata GET /api/v0/models")
            return finish(androidStudioV0ModelsResponse())
        }

        if request.method == "GET", request.path == "/provider/v1/models" {
            eventLogger("Provider served GET /provider/v1/models")
            return finish(androidStudioV0ModelsResponse())
        }

        if request.method == "POST", request.path == "/provider/v1/mode-advice" {
            eventLogger("Provider received POST /provider/v1/mode-advice")
            let result = try await modeAdviceResponse(request)
            return finish(result.response, context: result.debugContext)
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
            let result = try await androidStudioChatResponse(request)
            return finish(result.response, context: result.debugContext)
        }

        if request.method == "POST", request.path == "/api/generate" {
            eventLogger("Provider translated Android Studio compatibility POST /api/generate to chat completions")
            let result = try await androidStudioGenerateResponse(request)
            return finish(result.response, context: result.debugContext)
        }

        if request.method == "POST", request.path == "/v1/responses" {
            eventLogger("Provider translated POST /v1/responses to chat completions")
            let result = try await responseFromChatCompletion(request)
            return finish(result.response, context: result.debugContext)
        }

        let usageEventsRequested = shouldEmitMLXUsageEvents(for: request)
        let routed = await requestWithSelectedUpstreamIfAvailable(request)
        let proxiedRequest = routed.request
        let upstreamEndpoint = routed.upstreamEndpoint ?? defaultUpstreamEndpoint()
        do {
            if shouldStream(proxiedRequest) {
                var response = try await proxyStream(proxiedRequest, to: upstreamEndpoint)
                if usageEventsRequested, proxiedRequest.path == "/v1/chat/completions" {
                    response = responseWithMLXUsageEvents(
                        response,
                        model: routed.debugContext.routingDecision?.upstreamModel
                            ?? selectedModel(from: proxiedRequest.body)
                            ?? activeModel()
                            ?? "local"
                    )
                }
                eventLogger("Provider streaming \(request.method) \(request.path) from upstream with status \(response.status)")
                return finishStream(response, context: routed.debugContext, upstreamRequest: proxiedRequest)
            }

            let upstreamResponse = try await proxy(proxiedRequest, to: upstreamEndpoint)
            let response = normalizedChatCompletionResponseIfNeeded(upstreamResponse, for: proxiedRequest)
            eventLogger("Provider proxied \(request.method) \(request.path) to upstream with status \(response.status)")
            if response.status >= 400 {
                eventLogger("Provider upstream error body for \(request.method) \(request.path) status \(response.status): \(sanitizedErrorBody(response.body))")
                eventLogger("Provider upstream request summary for \(request.method) \(request.path): \(requestSummary(from: proxiedRequest.body))")
            }
            return finish(response, context: routed.debugContext)
        } catch {
            eventLogger("Provider upstream request failed for \(request.method) \(request.path): \(error.localizedDescription)")
            eventLogger("Provider upstream request summary for \(request.method) \(request.path): \(requestSummary(from: proxiedRequest.body))")
            return finish(json(status: 502, #"{"error":"bad gateway"}"#), context: routed.debugContext)
        }
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
        if path == "/provider/v1/models" || path.hasPrefix("/provider/v1/models/") {
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

    private func shouldEmitMLXUsageEvents(for request: ProviderRequest) -> Bool {
        if request.header("x-mlx-usage-events")?.lowercased() == "true" {
            return true
        }

        guard request.method == "POST",
              request.path == "/v1/chat/completions",
              let object = decodedObject(from: request.body),
              let streamOptions = object["stream_options"] as? [String: Any]
        else { return false }

        return streamOptions["include_usage"] as? Bool == true
    }

    private func activeModel() -> String? {
        activeModelProvider().flatMap { $0.isEmpty ? nil : $0 }
    }

    private func defaultUpstreamEndpoint() -> ProviderUpstreamEndpoint? {
        defaultEndpointProvider()
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

    private func normalizedChatCompletionResponseIfNeeded(
        _ response: ProviderResponse,
        for request: ProviderRequest
    ) -> ProviderResponse {
        guard request.path == "/v1/chat/completions",
              response.status >= 200,
              response.status < 300,
              let body = normalizedChatCompletionBody(from: response.body)
        else {
            return response
        }
        return ProviderResponse(status: response.status, headers: response.headers, body: body)
    }

    private func normalizedChatCompletionBody(from body: Data) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              var choices = object["choices"] as? [[String: Any]]
        else { return nil }

        var changed = false
        for index in choices.indices {
            guard var message = choices[index]["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  let channelContent = normalizedChannelContent(from: content, isAssistant: true)
            else {
                continue
            }

            message["content"] = channelContent.content
            if let thinking = channelContent.thinking, !thinking.isEmpty {
                if let existingReasoning = message["reasoning"] as? String,
                   !existingReasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    message["reasoning"] = "\(existingReasoning)\n\n\(thinking)"
                } else {
                    message["reasoning"] = thinking
                }
            }
            choices[index]["message"] = message
            changed = true
        }

        guard changed else { return nil }
        object["choices"] = choices
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func advertisedModels() -> [String] {
        guard let activeModel = activeModel() else { return [] }
        guard modelMetadata(for: activeModel).state == .loaded else { return [] }
        return (Self.modeAliases + [activeModel]).reduce(into: []) { models, model in
            if !models.contains(model) {
                models.append(model)
            }
        }
    }

    private func isAdvertisedModel(_ model: String) -> Bool {
        Self.acceptedModeAliases.contains(model) || advertisedModels().contains(model)
    }

    private func androidStudioV0AdvertisedModels() -> [String] {
        let metadata = modelMetadataProvider()
        let activeModels = activeModel().map { Self.modeAliases + [$0] } ?? []
        return metadata.keys.sorted().reduce(into: activeModels) { models, model in
            guard metadata[model]?.state != .loaded else { return }
            if !models.contains(model) {
                models.append(model)
            }
        }
    }

    private func isAndroidStudioV0AdvertisedModel(_ model: String) -> Bool {
        Self.acceptedModeAliases.contains(model) || androidStudioV0AdvertisedModels().contains(model)
    }

    private func aliasResolution(for selectedModel: String?) -> String? {
        guard let selectedModel,
              Self.acceptedModeAliases.contains(selectedModel),
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
            "data": models.map(modelPayload)
        ]
        return jsonResponse(payload)
    }

    private func androidStudioV0ModelsResponse() -> ProviderResponse {
        let models = androidStudioV0AdvertisedModels()
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
        guard isAndroidStudioV0AdvertisedModel(requestedModel) else {
            return json(status: 404, #"{"error":"not found"}"#)
        }

        return jsonResponse(modelPayload(requestedModel))
    }

    private func androidStudioV0ModelPayload(_ model: String) -> [String: Any] {
        modelPayload(model)
    }

    private func modelPayload(_ model: String) -> [String: Any] {
        let details = modelDetails(for: model)
        let metadata = details.metadata
        let metadataModel = details.metadataModel
        let owner = publisher(for: metadataModel)
        var payload: [String: Any] = [
            "id": model,
            "object": "model",
            "created": 0,
            "owned_by": owner,
            "type": "llm",
            "publisher": owner,
            "arch": architecture(for: metadataModel),
            "compatibility_type": "mlx",
            "generation_type": metadata.generationType.rawValue,
            "model_family": metadata.modelFamily.rawValue,
            "quantization": quantization(for: metadataModel),
            "state": metadata.state.rawValue,
            "runtime": metadata.runtime.rawValue,
            "supports_streaming": metadata.supportsStreaming,
            "supported_generation_modes": metadata.supportedGenerationModes.map(\.rawValue)
        ]
        if let modelType = metadata.modelType {
            payload["model_type"] = modelType
        }
        if let maxContextLength = metadata.maxContextLength {
            payload["max_context_length"] = maxContextLength
        }
        if let maxOutputTokens = metadata.maxOutputTokens {
            payload["max_output_tokens"] = maxOutputTokens
        }
        if metadataModel != model {
            payload["resolved_model"] = metadataModel
        }
        if let role = details.role {
            payload["role"] = role.rawValue
        }
        if let routingMetadata = aliasRoutingMetadata(for: model) {
            payload["effective_model"] = routingMetadata.decision.upstreamModel
            payload["routing_state"] = routingMetadata.state
            if let port = routingMetadata.decision.upstreamEndpoint?.port {
                payload["effective_port"] = port
            }
            if let fallbackReason = routingMetadata.decision.fallbackReason {
                payload["fallback_reason"] = fallbackReason
            }
        }
        if metadata.state != .loaded, let reason = metadata.unavailableReason {
            payload["reason"] = reason
            switch metadata.state {
            case .loaded:
                break
            case .unsupported:
                payload["unsupported_reason"] = reason
            case .notInstalled:
                payload["not_installed_reason"] = reason
            }
        }
        return payload
    }

    private func aliasRoutingMetadata(for model: String) -> (
        decision: ProviderRoutingDecision,
        state: String
    )? {
        guard Self.acceptedModeAliases.contains(model) else { return nil }
        let decision = routingDecision(
            selectedModel: model,
            payload: [:],
            activeModel: activeModel(),
            defaultEndpoint: defaultUpstreamEndpoint(),
            canProxyWithoutEndpoint: legacyUpstream != nil
        )
        return (decision, routingState(for: decision))
    }

    private func routingState(for decision: ProviderRoutingDecision) -> String {
        guard let fallbackReason = decision.fallbackReason else {
            return decision.upstreamEndpoint == nil ? "unavailable" : "role_endpoint"
        }
        if fallbackReason.contains("using active model") {
            return "active_model_fallback"
        }
        if fallbackReason.contains("using default endpoint") {
            return "default_endpoint_fallback"
        }
        return "unavailable"
    }

    private func modelMetadata(for model: String) -> ProviderModelMetadata {
        modelDetails(for: model).metadata
    }

    private func modelDetails(for model: String) -> (
        metadata: ProviderModelMetadata,
        metadataModel: String,
        role: ProviderModelRole?
    ) {
        if Self.acceptedModeAliases.contains(model),
           let role = role(forAlias: model),
           let roleModel = roleAssignmentsProvider().model(for: role) {
            return (
                modelMetadataProvider()[roleModel] ?? .inferred(modelID: roleModel),
                roleModel,
                role
            )
        }
        if Self.acceptedModeAliases.contains(model), let activeModel = activeModel() {
            return (
                modelMetadataProvider()[activeModel] ?? .inferred(modelID: activeModel),
                activeModel,
                role(forAlias: model)
            )
        }
        return (modelMetadataProvider()[model] ?? .inferred(modelID: model), model, nil)
    }

    private func publisher(for model: String) -> String {
        model.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
    }

    private func architecture(for model: String) -> String {
        let lowercased = model.lowercased()
        if lowercased.contains("gpt-oss") { return "gpt-oss" }
        if lowercased.contains("devstral") { return "devstral" }
        if lowercased.contains("qwen") { return "qwen" }
        if lowercased.contains("deepseek") { return "deepseek" }
        if lowercased.contains("llama") { return "llama" }
        if lowercased.contains("gemma") { return "gemma" }
        if lowercased.contains("mistral") { return "mistral" }
        return "mlx"
    }

    private func quantization(for model: String) -> String {
        let lowercased = model.lowercased()
        if lowercased.contains("mxfp4-q8") { return "MXFP4-Q8" }
        if lowercased.contains("mxfp4") { return "MXFP4" }
        if lowercased.contains("q8") { return "Q8" }
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

    private func androidStudioChatResponse(_ request: ProviderRequest) async throws -> (
        response: ProviderResponse,
        debugContext: ProviderDebugContext
    ) {
        guard let object = decodedObject(from: request.body) else {
            return (json(status: 400, #"{"error":"invalid chat request"}"#), debugContext(for: request))
        }

        let requestedModel = object["model"] as? String
        let model = requestedModel ?? activeModel() ?? "local"
        let messages = object["messages"] as? [[String: Any]] ?? []
        let stream = object["stream"] as? Bool ?? true
        let chatResult = try await proxyChatCompletion(model: model, messages: messages, stream: stream, headers: request.headers)
        let chatResponse = chatResult.response
        guard chatResponse.status >= 200, chatResponse.status < 300 else {
            return (chatResponse, chatResult.debugContext)
        }

        if stream {
            return (
                androidStudioStreamingChatResponse(model: chatResult.model, chatBody: chatResponse.body),
                chatResult.debugContext
            )
        }

        let text = assistantText(fromChatCompletionBody: chatResponse.body)
        let payload: [String: Any] = [
            "model": chatResult.model,
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
        return (jsonResponse(payload), chatResult.debugContext)
    }

    private func androidStudioGenerateResponse(_ request: ProviderRequest) async throws -> (
        response: ProviderResponse,
        debugContext: ProviderDebugContext
    ) {
        guard let object = decodedObject(from: request.body) else {
            return (json(status: 400, #"{"error":"invalid generate request"}"#), debugContext(for: request))
        }

        let requestedModel = object["model"] as? String
        let model = requestedModel ?? activeModel() ?? "local"
        let prompt = object["prompt"] as? String ?? ""
        let stream = object["stream"] as? Bool ?? true
        let chatResult = try await proxyChatCompletion(
            model: model,
            messages: [["role": "user", "content": prompt]],
            stream: stream,
            headers: request.headers
        )
        let chatResponse = chatResult.response
        guard chatResponse.status >= 200, chatResponse.status < 300 else {
            return (chatResponse, chatResult.debugContext)
        }

        if stream {
            return (
                androidStudioStreamingGenerateResponse(model: chatResult.model, chatBody: chatResponse.body),
                chatResult.debugContext
            )
        }

        let text = assistantText(fromChatCompletionBody: chatResponse.body)
        let payload: [String: Any] = [
            "model": chatResult.model,
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
        return (jsonResponse(payload), chatResult.debugContext)
    }

    private func proxyChatCompletion(
        model: String,
        messages: [[String: Any]],
        stream: Bool,
        headers: [String: String]
    ) async throws -> (response: ProviderResponse, model: String, debugContext: ProviderDebugContext) {
        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream
        ]
        return try await proxyChatCompletion(payload: payload, headers: headers, fallbackModel: model)
    }

    private func proxyChatCompletion(
        payload: [String: Any],
        headers: [String: String],
        fallbackModel: String
    ) async throws -> (response: ProviderResponse, model: String, debugContext: ProviderDebugContext) {
        let chatBody = try JSONSerialization.data(withJSONObject: payload)
        let request = ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: headers, body: chatBody)
        let routed = await requestWithSelectedUpstreamIfAvailable(request)
        let selectedModel = selectedModel(from: routed.request.body) ?? fallbackModel
        let response = try await proxy(routed.request, to: routed.upstreamEndpoint ?? defaultUpstreamEndpoint())
        return (response, selectedModel, routed.debugContext)
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

    private func providerMetadataModelID(from path: String) -> String? {
        let prefix = "/provider/v1/models/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        let encodedModel = String(path.dropFirst(prefix.count))
        return encodedModel.removingPercentEncoding ?? encodedModel
    }

    private func modelResponse(for requestedModel: String) -> ProviderResponse {
        guard isAdvertisedModel(requestedModel) else {
            return json(status: 404, #"{"error":"not found"}"#)
        }

        return jsonResponse(modelPayload(requestedModel))
    }

    private func requestWithSelectedUpstreamIfAvailable(_ request: ProviderRequest) async -> (
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
        let activeModel = activeModel()
        let modeAdvice = await routingModeAdvice(
            selectedModel: selectedModel,
            messagesValue: object["messages"]
        )
        let routingDecision = routingDecision(
            selectedModel: selectedModel,
            payload: object,
            activeModel: activeModel,
            defaultEndpoint: defaultUpstreamEndpoint(),
            canProxyWithoutEndpoint: legacyUpstream != nil,
            modeAdviceRole: modeAdvice.role
        )
        let upstreamEndpoint = routingDecision.upstreamEndpoint
        debugContext.routingDecision = routingDecision
        debugContext.modeAdvice = modeAdvice.advice
        if let selectedModel,
           Self.acceptedModeAliases.contains(selectedModel) {
            debugContext.aliasResolution = "\(selectedModel) -> \(routingDecision.upstreamModel)"
            if routingDecision.upstreamModel == activeModel {
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
        if let rewrittenModel = routingDecision.rewrittenModel {
            payload["model"] = rewrittenModel
        }
        if let inferredRole = routingDecision.inferredRole {
            applyGenerationDefaults(for: inferredRole, to: &payload)
        }
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
        _ = removeStreamOptions(from: &payload)
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
        if let upstreamEndpoint {
            if upstreamEndpoint.modelID == activeModel {
                eventLogger("Provider rewrote \(request.method) \(request.path) model to active model \(upstreamEndpoint.modelID)")
            } else {
                let portText = upstreamEndpoint.port.map { " on port \($0)" } ?? ""
                eventLogger("Provider rewrote \(request.method) \(request.path) model to upstream model \(upstreamEndpoint.modelID)\(portText)")
            }
        } else if let rewrittenModel = routingDecision.rewrittenModel, rewrittenModel == activeModel {
            eventLogger("Provider rewrote \(request.method) \(request.path) model to active model \(rewrittenModel)")
        }

        return (
            ProviderRequest(method: request.method, path: request.path, headers: request.headers, body: body),
            debugContext,
            upstreamEndpoint
        )
    }

    private func applyGenerationDefaults(for role: ProviderModelRole, to payload: inout [String: Any]) {
        let settings = generationDefaultsProvider().settings(for: role).validated()
        if payload["temperature"] == nil {
            payload["temperature"] = settings.temperature
        }
        if payload["top_p"] == nil {
            payload["top_p"] = settings.topP
        }
        if payload["max_tokens"] == nil {
            payload["max_tokens"] = settings.maxTokens
        }
    }

    private func modeAdviceResponse(_ request: ProviderRequest) async throws -> (
        response: ProviderResponse,
        debugContext: ProviderDebugContext
    ) {
        var debugContext = debugContext(for: request)
        guard let object = decodedObject(from: request.body),
              let input = object["input"] as? String,
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return (json(status: 400, #"{"error":"input is required"}"#), debugContext)
        }

        let selectedModel = object["selected_model"] as? String
        let currentMode = mode(forSelectedModel: selectedModel)
        let advice = await classifyModeAdviceWithTimeout(input: input, currentMode: currentMode)
        debugContext.selectedModel = selectedModel
        debugContext.modeAdvice = advice
        if advice.suggestedMode == .unknown {
            eventLogger("Provider mode advice unavailable: \(advice.reason)")
        } else {
            eventLogger(
                "Provider mode advice: suggested=\(advice.suggestedMode.rawValue), confidence=\(advice.confidence), current=\(advice.currentMode ?? "none"), switch=\(advice.shouldSuggestSwitch)"
            )
        }
        return (jsonResponse(advice.responsePayload), debugContext)
    }

    private func classifyModeAdviceWithTimeout(
        input: String,
        currentMode: String?
    ) async -> ProviderModeAdvice {
        await withTaskGroup(of: ProviderModeAdvice.self) { group in
            group.addTask {
                await classifyModeAdvice(input: input, currentMode: currentMode)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: modeAdviceTimeoutNanoseconds)
                return ProviderModeAdvice.unknown(
                    currentMode: currentMode,
                    reason: "Mode advice timed out."
                )
            }
            let advice = await group.next() ?? ProviderModeAdvice.unknown(
                currentMode: currentMode,
                reason: "Mode advice timed out."
            )
            group.cancelAll()
            return advice
        }
    }

    private func classifyModeAdvice(
        input: String,
        currentMode: String?
    ) async -> ProviderModeAdvice {
        guard let endpoint = modeAdviceAskEndpoint(),
              let askModel = roleAssignmentsProvider().ask
        else {
            return ProviderModeAdvice.unknown(
                currentMode: currentMode,
                reason: "Ask role endpoint is unavailable."
            )
        }

        let payload: [String: Any] = [
            "model": askModel,
            "temperature": 0,
            "max_tokens": 128,
            "stream": false,
            "messages": [
                [
                    "role": "system",
                    "content": modeAdviceClassifierPrompt
                ],
                [
                    "role": "user",
                    "content": input
                ]
            ]
        ]

        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let classifierRequest = ProviderRequest(method: "POST", path: "/v1/chat/completions", headers: [:], body: body)
            let response = try await proxy(classifierRequest, to: endpoint)
            guard response.status >= 200, response.status < 300 else {
                return ProviderModeAdvice.unknown(
                    currentMode: currentMode,
                    reason: "Classifier upstream returned status \(response.status)."
                )
            }
            let text = assistantText(fromChatCompletionBody: response.body)
            guard let classified = ProviderModeAdvice.parse(
                classifierOutput: text,
                currentMode: currentMode
            ) else {
                return ProviderModeAdvice.unknown(
                    currentMode: currentMode,
                    reason: "Classifier response was not valid mode advice."
                )
            }
            return classified
        } catch {
            return ProviderModeAdvice.unknown(
                currentMode: currentMode,
                reason: "Classifier request failed: \(error.localizedDescription)"
            )
        }
    }

    private var modeAdviceClassifierPrompt: String {
        """
        Classify the user's request for a local coding assistant UI.
        Return JSON only with keys mode, confidence, reason.
        mode must be one of ask, plan, coding, unknown.
        Use plan for architecture, sequencing, task decomposition, risk analysis, or requests to plan.
        Use coding for writing, editing, fixing, refactoring, or testing code.
        Use ask for explanations, questions, summaries, and lightweight troubleshooting.
        Use unknown when unsure.
        """
    }

    private func modeAdviceAskEndpoint() -> ProviderUpstreamEndpoint? {
        guard let askModel = roleAssignmentsProvider().ask else { return nil }
        if let endpoint = roleEndpointProvider(.ask), endpoint.modelID == askModel {
            return endpoint
        }
        if let defaultEndpoint = defaultUpstreamEndpoint(), defaultEndpoint.modelID == askModel {
            return defaultEndpoint
        }
        return nil
    }

    private func mode(forSelectedModel selectedModel: String?) -> String? {
        guard let selectedModel else { return nil }
        if let role = role(forAlias: selectedModel) {
            return role.rawValue
        }
        return nil
    }

    private func routingDecision(
        selectedModel: String?,
        payload: [String: Any],
        activeModel: String?,
        defaultEndpoint: ProviderUpstreamEndpoint?,
        canProxyWithoutEndpoint: Bool,
        modeAdviceRole: ProviderModelRole? = nil
    ) -> ProviderRoutingDecision {
        func fallbackReasonForUnavailableRoleEndpoint(using defaultEndpoint: ProviderUpstreamEndpoint?) -> String {
            guard let defaultEndpoint else {
                return "no upstream endpoint available"
            }
            if defaultEndpoint.modelID == activeModel {
                return "role server unavailable; using active model"
            }
            return "role server unavailable; using default endpoint"
        }

        let selectedAlias = selectedModel.flatMap { Self.acceptedModeAliases.contains($0) ? $0 : nil }
        let aliasRole = selectedAlias.flatMap(role(forAlias:))
        let inferredRole: ProviderModelRole?
        if let modeAdviceRole {
            inferredRole = modeAdviceRole
        } else if containsPlanningModePrompt(in: payload["messages"]) {
            inferredRole = .plan
        } else {
            inferredRole = aliasRole
        }
        let desiredRoleModel = inferredRole.flatMap { roleAssignmentsProvider().model(for: $0) }
        let selectedEndpoint: ProviderUpstreamEndpoint?
        let upstreamModel: String
        let rewrittenModel: String?
        let fallbackReason: String?
        if let inferredRole, let desiredRoleModel {
            let roleEndpoint = roleEndpointProvider(inferredRole).flatMap { endpoint in
                endpoint.modelID == desiredRoleModel ? endpoint : nil
            }
            if let roleEndpoint {
                selectedEndpoint = roleEndpoint
                upstreamModel = roleEndpoint.modelID
                rewrittenModel = roleEndpoint.modelID
                fallbackReason = nil
            } else if let defaultEndpoint, defaultEndpoint.modelID == desiredRoleModel {
                selectedEndpoint = defaultEndpoint
                upstreamModel = defaultEndpoint.modelID
                rewrittenModel = defaultEndpoint.modelID
                fallbackReason = nil
            } else if canProxyWithoutEndpoint, activeModel == desiredRoleModel, let activeModel {
                selectedEndpoint = nil
                upstreamModel = activeModel
                rewrittenModel = activeModel
                fallbackReason = nil
            } else if canProxyWithoutEndpoint, let activeModel {
                selectedEndpoint = nil
                upstreamModel = activeModel
                rewrittenModel = activeModel
                fallbackReason = "role server unavailable; using active model"
            } else {
                selectedEndpoint = defaultEndpoint
                upstreamModel = defaultEndpoint?.modelID ?? activeModel ?? desiredRoleModel
                rewrittenModel = defaultEndpoint?.modelID
                fallbackReason = fallbackReasonForUnavailableRoleEndpoint(using: defaultEndpoint)
            }
        } else if inferredRole != nil, desiredRoleModel == nil {
            if let defaultEndpoint {
                selectedEndpoint = defaultEndpoint
                upstreamModel = defaultEndpoint.modelID
                rewrittenModel = defaultEndpoint.modelID
                fallbackReason = "no model assigned for inferred role"
            } else if canProxyWithoutEndpoint, let activeModel {
                selectedEndpoint = nil
                upstreamModel = activeModel
                rewrittenModel = activeModel
                fallbackReason = "no model assigned for inferred role"
            } else {
                selectedEndpoint = nil
                upstreamModel = activeModel ?? selectedModel ?? "local"
                rewrittenModel = nil
                fallbackReason = "no upstream endpoint available"
            }
        } else {
            if let defaultEndpoint {
                selectedEndpoint = defaultEndpoint
                upstreamModel = defaultEndpoint.modelID
                rewrittenModel = defaultEndpoint.modelID
                fallbackReason = nil
            } else if canProxyWithoutEndpoint, let activeModel {
                selectedEndpoint = nil
                upstreamModel = activeModel
                rewrittenModel = activeModel
                fallbackReason = nil
            } else {
                selectedEndpoint = nil
                upstreamModel = activeModel ?? selectedModel ?? "local"
                rewrittenModel = nil
                fallbackReason = "no upstream endpoint available"
            }
        }
        return ProviderRoutingDecision(
            requestedModel: selectedModel,
            selectedAlias: selectedAlias,
            inferredRole: inferredRole,
            clientCapability: clientCapability(from: payload["tools"]),
            desiredRoleModel: desiredRoleModel,
            upstreamModel: upstreamModel,
            rewrittenModel: rewrittenModel,
            upstreamEndpoint: selectedEndpoint,
            fallbackReason: fallbackReason
        )
    }

    private func routingModeAdvice(
        selectedModel: String?,
        messagesValue: Any?
    ) async -> (role: ProviderModelRole?, advice: ProviderModeAdvice?) {
        guard let selectedModel,
              Self.acceptedModeAliases.contains(selectedModel),
              let currentMode = mode(forSelectedModel: selectedModel),
              currentMode != ProviderModelRole.plan.rawValue
        else { return (nil, nil) }

        let strategy = modeAdviceStrategyProvider()
        if strategy == .disabled {
            return (nil, nil)
        }

        let heuristicRole: ProviderModelRole? = containsPlanningModePrompt(in: messagesValue) ? .plan : nil
        if strategy == .heuristic {
            return (heuristicRole, nil)
        }

        if let input = modeAdviceInput(from: messagesValue) {
            let advice = await classifyModeAdviceWithTimeout(input: input, currentMode: currentMode)
            if advice.suggestedMode == .unknown {
                eventLogger("Provider routing mode advice unavailable: \(advice.reason)")
            } else {
                eventLogger(
                    "Provider routing mode advice: suggested=\(advice.suggestedMode.rawValue), confidence=\(advice.confidence), current=\(advice.currentMode ?? "none")"
                )
            }
            if advice.suggestedMode == .plan,
               advice.confidence >= ProviderModeAdvice.switchConfidenceThreshold {
                return (.plan, advice)
            }
            if strategy == .model {
                return (nil, advice)
            }
            return (heuristicRole, advice)
        }

        return (heuristicRole, nil)
    }

    private func role(forAlias alias: String) -> ProviderModelRole? {
        switch alias {
        case "mlx-ask":
            .ask
        case "mlx-plan":
            .plan
        case "mlx-coding", "mlx-fast":
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
            let lowercased = text.lowercased()
            return lowercased.contains("planning mode")
                || lowercased.contains("plan mode")
                || lowercased.contains("mode: planning")
                || lowercased.contains("mode: plan")
        }
    }

    private func modeAdviceInput(from messagesValue: Any?) -> String? {
        guard let messages = messagesValue as? [[String: Any]] else { return nil }
        let texts = messages.compactMap { message -> String? in
            guard let role = message["role"] as? String,
                  role == "developer" || role == "system" || role == "user",
                  let text = normalizedContent(message["content"] ?? "")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return nil }
            return "\(role): \(text)"
        }
        let input = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return input.isEmpty ? nil : input
    }

    private func removeStreamOptions(from payload: inout [String: Any]) -> Bool {
        payload.removeValue(forKey: "stream_options") != nil
    }

    private func removeToolCallingFields(from payload: inout [String: Any]) -> Bool {
        let toolFields = ["tools", "tool_choice", "parallel_tool_calls"]
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
            if let content = message["content"], let text = normalizedContent(content) {
                if !(content is String) {
                    next["content"] = text
                    changed = true
                }
                if let channelContent = normalizedChannelContent(
                    from: text,
                    isAssistant: next["role"] as? String == "assistant"
                ) {
                    next["content"] = channelContent.content
                    if let thinking = channelContent.thinking, !thinking.isEmpty {
                        next["thinking"] = thinking
                    } else {
                        next.removeValue(forKey: "thinking")
                    }
                    changed = true
                }
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

    private func normalizedChannelContent(
        from text: String,
        isAssistant: Bool
    ) -> NormalizedChannelContent? {
        guard text.contains("<|channel|>") || text.contains("<|message|>") || text.contains("<|end|>") else {
            return nil
        }
        let segments = channelMarkedSegments(from: text)
        if isAssistant {
            let finalTexts = segments
                .filter { $0.channel == "final" || ($0.channel != "analysis" && $0.channel != nil) || $0.channel == nil }
                .map(\.text)
            let thinkingTexts = segments
                .filter { $0.channel == "analysis" }
                .map(\.text)
            return NormalizedChannelContent(
                content: joinedMessageText(finalTexts),
                thinking: joinedMessageText(thinkingTexts)
            )
        }
        return NormalizedChannelContent(
            content: joinedMessageText(segments.map(\.text)),
            thinking: nil
        )
    }

    private func channelMarkedSegments(from text: String) -> [ChannelMarkedSegment] {
        var segments: [ChannelMarkedSegment] = []
        var cursor = text.startIndex

        func appendPlain(_ substring: Substring) {
            let cleaned = cleanedMarkerText(String(substring))
            guard !cleaned.isEmpty else { return }
            segments.append(ChannelMarkedSegment(channel: nil, text: cleaned))
        }

        while let channelRange = text[cursor...].range(of: "<|channel|>") {
            appendPlain(text[cursor..<channelRange.lowerBound])
            let channelStart = channelRange.upperBound
            guard let messageRange = text[channelStart...].range(of: "<|message|>") else {
                appendPlain(text[channelRange.lowerBound...])
                cursor = text.endIndex
                break
            }
            let channel = String(text[channelStart..<messageRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let messageStart = messageRange.upperBound
            let messageText: String
            if let endRange = text[messageStart...].range(of: "<|end|>") {
                messageText = String(text[messageStart..<endRange.lowerBound])
                cursor = endRange.upperBound
            } else {
                messageText = String(text[messageStart...])
                cursor = text.endIndex
            }
            let cleaned = cleanedMarkerText(messageText)
            if !cleaned.isEmpty {
                segments.append(ChannelMarkedSegment(channel: channel, text: cleaned))
            }
        }
        appendPlain(text[cursor...])
        return segments
    }

    private func cleanedMarkerText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<|start|>assistant", with: "")
            .replacingOccurrences(of: "<|start|>", with: "")
            .replacingOccurrences(of: "<|channel|>", with: "")
            .replacingOccurrences(of: "<|message|>", with: "")
            .replacingOccurrences(of: "<|end|>", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func joinedMessageText(_ texts: [String]) -> String {
        texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
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
        let firstThinking = first["thinking"] as? String ?? ""
        let secondThinking = second["thinking"] as? String ?? ""
        switch (firstThinking.isEmpty, secondThinking.isEmpty) {
        case (true, false):
            merged["thinking"] = secondThinking
        case (false, false):
            merged["thinking"] = "\(firstThinking)\n\n\(secondThinking)"
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

    private func responseFromChatCompletion(_ request: ProviderRequest) async throws -> (
        response: ProviderResponse,
        debugContext: ProviderDebugContext
    ) {
        guard let responseRequest = try? decodeResponsesRequest(from: request.body) else {
            return (json(status: 400, #"{"error":"invalid responses request"}"#), debugContext(for: request))
        }

        let requestedModel = responseRequest.model
            ?? activeModelProvider().flatMap { $0.isEmpty ? nil : $0 }
            ?? "local"
        let chatPayload = responseRequest.chatCompletionPayload(model: requestedModel)
        let chatResult = try await proxyChatCompletion(
            payload: chatPayload,
            headers: request.headers,
            fallbackModel: requestedModel
        )
        let chatResponse = chatResult.response
        guard chatResponse.status >= 200, chatResponse.status < 300 else {
            return (chatResponse, chatResult.debugContext)
        }

        if responseRequest.stream {
            return (
                streamingResponsesResponse(model: chatResult.model, chatBody: chatResponse.body),
                chatResult.debugContext
            )
        }

        let assistantText = assistantText(fromChatCompletionBody: chatResponse.body)
        let payload = responsesPayload(model: chatResult.model, outputText: assistantText, chatBody: chatResponse.body)
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(#"{"object":"response","status":"completed","output":[]}"#.utf8)
        return (
            ProviderResponse(status: 200, headers: ["content-type": "application/json"], body: data),
            chatResult.debugContext
        )
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
            return normalizedChannelContent(from: content, isAssistant: true)?.content ?? content
        }
        if let text = firstChoice["text"] as? String {
            return normalizedChannelContent(from: text, isAssistant: true)?.content ?? text
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

    private func responseWithMLXUsageEvents(
        _ response: ProviderStreamedResponse,
        model: String
    ) -> ProviderStreamedResponse {
        let contextLimit = modelMetadata(for: model).maxContextLength
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            Task {
                var buffer = ""
                var latestUsage: MLXStreamTokenUsage?
                var didEmitCompletedUsage = false
                continuation.yield(
                    mlxUsageEventData(
                        phase: "started",
                        model: model,
                        contextLimit: contextLimit,
                        tokens: nil
                    )
                )

                do {
                    for try await chunk in response.chunks {
                        guard let text = String(data: chunk, encoding: .utf8) else {
                            continuation.yield(chunk)
                            continue
                        }

                        buffer.append(text)
                        while let delimiterRange = buffer.range(of: "\n\n") {
                            let blockWithDelimiter = String(buffer[..<delimiterRange.upperBound])
                            let block = String(buffer[..<delimiterRange.lowerBound])
                            buffer.removeSubrange(..<delimiterRange.upperBound)

                            if let usage = mlxStreamTokenUsage(fromSSEBlock: block) {
                                latestUsage = usage
                            }
                            if isSSEDoneBlock(block), !didEmitCompletedUsage {
                                continuation.yield(
                                    mlxUsageEventData(
                                        phase: "completed",
                                        model: model,
                                        contextLimit: contextLimit,
                                        tokens: latestUsage
                                    )
                                )
                                didEmitCompletedUsage = true
                            }

                            continuation.yield(Data(blockWithDelimiter.utf8))
                        }
                    }

                    if !buffer.isEmpty {
                        if let usage = mlxStreamTokenUsage(fromSSEBlock: buffer) {
                            latestUsage = usage
                        }
                        if isSSEDoneBlock(buffer), !didEmitCompletedUsage {
                            continuation.yield(
                                mlxUsageEventData(
                                    phase: "completed",
                                    model: model,
                                    contextLimit: contextLimit,
                                    tokens: latestUsage
                                )
                            )
                            didEmitCompletedUsage = true
                        }
                        continuation.yield(Data(buffer.utf8))
                    }

                    if !didEmitCompletedUsage {
                        continuation.yield(
                            mlxUsageEventData(
                                phase: "completed",
                                model: model,
                                contextLimit: contextLimit,
                                tokens: latestUsage
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return ProviderStreamedResponse(status: response.status, headers: response.headers, chunks: chunks)
    }

    private func mlxUsageEventData(
        phase: String,
        model: String,
        contextLimit: Int?,
        tokens: MLXStreamTokenUsage?
    ) -> Data {
        let null = NSNull()
        let context: [String: Any] = [
            "limit_tokens": contextLimit.map { $0 as Any } ?? null,
            "used_tokens": null,
            "remaining_tokens": null,
            "usage_ratio": null
        ]
        let tokenPayload: [String: Any] = [
            "input_tokens": tokens?.inputTokens.map { $0 as Any } ?? null,
            "output_tokens": tokens?.outputTokens.map { $0 as Any } ?? null,
            "total_tokens": tokens?.totalTokens.map { $0 as Any } ?? null
        ]
        let payload: [String: Any] = [
            "type": "mlx.usage",
            "phase": phase,
            "model": model,
            "context": context,
            "tokens": tokenPayload
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return Data() }
        return Data("event: mlx.usage\ndata: \(json)\n\n".utf8)
    }

    private func isSSEDoneBlock(_ block: String) -> Bool {
        sseDataPayloads(in: block).contains("[DONE]")
    }

    private func mlxStreamTokenUsage(fromSSEBlock block: String) -> MLXStreamTokenUsage? {
        for payload in sseDataPayloads(in: block) where payload != "[DONE]" {
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = object["usage"] as? [String: Any]
            else { continue }

            let inputTokens = intValue(usage["prompt_tokens"])
            let outputTokens = intValue(usage["completion_tokens"])
            let totalTokens = intValue(usage["total_tokens"]) ?? inputTokens.map { input in
                input + (outputTokens ?? 0)
            }
            return MLXStreamTokenUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalTokens: totalTokens
            )
        }
        return nil
    }

    private func sseDataPayloads(in block: String) -> [String] {
        block
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("data:") else { return nil }
                return String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            }
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }
}

private struct ProviderDebugContext {
    var selectedModel: String?
    var aliasResolution: String?
    var routingDecision: ProviderRoutingDecision?
    var modeAdvice: ProviderModeAdvice?
}

private struct ChannelMarkedSegment {
    var channel: String?
    var text: String
}

private struct NormalizedChannelContent {
    var content: String
    var thinking: String?
}

private struct MLXStreamTokenUsage {
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
}

private enum ProviderModeAdviceMode: String {
    case ask
    case plan
    case coding
    case unknown
}

private struct ProviderModeAdvice {
    static let switchConfidenceThreshold = 0.75

    var suggestedMode: ProviderModeAdviceMode
    var confidence: Double
    var shouldSuggestSwitch: Bool
    var currentMode: String?
    var reason: String

    var responsePayload: [String: Any] {
        var payload: [String: Any] = [
            "suggested_mode": suggestedMode.rawValue,
            "confidence": confidence,
            "should_suggest_switch": shouldSuggestSwitch,
            "reason": reason
        ]
        if let currentMode {
            payload["current_mode"] = currentMode
        }
        return payload
    }

    var debugPayload: [String: Any] {
        responsePayload
    }

    static func parse(classifierOutput: String, currentMode: String?) -> ProviderModeAdvice? {
        let trimmed = classifierOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawMode = object["mode"] as? String,
              let mode = ProviderModeAdviceMode(rawValue: rawMode)
        else {
            return nil
        }
        let rawConfidence = (object["confidence"] as? Double)
            ?? (object["confidence"] as? NSNumber)?.doubleValue
            ?? 0
        let confidence = min(max(rawConfidence, 0), 1)
        let reason = (object["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayReason = if let reason, !reason.isEmpty {
            reason
        } else {
            "Classifier did not provide a reason."
        }
        let shouldSuggestSwitch = confidence >= switchConfidenceThreshold
            && mode != .unknown
            && currentMode != nil
            && currentMode != mode.rawValue
        return ProviderModeAdvice(
            suggestedMode: mode,
            confidence: confidence,
            shouldSuggestSwitch: shouldSuggestSwitch,
            currentMode: currentMode,
            reason: displayReason
        )
    }

    static func unknown(currentMode: String?, reason: String) -> ProviderModeAdvice {
        ProviderModeAdvice(
            suggestedMode: .unknown,
            confidence: 0,
            shouldSuggestSwitch: false,
            currentMode: currentMode,
            reason: reason
        )
    }
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
    var upstreamModel: String
    var rewrittenModel: String?
    var upstreamEndpoint: ProviderUpstreamEndpoint?
    var fallbackReason: String?

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
