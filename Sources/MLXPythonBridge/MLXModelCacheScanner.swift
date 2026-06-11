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
