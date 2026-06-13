import Foundation

public struct URLSessionProviderUpstreamClient: ProviderUpstreamClient {
    private let mlxBaseURL: @Sendable () -> URL
    private let session: URLSession

    public init(mlxBaseURL: @escaping @Sendable () -> URL, session: URLSession = .shared) {
        self.mlxBaseURL = mlxBaseURL
        self.session = session
    }

    public func proxy(_ request: ProviderRequest) async throws -> ProviderResponse {
        let (data, headers, status) = try await dataResponse(for: request)
        return ProviderResponse(
            status: status,
            headers: headers,
            body: data
        )
    }

    public func proxyStream(_ request: ProviderRequest) async throws -> ProviderStreamedResponse {
        let upstreamRequest = urlRequest(for: request)
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

    private func dataResponse(for request: ProviderRequest) async throws -> (Data, [String: String], Int) {
        let upstreamRequest = urlRequest(for: request)
        let (data, response) = try await session.data(for: upstreamRequest)
        let httpResponse = response as? HTTPURLResponse
        return (
            data,
            responseHeaders(from: httpResponse),
            httpResponse?.statusCode ?? 502
        )
    }

    private func urlRequest(for request: ProviderRequest) -> URLRequest {
        let upstreamURL = mlxBaseURL().appending(path: request.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
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
