import Foundation

public struct AppPaths: Sendable {
    public let applicationSupport: URL
    public let configDirectory: URL
    public let logsDirectory: URL
    public let modelRegistryFile: URL
    public let settingsFile: URL
    public let venvDirectory: URL

    public init(applicationSupport: URL) {
        self.applicationSupport = applicationSupport
        self.configDirectory = applicationSupport.appending(path: "config", directoryHint: .isDirectory)
        self.logsDirectory = applicationSupport.appending(path: "logs", directoryHint: .isDirectory)
        self.modelRegistryFile = applicationSupport.appending(path: "models/registry.json")
        self.settingsFile = configDirectory.appending(path: "settings.json")
        self.venvDirectory = applicationSupport.appending(path: "venv", directoryHint: .isDirectory)
    }

    public static var `default`: AppPaths {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MLXDashboard", directoryHint: .isDirectory)
        return AppPaths(applicationSupport: root)
    }

    public func createDirectories() throws {
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: modelRegistryFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
