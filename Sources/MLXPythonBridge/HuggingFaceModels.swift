import Foundation

public struct HuggingFaceModelSummary: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var downloads: Int?
    public var likes: Int?
    public var modelType: String?

    public init(id: String, downloads: Int? = nil, likes: Int? = nil, modelType: String? = nil) {
        self.id = id
        self.downloads = downloads
        self.likes = likes
        self.modelType = modelType
    }

    enum CodingKeys: String, CodingKey {
        case id
        case downloads
        case likes
        case modelType = "model_type"
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

    public func search(
        query: String,
        pythonExecutable: URL,
        author: String = "mlx-community",
        sort: String = "downloads",
        limit: Int = 50
    ) async throws -> [HuggingFaceModelSummary] {
        let script = """
        import json
        import sys
        from tempfile import TemporaryDirectory
        from concurrent.futures import ThreadPoolExecutor
        from huggingface_hub import hf_hub_download, list_models
        query, author, sort, limit = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
        models = list(list_models(search=query, author=author, filter='mlx', sort=sort, limit=limit))
        with TemporaryDirectory(prefix='mlxdashboard-hf-config-') as config_cache:
            def summarize(model):
                model_type = None
                try:
                    config_path = hf_hub_download(repo_id=model.modelId, filename='config.json', cache_dir=config_cache)
                    with open(config_path, encoding='utf-8') as config_file:
                        model_type = json.load(config_file).get('model_type')
                except Exception:
                    model_type = None
                return {
                    'id': model.modelId,
                    'downloads': model.downloads,
                    'likes': model.likes,
                    'model_type': model_type,
                }
            with ThreadPoolExecutor(max_workers=8) as executor:
                results = list(executor.map(summarize, models))
        print(json.dumps(results))
        """
        let result = try await runner.run(Command(
            executableURL: pythonExecutable,
            arguments: ["-c", script, query, author, sort, String(limit)]
        ))
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
        let bracketText = bracketContent(in: line)
        guard let rate = rateText(from: bracketText),
              isByteTransferRate(rate)
        else { return nil }
        let fraction = min(max(percentValue / 100, 0), 1)
        let percentText = formattedPercent(percentValue)
        return HuggingFaceDownloadProgress(
            fractionCompleted: fraction,
            percentText: percentText,
            etaText: etaText(from: bracketText),
            rateText: rate
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

    private static func isByteTransferRate(_ rate: String) -> Bool {
        let normalized = rate.lowercased()
        return normalized.contains("b/s") || normalized.contains("byte/s") || normalized.contains("bytes/s")
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
        disableXet: Bool,
        progressHandler: (@Sendable (HuggingFaceDownloadProgress) -> Void)? = nil,
        activityHandler: (@Sendable (HuggingFaceDownloadActivity) -> Void)? = nil
    ) async throws -> HuggingFaceInstallResult {
        let downloadEnvironment = disableXet ? ["HF_HUB_DISABLE_XET": "1"] : [:]
        return try await install(
            modelID: modelID,
            pythonExecutable: pythonExecutable,
            downloadEnvironment: downloadEnvironment,
            downloadEnvironmentRemovals: disableXet ? [] : ["HF_HUB_DISABLE_XET"],
            progressHandler: progressHandler,
            activityHandler: activityHandler
        )
    }

    public func install(
        modelID: String,
        pythonExecutable: URL,
        downloadEnvironment: [String: String] = [:],
        downloadEnvironmentRemovals: [String] = [],
        progressHandler: (@Sendable (HuggingFaceDownloadProgress) -> Void)? = nil,
        activityHandler: (@Sendable (HuggingFaceDownloadActivity) -> Void)? = nil
    ) async throws -> HuggingFaceInstallResult {
        let activityBuffer = HuggingFaceDownloadActivityBuffer()
        let isXetDisabled = downloadEnvironment["HF_HUB_DISABLE_XET"] == "1"
        let script = """
        import json
        import os
        import sys
        from pathlib import Path
        from huggingface_hub import snapshot_download

        MISTRAL_FAMILY_MODEL_TYPES = {
            'mistral',
            'mistral3',
            'ministral',
            'ministral3',
            'pixtral',
            'voxtral',
        }

        def model_needs_mistral_regex_fix(config):
            model_type = config.get('model_type')
            if isinstance(model_type, str) and model_type.lower() in MISTRAL_FAMILY_MODEL_TYPES:
                return True
            text_config = config.get('text_config')
            text_model_type = text_config.get('model_type') if isinstance(text_config, dict) else None
            if isinstance(text_model_type, str) and text_model_type.lower() in MISTRAL_FAMILY_MODEL_TYPES:
                return True
            return False

        def repair_tokenizer_config(snapshot_path):
            snapshot = Path(snapshot_path)
            config_path = snapshot / 'config.json'
            tokenizer_config_path = snapshot / 'tokenizer_config.json'
            try:
                with open(config_path, encoding='utf-8') as config_file:
                    config = json.load(config_file)
                if not model_needs_mistral_regex_fix(config):
                    return
                with open(tokenizer_config_path, encoding='utf-8') as tokenizer_config_file:
                    tokenizer_config = json.load(tokenizer_config_file)
                if tokenizer_config.get('fix_mistral_regex') is True:
                    return
                tokenizer_config['fix_mistral_regex'] = True
                temporary_path = tokenizer_config_path.with_suffix(tokenizer_config_path.suffix + '.tmp')
                with open(temporary_path, 'w', encoding='utf-8') as tokenizer_config_file:
                    json.dump(tokenizer_config, tokenizer_config_file, indent=2, sort_keys=True)
                    tokenizer_config_file.write('\\n')
                os.replace(temporary_path, tokenizer_config_path)
            except Exception as exc:
                print(f'MLXDashboard: Unable to repair tokenizer config for {snapshot}: {exc}', file=sys.stderr, flush=True)

        model_id = sys.argv[1]
        suffix = ' with Xet disabled' if '\(isXetDisabled ? "1" : "0")' == '1' else ''
        print(f'MLXDashboard: Started Hugging Face snapshot download for {model_id}{suffix}', file=sys.stderr, flush=True)
        path = snapshot_download(repo_id=model_id)
        repair_tokenizer_config(path)
        print(json.dumps({'local_path': path}))
        """
        let environment = downloadEnvironment
        let result = try await runner.run(Command(
            executableURL: pythonExecutable,
            arguments: ["-c", script, modelID],
            environment: environment,
            environmentRemovals: downloadEnvironmentRemovals
        )) { output in
            if let progress = HuggingFaceDownloadProgress.parse(from: output) {
                progressHandler?(progress)
            }
            for activity in activityBuffer.append(output) {
                activityHandler?(activity)
            }
        }
        for activity in activityBuffer.flush() {
            activityHandler?(activity)
        }
        guard result.exitCode == 0 else {
            throw HuggingFaceError.installFailed(result.standardError)
        }
        return try JSONDecoder().decode(HuggingFaceInstallResult.self, from: Data(result.standardOutput.utf8))
    }
}

private final class HuggingFaceDownloadActivityBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingOutput = ""

    func append(_ output: String) -> [HuggingFaceDownloadActivity] {
        lock.withLock {
            if output.hasPrefix("MLXDashboard: "),
               !pendingOutput.isEmpty,
               !pendingOutput.hasPrefix("MLXDashboard: ") {
                pendingOutput = ""
            }
            pendingOutput.append(output)
            guard let lastNewline = pendingOutput.lastIndex(where: \.isNewline) else {
                return []
            }

            let completeOutput = String(pendingOutput[...lastNewline])
            pendingOutput = String(pendingOutput[pendingOutput.index(after: lastNewline)...])
            return HuggingFaceDownloadActivity.parse(from: completeOutput)
        }
    }

    func flush() -> [HuggingFaceDownloadActivity] {
        lock.withLock {
            let output = pendingOutput
            pendingOutput = ""
            return HuggingFaceDownloadActivity.parse(from: output)
        }
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
