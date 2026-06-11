import Foundation

public struct ProviderRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method.uppercased()
        self.path = path
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { key, value in
            (key.lowercased(), value)
        })
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public struct ProviderResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { key, value in
            (key.lowercased(), value)
        })
        self.body = body
    }
}

public protocol ProviderUpstreamClient: Sendable {
    func proxy(_ request: ProviderRequest) async throws -> ProviderResponse
}
