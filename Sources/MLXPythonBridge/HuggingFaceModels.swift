import Foundation

public struct HuggingFaceModelSummary: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var downloads: Int?
    public var likes: Int?

    public init(id: String, downloads: Int? = nil, likes: Int? = nil) {
        self.id = id
        self.downloads = downloads
        self.likes = likes
    }
}

public struct HuggingFaceModelSearcher: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ShellCommandRunner()) {
        self.runner = runner
    }

    public func search(query: String, pythonExecutable: URL, limit: Int = 20) async throws -> [HuggingFaceModelSummary] {
        let escapedQuery = query.replacingOccurrences(of: "'", with: "\\'")
        let script = """
        import json
        from huggingface_hub import list_models
        models = list_models(search='\(escapedQuery)', filter='mlx', limit=\(limit))
        print(json.dumps([{'id': m.modelId, 'downloads': m.downloads, 'likes': m.likes} for m in models]))
        """
        let result = try await runner.run(Command(executableURL: pythonExecutable, arguments: ["-c", script]))
        guard result.exitCode == 0 else {
            throw HuggingFaceError.searchFailed(result.standardError)
        }
        return try JSONDecoder().decode([HuggingFaceModelSummary].self, from: Data(result.standardOutput.utf8))
    }
}

public struct HuggingFaceModelInstaller: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ShellCommandRunner()) {
        self.runner = runner
    }

    public func install(modelID: String, pythonExecutable: URL) async throws {
        let script = """
        from huggingface_hub import snapshot_download
        snapshot_download(repo_id='\(modelID.replacingOccurrences(of: "'", with: "\\'"))')
        """
        let result = try await runner.run(Command(executableURL: pythonExecutable, arguments: ["-c", script]))
        guard result.exitCode == 0 else {
            throw HuggingFaceError.installFailed(result.standardError)
        }
    }
}

public enum HuggingFaceError: Error, Equatable, CustomStringConvertible {
    case searchFailed(String)
    case installFailed(String)

    public var description: String {
        switch self {
        case .searchFailed(let message):
            return "Hugging Face search failed: \(message)"
        case .installFailed(let message):
            return "Hugging Face install failed: \(message)"
        }
    }
}
