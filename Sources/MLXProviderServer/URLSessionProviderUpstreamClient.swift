import Foundation

public struct URLSessionProviderUpstreamClient: ProviderUpstreamClient {
    private let mlxBaseURL: @Sendable () -> URL
    private let transport: URLSessionProviderUpstreamTransport

    public init(mlxBaseURL: @escaping @Sendable () -> URL, session: URLSession = .shared) {
        self.mlxBaseURL = mlxBaseURL
        self.transport = URLSessionProviderUpstreamTransport(session: session)
    }

    public func proxy(_ request: ProviderRequest) async throws -> ProviderResponse {
        try await transport.proxy(request, baseURL: mlxBaseURL())
    }

    public func proxyStream(_ request: ProviderRequest) async throws -> ProviderStreamedResponse {
        try await transport.proxyStream(request, baseURL: mlxBaseURL())
    }
}

public struct URLSessionProviderUpstreamProxyClient: ProviderUpstreamProxyClient {
    private let transport: URLSessionProviderUpstreamTransport

    public init(session: URLSession = .shared) {
        self.transport = URLSessionProviderUpstreamTransport(session: session)
    }

    public func proxy(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint) async throws -> ProviderResponse {
        try await transport.proxy(request, baseURL: endpoint.baseURL)
    }

    public func proxyStream(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint) async throws -> ProviderStreamedResponse {
        try await transport.proxyStream(request, baseURL: endpoint.baseURL)
    }
}

private struct URLSessionProviderUpstreamTransport: Sendable {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func proxy(_ request: ProviderRequest, baseURL: URL) async throws -> ProviderResponse {
        let (data, headers, status) = try await dataResponse(for: request, baseURL: baseURL)
        return ProviderResponse(status: status, headers: headers, body: data)
    }

    func proxyStream(_ request: ProviderRequest, baseURL: URL) async throws -> ProviderStreamedResponse {
        let upstreamRequest = urlRequest(for: request, baseURL: baseURL)
        let (bytes, response) = try await session.bytes(for: upstreamRequest)
        let httpResponse = response as? HTTPURLResponse
        let headers = responseHeaders(from: httpResponse)
        let status = httpResponse?.statusCode ?? 502
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            Task {
                do {
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == 10 || buffer.count >= 4096 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return ProviderStreamedResponse(status: status, headers: headers, chunks: chunks)
    }

    private func dataResponse(for request: ProviderRequest, baseURL: URL) async throws -> (Data, [String: String], Int) {
        let upstreamRequest = urlRequest(for: request, baseURL: baseURL)
        let (data, response) = try await session.data(for: upstreamRequest)
        let httpResponse = response as? HTTPURLResponse
        return (
            data,
            responseHeaders(from: httpResponse),
            httpResponse?.statusCode ?? 502
        )
    }

    private func urlRequest(for request: ProviderRequest, baseURL: URL) -> URLRequest {
        let upstreamURL = baseURL.appending(path: request.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var upstreamRequest = URLRequest(url: upstreamURL)
        upstreamRequest.httpMethod = request.method
        upstreamRequest.httpBody = request.body.isEmpty ? nil : request.body
        for (name, value) in request.headers where name != "authorization" && name != "host" {
            upstreamRequest.setValue(value, forHTTPHeaderField: name)
        }
        return upstreamRequest
    }

    private func responseHeaders(from httpResponse: HTTPURLResponse?) -> [String: String] {
        var headers: [String: String] = [:]
        httpResponse?.allHeaderFields.forEach { key, value in
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return headers
    }
}
