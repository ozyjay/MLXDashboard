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

public struct HuggingFaceDownloadProgress: Sendable, Equatable {
    public var fractionCompleted: Double
    public var percentText: String
    public var etaText: String?
    public var rateText: String?

    public init(fractionCompleted: Double, percentText: String, etaText: String? = nil, rateText: String? = nil) {
        self.fractionCompleted = fractionCompleted
        self.percentText = percentText
        self.etaText = etaText
        self.rateText = rateText
    }

    public static func parse(from output: String) -> HuggingFaceDownloadProgress? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            if let progress = parseLine(String(line)) {
                return progress
            }
        }
        return parseLine(output)
    }

    private static func parseLine(_ line: String) -> HuggingFaceDownloadProgress? {
        guard let percentMatch = line.range(
            of: #"(\d+(?:\.\d+)?)%"#,
            options: .regularExpression
        ) else { return nil }

        let percentString = String(line[percentMatch].dropLast())
        guard let percentValue = Double(percentString) else { return nil }
        let fraction = min(max(percentValue / 100, 0), 1)
        let percentText = formattedPercent(percentValue)
        let bracketText = bracketContent(in: line)
        return HuggingFaceDownloadProgress(
            fractionCompleted: fraction,
            percentText: percentText,
            etaText: etaText(from: bracketText),
            rateText: rateText(from: bracketText)
        )
    }

    private static func formattedPercent(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))%"
        }
        return String(format: "%.1f%%", value)
    }

    private static func bracketContent(in line: String) -> String? {
        guard let start = line.lastIndex(of: "["),
              let end = line.lastIndex(of: "]"),
              start < end
        else { return nil }
        return String(line[line.index(after: start)..<end])
    }

    private static func etaText(from bracketText: String?) -> String? {
        guard let bracketText,
              let etaStart = bracketText.firstIndex(of: "<")
        else { return nil }
        let remainder = bracketText[bracketText.index(after: etaStart)...]
        let rawETA = remainder.split(separator: ",", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawETA, !rawETA.isEmpty, rawETA != "?" else { return nil }
        return formattedDuration(rawETA)
    }

    private static func rateText(from bracketText: String?) -> String? {
        guard let bracketText else { return nil }
        let parts = bracketText.split(separator: ",", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let rate = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return rate.isEmpty ? nil : rate
    }

    private static func formattedDuration(_ raw: String) -> String {
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        guard parts.count == raw.split(separator: ":").count else { return raw }
        let hours: Int
        let minutes: Int
        let seconds: Int
        switch parts.count {
        case 3:
            hours = parts[0]
            minutes = parts[1]
            seconds = parts[2]
        case 2:
            hours = 0
            minutes = parts[0]
            seconds = parts[1]
        case 1:
            hours = 0
            minutes = 0
            seconds = parts[0]
        default:
            return raw
        }

        var components: [String] = []
        if hours > 0 {
            components.append("\(hours)h")
        }
        if minutes > 0 {
            components.append("\(minutes)m")
        }
        if seconds > 0 || components.isEmpty {
            components.append("\(seconds)s")
        }
        return components.joined(separator: " ")
    }
}

public struct HuggingFaceDownloadActivity: Sendable, Equatable {
    public enum Tone: String, Sendable, Equatable {
        case info
        case warning
        case error
    }

    public enum Source: String, Sendable, Equatable {
        case commandOutput
        case cacheScan
        case xetLog
    }

    public var message: String
    public var tone: Tone
    public var source: Source

    public init(message: String, tone: Tone, source: Source) {
        self.message = message
        self.tone = tone
        self.source = source
    }

    public static func parse(from output: String) -> [HuggingFaceDownloadActivity] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0)) }
    }

    private static func parseLine(_ line: String) -> HuggingFaceDownloadActivity? {
        if line.hasPrefix("MLXDashboard: ") {
            return HuggingFaceDownloadActivity(
                message: String(line.dropFirst("MLXDashboard: ".count)),
                tone: .info,
                source: .commandOutput
            )
        }

        guard line.localizedCaseInsensitiveContains("connection struggling"),
              line.localizedCaseInsensitiveContains("concurrency")
        else { return nil }

        return HuggingFaceDownloadActivity(
            message: "Xet transfer: connection struggling, concurrency reduced",
            tone: .warning,
            source: .xetLog
        )
    }
}

public struct HuggingFaceModelInstaller: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ShellCommandRunner()) {
        self.runner = runner
    }

    public func install(
        modelID: String,
        pythonExecutable: URL,
        progressHandler: (@Sendable (HuggingFaceDownloadProgress) -> Void)? = nil,
        activityHandler: (@Sendable (HuggingFaceDownloadActivity) -> Void)? = nil
    ) async throws -> HuggingFaceInstallResult {
        let script = """
        import json
        import sys
        from huggingface_hub import snapshot_download
        print('MLXDashboard: Started Hugging Face snapshot download for \(modelID.replacingOccurrences(of: "'", with: "\\'"))', file=sys.stderr, flush=True)
        path = snapshot_download(repo_id='\(modelID.replacingOccurrences(of: "'", with: "\\'"))')
        print(json.dumps({'local_path': path}))
        """
        let result = try await runner.run(Command(executableURL: pythonExecutable, arguments: ["-c", script])) { output in
            if let progress = HuggingFaceDownloadProgress.parse(from: output) {
                progressHandler?(progress)
            }
            for activity in HuggingFaceDownloadActivity.parse(from: output) {
                activityHandler?(activity)
            }
        }
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
