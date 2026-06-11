import Foundation

public struct URLSessionProviderUpstreamClient: ProviderUpstreamClient {
    private let mlxBaseURL: @Sendable () -> URL
    private let session: URLSession

    public init(mlxBaseURL: @escaping @Sendable () -> URL, session: URLSession = .shared) {
        self.mlxBaseURL = mlxBaseURL
        self.session = session
    }

    public func proxy(_ request: ProviderRequest) async throws -> ProviderResponse {
        let upstreamURL = mlxBaseURL().appending(path: request.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var upstreamRequest = URLRequest(url: upstreamURL)
        upstreamRequest.httpMethod = request.method
        upstreamRequest.httpBody = request.body.isEmpty ? nil : request.body
        for (name, value) in request.headers where name != "authorization" && name != "host" {
            upstreamRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: upstreamRequest)
        let httpResponse = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        httpResponse?.allHeaderFields.forEach { key, value in
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return ProviderResponse(
            status: httpResponse?.statusCode ?? 502,
            headers: headers,
            body: data
        )
    }
}
