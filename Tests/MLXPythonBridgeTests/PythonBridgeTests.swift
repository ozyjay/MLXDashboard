import XCTest
import MLXCore
@testable import MLXPythonBridge

final class PythonBridgeTests: XCTestCase {
    func testPackageCheckerReportsMissingPackages() async throws {
        let runner = FakeCommandRunner(results: [
            "import mlx_lm": CommandResult(exitCode: 1, standardOutput: "", standardError: "No module named mlx_lm"),
            "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ])
        let checker = PythonPackageChecker(runner: runner)

        let report = try await checker.checkPackages(
            pythonExecutable: URL(filePath: "/tmp/python"),
            packages: [
                PythonPackage(importName: "mlx_lm", installName: "mlx-lm"),
                PythonPackage(importName: "huggingface_hub", installName: "huggingface_hub")
            ]
        )

        XCTAssertEqual(report.missingInstallNames, ["mlx-lm"])
        XCTAssertFalse(report.isReady)
    }

    func testCacheScannerFindsMLXCompatibleModelDirectories() throws {
        let root = try temporaryDirectory()
        let good = root.appending(path: "models--mlx-community--Tiny/snapshots/abc123", directoryHint: .isDirectory)
        let bad = root.appending(path: "models--mlx-community--Broken/snapshots/def456", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        for name in ["config.json", "model.safetensors.index.json", "tokenizer_config.json"] {
            FileManager.default.createFile(atPath: good.appending(path: name).path, contents: Data())
        }
        FileManager.default.createFile(atPath: bad.appending(path: "config.json").path, contents: Data())

        let scanner = MLXModelCacheScanner()
        let models = try scanner.scan(cacheRoot: root)

        XCTAssertEqual(models.map(\.id), ["mlx-community/Tiny"])
        XCTAssertEqual(models.first?.localPath, good.path)
    }

    func testCacheManagerDeletesWholeRepoCacheFolderForModel() throws {
        let root = try temporaryDirectory()
        let snapshot = root.appending(path: "models--mlx-community--Tiny/snapshots/abc123", directoryHint: .isDirectory)
        let siblingSnapshot = root.appending(path: "models--mlx-community--Tiny/snapshots/def456", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingSnapshot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: snapshot.appending(path: "config.json").path, contents: Data())
        FileManager.default.createFile(atPath: siblingSnapshot.appending(path: "config.json").path, contents: Data())

        let manager = MLXModelCacheManager()
        let deleted = try manager.deleteModelCache(
            modelID: "mlx-community/Tiny",
            localPath: snapshot.path,
            cacheRoot: root
        )

        XCTAssertEqual(deleted.lastPathComponent, "models--mlx-community--Tiny")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "models--mlx-community--Tiny").path))
    }

    func testCacheManagerRejectsUnsafeModelIDWithoutDeletingCacheRoot() throws {
        let root = try temporaryDirectory()
        let keep = root.appending(path: "models--mlx-community--Tiny", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)

        let manager = MLXModelCacheManager()

        XCTAssertThrowsError(
            try manager.deleteModelCache(modelID: "../Tiny", localPath: nil, cacheRoot: root)
        ) { error in
            XCTAssertEqual(error as? MLXModelCacheError, .unsafeModelID("../Tiny"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    }

    func testHuggingFaceSearcherDecodesModelSummaries() async throws {
        let runner = FakeCommandRunner(results: [
            "search": CommandResult(
                exitCode: 0,
                standardOutput: #"[{"id":"mlx-community/Tiny","downloads":42,"likes":7}]"#,
                standardError: ""
            )
        ])
        let searcher = HuggingFaceModelSearcher(runner: runner)

        let results = try await searcher.search(query: "tiny", pythonExecutable: URL(filePath: "/tmp/python"), limit: 5)

        XCTAssertEqual(results, [HuggingFaceModelSummary(id: "mlx-community/Tiny", downloads: 42, likes: 7)])
    }

    func testHuggingFaceAuthCheckerReportsLoggedInAndLoggedOutStates() async throws {
        let loggedInRunner = FakeCommandRunner(results: [
            "whoami": CommandResult(exitCode: 0, standardOutput: #"{"name":"octocat"}"#, standardError: "")
        ])
        let loggedOutRunner = FakeCommandRunner(results: [
            "whoami": CommandResult(exitCode: 1, standardOutput: "", standardError: "Invalid user token")
        ])
        let unavailableRunner = FakeCommandRunner(results: [
            "whoami": CommandResult(exitCode: 1, standardOutput: "", standardError: "No module named huggingface_hub")
        ])

        let python = URL(filePath: "/tmp/python")
        let loggedIn = try await HuggingFaceAuthChecker(runner: loggedInRunner).status(pythonExecutable: python)
        let loggedOut = try await HuggingFaceAuthChecker(runner: loggedOutRunner).status(pythonExecutable: python)
        let unavailable = try await HuggingFaceAuthChecker(runner: unavailableRunner).status(pythonExecutable: python)

        XCTAssertEqual(loggedIn, .loggedIn(username: "octocat"))
        XCTAssertEqual(loggedOut, .loggedOut("Invalid user token"))
        XCTAssertEqual(unavailable, .unavailable("No module named huggingface_hub"))
    }

    func testHuggingFaceInstallerReturnsDownloadedSnapshotPath() async throws {
        let runner = FakeCommandRunner(results: [
            "install": CommandResult(
                exitCode: 0,
                standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
                standardError: ""
            )
        ])
        let installer = HuggingFaceModelInstaller(runner: runner)

        let result = try await installer.install(
            modelID: "mlx-community/Tiny",
            pythonExecutable: URL(filePath: "/tmp/python")
        )

        XCTAssertEqual(result.localPath, "/tmp/cache/models--mlx-community--Tiny/snapshots/abc")
    }

    func testHuggingFaceDownloadProgressParsesTqdmETA() throws {
        let line = "model.safetensors:  42%|####      | 4.20G/10.0G [05:10<07:12, 13.4MB/s]"

        let progress = try XCTUnwrap(HuggingFaceDownloadProgress.parse(from: line))

        XCTAssertEqual(progress.fractionCompleted, 0.42, accuracy: 0.001)
        XCTAssertEqual(progress.percentText, "42%")
        XCTAssertEqual(progress.etaText, "7m 12s")
        XCTAssertEqual(progress.rateText, "13.4MB/s")
    }

    func testHuggingFaceInstallerReportsDownloadProgressFromCommandOutput() async throws {
        let runner = FakeCommandRunner(results: [
            "install": CommandResult(
                exitCode: 0,
                standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
                standardError: "model.safetensors:  42%|####      | 4.20G/10.0G [05:10<07:12, 13.4MB/s]"
            )
        ])
        let installer = HuggingFaceModelInstaller(runner: runner)
        let recorder = DownloadProgressRecorder()

        _ = try await installer.install(
            modelID: "mlx-community/Tiny",
            pythonExecutable: URL(filePath: "/tmp/python"),
            progressHandler: { recorder.append($0) }
        )

        XCTAssertEqual(recorder.last?.etaText, "7m 12s")
        XCTAssertEqual(recorder.last?.fractionCompleted ?? 0, 0.42, accuracy: 0.001)
    }

    func testHuggingFaceInstallerReportsInstallFailure() async throws {
        let runner = FakeCommandRunner(results: [
            "install": CommandResult(exitCode: 1, standardOutput: "", standardError: "download failed")
        ])
        let installer = HuggingFaceModelInstaller(runner: runner)

        do {
            try await installer.install(modelID: "mlx-community/Tiny", pythonExecutable: URL(filePath: "/tmp/python"))
            XCTFail("Expected install to fail")
        } catch let error as HuggingFaceError {
            XCTAssertEqual(error, .installFailed("download failed"))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MLXPythonBridgeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct FakeCommandRunner: CommandRunning {
    let results: [String: CommandResult]

    func run(_ command: Command) async throws -> CommandResult {
        let script = command.arguments.last ?? ""
        let key: String
        if script.contains("list_models") {
            key = "search"
        } else if script.contains("snapshot_download") {
            key = "install"
        } else if script.contains("whoami") {
            key = "whoami"
        } else {
            key = script
        }
        return results[key] ?? CommandResult(exitCode: 127, standardOutput: "", standardError: "unexpected command \(key)")
    }
}

private final class DownloadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HuggingFaceDownloadProgress] = []

    var last: HuggingFaceDownloadProgress? {
        lock.withLock {
            events.last
        }
    }

    func append(_ progress: HuggingFaceDownloadProgress) {
        lock.withLock {
            events.append(progress)
        }
    }
}
