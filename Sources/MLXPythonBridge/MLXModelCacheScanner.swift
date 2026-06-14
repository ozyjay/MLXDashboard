import Foundation

public struct CachedMLXModel: Sendable, Equatable, Identifiable {
    public var id: String
    public var localPath: String

    public init(id: String, localPath: String) {
        self.id = id
        self.localPath = localPath
    }
}

public struct MLXModelCacheScanner: Sendable {
    private let requiredFiles = [
        "config.json",
        "model.safetensors.index.json",
        "tokenizer_config.json"
    ]

    public init() {}

    public func scan(cacheRoot: URL) throws -> [CachedMLXModel] {
        guard let enumerator = FileManager.default.enumerator(
            at: cacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var models: [CachedMLXModel] = []
        for case let directory as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            guard isMLXModelDirectory(directory) else { continue }
            guard let id = repoID(fromSnapshotDirectory: directory, cacheRoot: cacheRoot) else { continue }
            models.append(CachedMLXModel(id: id, localPath: localPath(for: directory, cacheRoot: cacheRoot)))
        }
        return models.sorted { $0.id < $1.id }
    }

    private func isMLXModelDirectory(_ directory: URL) -> Bool {
        requiredFiles.allSatisfy { file in
            FileManager.default.fileExists(atPath: directory.appending(path: file).path)
        }
    }

    private func repoID(fromSnapshotDirectory directory: URL, cacheRoot: URL) -> String? {
        guard let repoFolder = directory.pathComponents.first(where: { $0.hasPrefix("models--") }) else {
            return nil
        }
        let repoParts = repoFolder.dropFirst("models--".count).components(separatedBy: "--")
        guard repoParts.count >= 2 else {
            return nil
        }
        return repoParts.joined(separator: "/")
    }

    private func localPath(for directory: URL, cacheRoot: URL) -> String {
        let components = directory.pathComponents
        guard let modelIndex = components.firstIndex(where: { $0.hasPrefix("models--") }) else {
            return directory.path
        }
        let suffix = components[modelIndex...].joined(separator: "/")
        return cacheRoot.appending(path: suffix).path
    }
}

public struct MLXModelCacheManager: Sendable {
    public init() {}

    public func scan(cacheRoot: URL) throws -> [CachedMLXModel] {
        try MLXModelCacheScanner().scan(cacheRoot: cacheRoot)
    }

    @discardableResult
    public func deleteModelCache(modelID: String, localPath: String?, cacheRoot: URL) throws -> URL {
        let cacheDirectory = try repoCacheDirectory(modelID: modelID, localPath: localPath, cacheRoot: cacheRoot)
        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try FileManager.default.removeItem(at: cacheDirectory)
        }
        let lockDirectory = cacheDirectory
            .deletingLastPathComponent()
            .appending(path: ".locks", directoryHint: .isDirectory)
            .appending(path: cacheDirectory.lastPathComponent, directoryHint: .isDirectory)
            .standardizedFileURL
        if FileManager.default.fileExists(atPath: lockDirectory.path) {
            try FileManager.default.removeItem(at: lockDirectory)
        }
        return cacheDirectory
    }

    public func repoCacheDirectory(modelID: String, localPath: String?, cacheRoot: URL) throws -> URL {
        let root = cacheRoot.standardizedFileURL
        let cacheFolder = try cacheFolderName(for: modelID)

        if let localPath,
           let directory = repoCacheDirectoryFromLocalPath(localPath, expectedCacheFolder: cacheFolder) {
            return directory
        }

        let directory = root.appending(path: cacheFolder, directoryHint: .isDirectory)
            .standardizedFileURL
        guard isInsideCacheRoot(directory, root: root) else {
            throw MLXModelCacheError.outsideCacheRoot(directory.path)
        }
        return directory
    }

    private func repoCacheDirectoryFromLocalPath(_ localPath: String, expectedCacheFolder: String) -> URL? {
        let localURL = URL(filePath: localPath).standardizedFileURL
        let components = localURL.pathComponents
        guard let index = components.firstIndex(where: { $0 == expectedCacheFolder }),
              components[(index + 1)...].contains("snapshots")
        else {
            return nil
        }
        let prefix = components[0...index].joined(separator: "/")
        return URL(filePath: prefix).standardizedFileURL
    }

    private func cacheFolderName(for modelID: String) throws -> String {
        let parts = modelID.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty,
              parts.allSatisfy({ isSafeRepoIDComponent($0) })
        else {
            throw MLXModelCacheError.unsafeModelID(modelID)
        }
        return "models--\(parts.joined(separator: "--"))"
    }

    private func isSafeRepoIDComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component != ".", component != ".." else {
            return false
        }
        return !component.contains("\\") && !component.contains(":")
    }

    private func isInsideCacheRoot(_ directory: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return directoryPath == rootPath || directoryPath.hasPrefix(rootPath + "/")
    }
}

public enum MLXModelCacheError: Error, Equatable, CustomStringConvertible {
    case unsafeModelID(String)
    case outsideCacheRoot(String)

    public var description: String {
        switch self {
        case .unsafeModelID(let modelID):
            return "Unsafe model id for cache deletion: \(modelID)"
        case .outsideCacheRoot(let path):
            return "Refusing to delete outside the Hugging Face cache: \(path)"
        }
    }
}
