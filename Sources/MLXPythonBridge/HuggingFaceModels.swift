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

public enum HuggingFaceAuthStatus: Sendable, Equatable {
    case loggedIn(username: String?)
    case loggedOut(String)
    case unavailable(String)

    public var displayText: String {
        switch self {
        case .loggedIn(let username):
            if let username, !username.isEmpty {
                return "Hugging Face: logged in as \(username)"
            }
            return "Hugging Face: logged in"
        case .loggedOut:
            return "Hugging Face: not logged in"
        case .unavailable:
            return "Hugging Face: unable to check auth"
        }
    }
}

public struct HuggingFaceAuthChecker: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ShellCommandRunner()) {
        self.runner = runner
    }

    public func status(pythonExecutable: URL) async throws -> HuggingFaceAuthStatus {
        let script = """
        import json
        from huggingface_hub import HfApi
        info = HfApi().whoami()
        print(json.dumps({'name': info.get('name')}))
        """
        let result = try await runner.run(Command(executableURL: pythonExecutable, arguments: ["-c", script]))
        guard result.exitCode == 0 else {
            let message = cleaned(result.standardError)
            if message.localizedCaseInsensitiveContains("No module named") {
                return .unavailable(message)
            }
            return .loggedOut(message)
        }
        let auth = try JSONDecoder().decode(HuggingFaceWhoamiResponse.self, from: Data(result.standardOutput.utf8))
        return .loggedIn(username: auth.name)
    }

    private func cleaned(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No Hugging Face login was found" : trimmed
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

public struct HuggingFaceInstallResult: Sendable, Equatable, Codable {
    public var localPath: String

    public init(localPath: String) {
        self.localPath = localPath
    }

    enum CodingKeys: String, CodingKey {
        case localPath = "local_path"
    }
}

public struct HuggingFaceModelInstaller: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ShellCommandRunner()) {
        self.runner = runner
    }

    public func install(modelID: String, pythonExecutable: URL) async throws -> HuggingFaceInstallResult {
        let script = """
        import json
        from huggingface_hub import snapshot_download
        path = snapshot_download(repo_id='\(modelID.replacingOccurrences(of: "'", with: "\\'"))')
        print(json.dumps({'local_path': path}))
        """
        let result = try await runner.run(Command(executableURL: pythonExecutable, arguments: ["-c", script]))
        guard result.exitCode == 0 else {
            throw HuggingFaceError.installFailed(result.standardError)
        }
        return try JSONDecoder().decode(HuggingFaceInstallResult.self, from: Data(result.standardOutput.utf8))
    }
}

private struct HuggingFaceWhoamiResponse: Decodable {
    var name: String?
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
