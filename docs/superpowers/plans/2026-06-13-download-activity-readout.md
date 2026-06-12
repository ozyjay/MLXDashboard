# Download Activity Readout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an always-visible OllamaPull-style readout that explains what Hugging Face model downloads are doing while they run.

**Architecture:** Keep reliable byte-progress parsing in `MLXPythonBridge`, add app-level cache/log monitoring in `MLXDashboardApp`, and render the resulting activity through the existing `InstallProgressBanner`. The install command remains `huggingface_hub.snapshot_download`; runtime server startup and localhost binding are untouched.

**Tech Stack:** Swift Package Manager, XCTest, SwiftUI, Foundation `Process`, Hugging Face `snapshot_download`, local Hugging Face hub cache.

---

## File Structure

- Modify `Sources/MLXPythonBridge/HuggingFaceModels.swift`
  - Add structured `HuggingFaceDownloadActivity` and parser helpers for non-progress command/Xet output.
  - Add an `activityHandler` to `HuggingFaceModelInstaller.install` without removing the existing progress handler.
- Modify `Tests/MLXPythonBridgeTests/PythonBridgeTests.swift`
  - Add red/green tests for activity classification and installer callback forwarding.
- Create `Sources/MLXDashboardApp/DownloadActivityMonitor.swift`
  - Add app-owned cache summary and Xet log sampling types.
  - Keep file-system monitoring separate from `DashboardViewModel`.
- Modify `Sources/MLXDashboardApp/ModelInstallProgress.swift`
  - Store recent activity and cache summary.
  - Add computed display strings for the banner.
- Modify `Sources/MLXDashboardApp/DashboardViewModel.swift`
  - Start and stop a lightweight monitor task during active installs.
  - Append activity while preserving only the latest five entries.
- Modify `Sources/MLXDashboardApp/ContentView.swift`
  - Render cache status and recent activity inside the existing install banner.
- Modify `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`
  - Add red/green tests for summary formatting and capped activity history.

---

### Task 1: Bridge Activity Events From Command Output

**Files:**
- Modify: `Sources/MLXPythonBridge/HuggingFaceModels.swift`
- Test: `Tests/MLXPythonBridgeTests/PythonBridgeTests.swift`

- [ ] **Step 1: Write failing parser tests**

Add these tests near the existing Hugging Face progress parser tests in `Tests/MLXPythonBridgeTests/PythonBridgeTests.swift`:

```swift
func testHuggingFaceDownloadActivityParsesXetConnectionStrugglingJSON() throws {
    let line = #"{"timestamp":"2026-06-12T14:00:45Z","level":"INFO","fields":{"message":"Concurrency control for download: Decreased concurrency from 1 to 1; reason: success ratio below threshold (connection struggling) (success_ratio = 1.000, threshold = 0.500)"}}"#

    let activities = HuggingFaceDownloadActivity.parse(from: line)

    XCTAssertEqual(activities, [
        HuggingFaceDownloadActivity(
            message: "Xet transfer: connection struggling, concurrency reduced",
            tone: .warning,
            source: .xetLog
        )
    ])
}

func testHuggingFaceDownloadActivityParsesSnapshotStartMarker() throws {
    let output = "MLXDashboard: Started Hugging Face snapshot download for mlx-community/Tiny\n"

    let activities = HuggingFaceDownloadActivity.parse(from: output)

    XCTAssertEqual(activities, [
        HuggingFaceDownloadActivity(
            message: "Started Hugging Face snapshot download for mlx-community/Tiny",
            tone: .info,
            source: .commandOutput
        )
    ])
}
```

- [ ] **Step 2: Run parser tests and verify red**

Run:

```bash
swift test --filter PythonBridgeTests/testHuggingFaceDownloadActivityParses
```

Expected: FAIL because `HuggingFaceDownloadActivity` does not exist.

- [ ] **Step 3: Add minimal activity model and parser**

In `Sources/MLXPythonBridge/HuggingFaceModels.swift`, after `HuggingFaceDownloadProgress`, add:

```swift
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
```

- [ ] **Step 4: Run parser tests and verify green**

Run:

```bash
swift test --filter PythonBridgeTests/testHuggingFaceDownloadActivityParses
```

Expected: PASS.

- [ ] **Step 5: Write failing installer forwarding test**

Add this test near `testHuggingFaceInstallerReportsDownloadProgressFromCommandOutput`:

```swift
func testHuggingFaceInstallerReportsDownloadActivityFromCommandOutput() async throws {
    let runner = FakeCommandRunner(results: [
        "install": CommandResult(
            exitCode: 0,
            standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
            standardError: "MLXDashboard: Started Hugging Face snapshot download for mlx-community/Tiny"
        )
    ])
    let installer = HuggingFaceModelInstaller(runner: runner)
    let recorder = DownloadActivityRecorder()

    _ = try await installer.install(
        modelID: "mlx-community/Tiny",
        pythonExecutable: URL(filePath: "/tmp/python"),
        activityHandler: { recorder.append($0) }
    )

    XCTAssertEqual(recorder.events, [
        HuggingFaceDownloadActivity(
            message: "Started Hugging Face snapshot download for mlx-community/Tiny",
            tone: .info,
            source: .commandOutput
        )
    ])
}
```

Add the recorder below `DownloadProgressRecorder`:

```swift
private final class DownloadActivityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [HuggingFaceDownloadActivity] = []

    var events: [HuggingFaceDownloadActivity] {
        lock.withLock { recordedEvents }
    }

    func append(_ activity: HuggingFaceDownloadActivity) {
        lock.withLock {
            recordedEvents.append(activity)
        }
    }
}
```

- [ ] **Step 6: Run installer forwarding test and verify red**

Run:

```bash
swift test --filter PythonBridgeTests/testHuggingFaceInstallerReportsDownloadActivityFromCommandOutput
```

Expected: FAIL because `install` has no `activityHandler` parameter.

- [ ] **Step 7: Add activity callback and start marker**

Change `HuggingFaceModelInstaller.install` signature in `Sources/MLXPythonBridge/HuggingFaceModels.swift` to:

```swift
public func install(
    modelID: String,
    pythonExecutable: URL,
    progressHandler: (@Sendable (HuggingFaceDownloadProgress) -> Void)? = nil,
    activityHandler: (@Sendable (HuggingFaceDownloadActivity) -> Void)? = nil
) async throws -> HuggingFaceInstallResult
```

Change the Python script body to:

```swift
let script = """
import json
import sys
from huggingface_hub import snapshot_download
print('MLXDashboard: Started Hugging Face snapshot download for \(modelID.replacingOccurrences(of: "'", with: "\\'"))', file=sys.stderr, flush=True)
path = snapshot_download(repo_id='\(modelID.replacingOccurrences(of: "'", with: "\\'"))')
print(json.dumps({'local_path': path}))
"""
```

Change the output handler block to:

```swift
let result = try await runner.run(Command(executableURL: pythonExecutable, arguments: ["-c", script])) { output in
    if let progress = HuggingFaceDownloadProgress.parse(from: output) {
        progressHandler?(progress)
    }
    for activity in HuggingFaceDownloadActivity.parse(from: output) {
        activityHandler?(activity)
    }
}
```

- [ ] **Step 8: Run bridge tests and verify green**

Run:

```bash
swift test --filter PythonBridgeTests
```

Expected: PASS.

- [ ] **Step 9: Commit bridge activity plumbing**

Run:

```bash
git add Sources/MLXPythonBridge/HuggingFaceModels.swift Tests/MLXPythonBridgeTests/PythonBridgeTests.swift
git commit -m "Add Hugging Face download activity events"
```

---

### Task 2: Cache And Xet Activity Monitoring

**Files:**
- Create: `Sources/MLXDashboardApp/DownloadActivityMonitor.swift`
- Test: `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Write failing cache summary tests**

Add these tests near the current model install progress tests in `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`:

```swift
func testDownloadCacheSamplerReportsSizeAndIncompleteBlobs() throws {
    let root = try temporaryDirectory()
    let repo = root.appending(path: "models--mlx-community--Tiny", directoryHint: .isDirectory)
    let blobs = repo.appending(path: "blobs", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: blobs.appending(path: "complete").path, contents: Data(repeating: 1, count: 4))
    FileManager.default.createFile(atPath: blobs.appending(path: "weights.safetensors.incomplete").path, contents: Data())

    let summary = try DownloadCacheSampler().summary(modelID: "mlx-community/Tiny", cacheRoot: root)

    XCTAssertEqual(summary.incompleteBlobCount, 1)
    XCTAssertEqual(summary.pendingFileNames, ["weights.safetensors.incomplete"])
    XCTAssertGreaterThanOrEqual(summary.totalBytes, 4)
}

func testDownloadCacheSummaryFormatsQuietStatus() {
    let summary = DownloadCacheSummary(
        totalBytes: 33 * 1024 * 1024,
        incompleteBlobCount: 3,
        pendingFileNames: ["a.incomplete", "b.incomplete", "c.incomplete"],
        secondsSinceGrowth: 45
    )

    XCTAssertEqual(summary.statusText, "Cache 33 MB • 3 incomplete blobs • no growth for 45s")
}
```

- [ ] **Step 2: Run cache summary tests and verify red**

Run:

```bash
swift test --filter DashboardViewModelTests/testDownloadCache
```

Expected: FAIL because the cache sampler and summary types do not exist.

- [ ] **Step 3: Add cache summary and sampler**

Create `Sources/MLXDashboardApp/DownloadActivityMonitor.swift`:

```swift
import Foundation
import MLXPythonBridge

struct DownloadCacheSummary: Equatable {
    var totalBytes: Int64
    var incompleteBlobCount: Int
    var pendingFileNames: [String]
    var secondsSinceGrowth: Int?

    var statusText: String {
        var parts = ["Cache \(Self.formatBytes(totalBytes))"]
        if incompleteBlobCount == 1 {
            parts.append("1 incomplete blob")
        } else {
            parts.append("\(incompleteBlobCount) incomplete blobs")
        }
        if let secondsSinceGrowth, secondsSinceGrowth >= 30 {
            parts.append("no growth for \(secondsSinceGrowth)s")
        }
        return parts.joined(separator: " • ")
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1024 / 1024
        if megabytes >= 1 {
            return "\(Int(megabytes.rounded())) MB"
        }
        let kilobytes = Double(bytes) / 1024
        if kilobytes >= 1 {
            return "\(Int(kilobytes.rounded())) KB"
        }
        return "\(bytes) B"
    }
}

struct DownloadCacheSampler {
    func summary(modelID: String, cacheRoot: URL, secondsSinceGrowth: Int? = nil) throws -> DownloadCacheSummary {
        let repo = cacheRoot.appending(path: repoFolderName(for: modelID), directoryHint: .isDirectory)
        var totalBytes: Int64 = 0
        var pendingNames: [String] = []

        guard let enumerator = FileManager.default.enumerator(
            at: repo,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return DownloadCacheSummary(totalBytes: 0, incompleteBlobCount: 0, pendingFileNames: [], secondsSinceGrowth: secondsSinceGrowth)
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            totalBytes += Int64(values.fileSize ?? 0)
            if url.lastPathComponent.hasSuffix(".incomplete") {
                pendingNames.append(url.lastPathComponent)
            }
        }

        return DownloadCacheSummary(
            totalBytes: totalBytes,
            incompleteBlobCount: pendingNames.count,
            pendingFileNames: pendingNames.sorted(),
            secondsSinceGrowth: secondsSinceGrowth
        )
    }

    private func repoFolderName(for modelID: String) -> String {
        "models--" + modelID.replacingOccurrences(of: "/", with: "--")
    }
}
```

- [ ] **Step 4: Run cache summary tests and verify green**

Run:

```bash
swift test --filter DashboardViewModelTests/testDownloadCache
```

Expected: PASS.

- [ ] **Step 5: Write failing Xet log reader test**

Add this test near the cache tests:

```swift
func testXetLogActivityReaderClassifiesConnectionStrugglingMessages() throws {
    let root = try temporaryDirectory()
    let logs = root.appending(path: "xet/logs", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let log = logs.appending(path: "xet_20260612.log")
    try #"{"fields":{"message":"Concurrency control for download: Decreased concurrency from 2 to 1; reason: success ratio below threshold (connection struggling)"}}"#
        .write(to: log, atomically: true, encoding: .utf8)

    let activities = try XetLogActivityReader().activities(logRoot: logs)

    XCTAssertEqual(activities, [
        HuggingFaceDownloadActivity(
            message: "Xet transfer: connection struggling, concurrency reduced",
            tone: .warning,
            source: .xetLog
        )
    ])
}
```

- [ ] **Step 6: Run Xet test and verify red**

Run:

```bash
swift test --filter DashboardViewModelTests/testXetLogActivityReaderClassifiesConnectionStrugglingMessages
```

Expected: FAIL because `XetLogActivityReader` does not exist.

- [ ] **Step 7: Add Xet log reader**

Append to `Sources/MLXDashboardApp/DownloadActivityMonitor.swift`:

```swift
struct XetLogActivityReader {
    func activities(logRoot: URL) throws -> [HuggingFaceDownloadActivity] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let newest = try files
            .map { url -> (URL, Date) in
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
                return (url, values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(2)
            .map(\.0)

        var activities: [HuggingFaceDownloadActivity] = []
        for file in newest {
            let text = try String(contentsOf: file, encoding: .utf8)
            activities.append(contentsOf: HuggingFaceDownloadActivity.parse(from: text))
        }
        var uniqueActivities: [HuggingFaceDownloadActivity] = []
        for activity in activities {
            if !uniqueActivities.contains(activity) {
                uniqueActivities.append(activity)
            }
        }
        return uniqueActivities
    }
}
```

- [ ] **Step 8: Run dashboard app tests and verify green**

Run:

```bash
swift test --filter DashboardViewModelTests/testDownloadCache
swift test --filter DashboardViewModelTests/testXetLogActivityReaderClassifiesConnectionStrugglingMessages
```

Expected: PASS.

- [ ] **Step 9: Commit cache and Xet monitor**

Run:

```bash
git add Sources/MLXDashboardApp/DownloadActivityMonitor.swift Tests/MLXDashboardAppTests/DashboardViewModelTests.swift
git commit -m "Add download cache activity monitoring"
```

---

### Task 3: Model Progress State And ViewModel Orchestration

**Files:**
- Modify: `Sources/MLXDashboardApp/ModelInstallProgress.swift`
- Modify: `Sources/MLXDashboardApp/DashboardViewModel.swift`
- Test: `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Write failing capped-history test**

Add this test near the existing `ModelInstallProgress` tests:

```swift
func testModelInstallProgressCapsActivityToLatestFiveEntries() {
    var progress = ModelInstallProgress(
        modelID: "mlx-community/Tiny",
        phase: .downloading,
        detail: "Downloading."
    )

    for index in 1...6 {
        progress = progress.appendingActivity(
            HuggingFaceDownloadActivity(message: "event \(index)", tone: .info, source: .commandOutput)
        )
    }

    XCTAssertEqual(progress.activities.map(\.message), ["event 2", "event 3", "event 4", "event 5", "event 6"])
}
```

- [ ] **Step 2: Run capped-history test and verify red**

Run:

```bash
swift test --filter DashboardViewModelTests/testModelInstallProgressCapsActivityToLatestFiveEntries
```

Expected: FAIL because `activities` and `appendingActivity` do not exist.

- [ ] **Step 3: Extend `ModelInstallProgress`**

In `Sources/MLXDashboardApp/ModelInstallProgress.swift`, update the struct:

```swift
struct ModelInstallProgress: Equatable {
    var modelID: String
    var phase: ModelInstallPhase
    var detail: String
    var downloadProgress: HuggingFaceDownloadProgress? = nil
    var cacheSummary: DownloadCacheSummary? = nil
    var activities: [HuggingFaceDownloadActivity] = []

    var title: String {
        phase.title
    }

    var stepText: String {
        phase.stepText
    }

    var fractionCompleted: Double {
        if phase == .downloading, let downloadProgress {
            return downloadProgress.fractionCompleted
        }
        return phase.fractionCompleted
    }

    var downloadStatusText: String? {
        guard phase == .downloading, let downloadProgress else { return nil }
        var parts = [downloadProgress.percentText]
        if let etaText = downloadProgress.etaText {
            parts.append("ETA \(etaText)")
        } else {
            parts.append("Calculating ETA")
        }
        if let rateText = downloadProgress.rateText {
            parts.append(rateText)
        }
        return parts.joined(separator: " • ")
    }

    var cacheStatusText: String? {
        guard phase == .downloading else { return nil }
        return cacheSummary?.statusText
    }

    func appendingActivity(_ activity: HuggingFaceDownloadActivity) -> ModelInstallProgress {
        var copy = self
        copy.activities.append(activity)
        if copy.activities.count > 5 {
            copy.activities = Array(copy.activities.suffix(5))
        }
        return copy
    }
}
```

- [ ] **Step 4: Run capped-history test and verify green**

Run:

```bash
swift test --filter DashboardViewModelTests/testModelInstallProgressCapsActivityToLatestFiveEntries
```

Expected: PASS.

- [ ] **Step 5: Write failing ViewModel activity forwarding test**

Add this async test near the install selected model tests:

```swift
func testInstallSelectedModelShowsDownloadActivityFromInstaller() async throws {
    let paths = try temporaryAppPaths()
    let python = paths.venvDirectory.appending(path: "bin/python")
    try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: python.path, contents: Data())

    let runner = FakeCommandRunner(results: [
        "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        "whoami": CommandResult(exitCode: 0, standardOutput: #"{"name":"octocat"}"#, standardError: ""),
        "install": CommandResult(
            exitCode: 0,
            standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
            standardError: "MLXDashboard: Started Hugging Face snapshot download for mlx-community/Tiny"
        )
    ])
    let viewModel = DashboardViewModel(
        settingsStore: SettingsStore(fileURL: paths.settingsFile),
        tokenStore: StubTokenStore(),
        registry: ModelRegistry(fileURL: paths.modelRegistryFile),
        environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
        modelInstaller: HuggingFaceModelInstaller(runner: runner),
        authChecker: HuggingFaceAuthChecker(runner: runner),
        huggingFaceCacheRoot: paths.applicationSupport.appending(path: "hub", directoryHint: .isDirectory)
    )
    viewModel.searchResults = [HuggingFaceModelSummary(id: "mlx-community/Tiny")]
    viewModel.selectedSearchModelID = "mlx-community/Tiny"

    await viewModel.installSelectedModel()
    await Task.yield()

    XCTAssertTrue(viewModel.modelInstallProgress?.activities.contains {
        $0.message == "Started Hugging Face snapshot download for mlx-community/Tiny"
    } == true)
}
```

- [ ] **Step 6: Run ViewModel activity test and verify red**

Run:

```bash
swift test --filter DashboardViewModelTests/testInstallSelectedModelShowsDownloadActivityFromInstaller
```

Expected: FAIL because the view model does not pass or preserve activity events.

- [ ] **Step 7: Preserve activity in progress updates**

In `Sources/MLXDashboardApp/DashboardViewModel.swift`, add properties:

```swift
private var activeDownloadMonitorTask: Task<Void, Never>?
private let downloadCacheSampler = DownloadCacheSampler()
private let xetLogActivityReader = XetLogActivityReader()
private var lastCacheByteCount: Int64?
private var lastCacheGrowthAt: Date?
private var emittedXetActivityMessages: Set<String> = []
```

Change `updateInstallProgress` to preserve activity and cache summary:

```swift
private func updateInstallProgress(
    _ phase: ModelInstallPhase,
    modelID: String,
    detail: String,
    downloadProgress: HuggingFaceDownloadProgress? = nil,
    cacheSummary: DownloadCacheSummary? = nil
) {
    let existing = modelInstallProgress
    modelInstallProgress = ModelInstallProgress(
        modelID: modelID,
        phase: phase,
        detail: detail,
        downloadProgress: downloadProgress,
        cacheSummary: cacheSummary ?? existing?.cacheSummary,
        activities: existing?.modelID == modelID ? existing?.activities ?? [] : []
    )
    modelInstallMessage = detail
}
```

Add:

```swift
private func appendInstallActivity(_ activity: HuggingFaceDownloadActivity, modelID: String, detail: String) {
    let current = modelInstallProgress ?? ModelInstallProgress(modelID: modelID, phase: .downloading, detail: detail)
    if current.activities.last == activity { return }
    modelInstallProgress = current.appendingActivity(activity)
    modelInstallMessage = detail
}
```

Change the installer call to pass activity events:

```swift
let result = try await modelInstaller.install(
    modelID: model.id,
    pythonExecutable: status.pythonExecutable,
    progressHandler: { [weak self] progress in
        Task { @MainActor [weak self] in
            self?.updateInstallProgress(
                .downloading,
                modelID: model.id,
                detail: downloadDetail,
                downloadProgress: progress
            )
        }
    },
    activityHandler: { [weak self] activity in
        Task { @MainActor [weak self] in
            self?.appendInstallActivity(activity, modelID: model.id, detail: downloadDetail)
        }
    }
)
```

- [ ] **Step 8: Run ViewModel activity test and verify green**

Run:

```bash
swift test --filter DashboardViewModelTests/testInstallSelectedModelShowsDownloadActivityFromInstaller
```

Expected: PASS.

- [ ] **Step 9: Add monitor task implementation**

In `DashboardViewModel.installModel`, after `updateInstallProgress(.downloading...)`, call:

```swift
startDownloadActivityMonitor(modelID: model.id, detail: downloadDetail)
defer { stopDownloadActivityMonitor() }
```

Add methods:

```swift
private func startDownloadActivityMonitor(modelID: String, detail: String) {
    stopDownloadActivityMonitor()
    lastCacheByteCount = nil
    lastCacheGrowthAt = Date()
    emittedXetActivityMessages = []
    activeDownloadMonitorTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
            self?.sampleDownloadActivity(modelID: modelID, detail: detail)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

private func stopDownloadActivityMonitor() {
    activeDownloadMonitorTask?.cancel()
    activeDownloadMonitorTask = nil
    lastCacheByteCount = nil
    lastCacheGrowthAt = nil
    emittedXetActivityMessages = []
}

private func sampleDownloadActivity(modelID: String, detail: String) {
    let now = Date()
    let previousBytes = lastCacheByteCount
    let growthAt = lastCacheGrowthAt ?? now
    let quietSeconds = Int(now.timeIntervalSince(growthAt))

    do {
        let baseSummary = try downloadCacheSampler.summary(modelID: modelID, cacheRoot: huggingFaceCacheRoot)
        if previousBytes == nil || baseSummary.totalBytes > (previousBytes ?? 0) {
            lastCacheGrowthAt = now
        }
        lastCacheByteCount = baseSummary.totalBytes
        let secondsSinceGrowth = Int(now.timeIntervalSince(lastCacheGrowthAt ?? now))
        let summary = DownloadCacheSummary(
            totalBytes: baseSummary.totalBytes,
            incompleteBlobCount: baseSummary.incompleteBlobCount,
            pendingFileNames: baseSummary.pendingFileNames,
            secondsSinceGrowth: secondsSinceGrowth >= 30 ? secondsSinceGrowth : nil
        )
        updateInstallProgress(.downloading, modelID: modelID, detail: detail, cacheSummary: summary)

        if quietSeconds >= 30 {
            appendInstallActivity(
                HuggingFaceDownloadActivity(message: "No cache growth for \(quietSeconds)s", tone: .warning, source: .cacheScan),
                modelID: modelID,
                detail: detail
            )
        }
    } catch {
        appendInstallActivity(
            HuggingFaceDownloadActivity(message: "Cache activity unavailable: \(error)", tone: .warning, source: .cacheScan),
            modelID: modelID,
            detail: detail
        )
    }

    let xetLogRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".cache/huggingface/xet/logs", directoryHint: .isDirectory)
    if let activities = try? xetLogActivityReader.activities(logRoot: xetLogRoot) {
        for activity in activities {
            guard !emittedXetActivityMessages.contains(activity.message) else { continue }
            emittedXetActivityMessages.insert(activity.message)
            appendInstallActivity(activity, modelID: modelID, detail: detail)
        }
    }
}
```

- [ ] **Step 10: Run dashboard tests and verify green**

Run:

```bash
swift test --filter DashboardViewModelTests
```

Expected: PASS.

- [ ] **Step 11: Commit progress state and orchestration**

Run:

```bash
git add Sources/MLXDashboardApp/ModelInstallProgress.swift Sources/MLXDashboardApp/DashboardViewModel.swift Tests/MLXDashboardAppTests/DashboardViewModelTests.swift
git commit -m "Show download activity in install progress state"
```

---

### Task 4: Always-Visible SwiftUI Readout

**Files:**
- Modify: `Sources/MLXDashboardApp/ContentView.swift`
- Test: `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Write failing status text test**

Add this test near `testDownloadProgressUsesTransferPercentETAAndRate`:

```swift
func testModelInstallProgressExposesCacheAndActivityStatusText() {
    let progress = ModelInstallProgress(
        modelID: "mlx-community/Tiny",
        phase: .downloading,
        detail: "Downloading.",
        cacheSummary: DownloadCacheSummary(
            totalBytes: 33 * 1024 * 1024,
            incompleteBlobCount: 3,
            pendingFileNames: ["a.incomplete", "b.incomplete", "c.incomplete"],
            secondsSinceGrowth: 45
        ),
        activities: [
            HuggingFaceDownloadActivity(message: "Xet transfer: connection struggling, concurrency reduced", tone: .warning, source: .xetLog)
        ]
    )

    XCTAssertEqual(progress.cacheStatusText, "Cache 33 MB • 3 incomplete blobs • no growth for 45s")
    XCTAssertEqual(progress.activityMessages, ["Xet transfer: connection struggling, concurrency reduced"])
}
```

- [ ] **Step 2: Run status text test and verify red**

Run:

```bash
swift test --filter DashboardViewModelTests/testModelInstallProgressExposesCacheAndActivityStatusText
```

Expected: FAIL because `activityMessages` does not exist.

- [ ] **Step 3: Add activity message computed property**

In `Sources/MLXDashboardApp/ModelInstallProgress.swift`, add:

```swift
var activityMessages: [String] {
    activities.map(\.message)
}
```

- [ ] **Step 4: Run status text test and verify green**

Run:

```bash
swift test --filter DashboardViewModelTests/testModelInstallProgressExposesCacheAndActivityStatusText
```

Expected: PASS.

- [ ] **Step 5: Render cache and activity in the banner**

In `Sources/MLXDashboardApp/ContentView.swift`, update `InstallProgressBanner.body` after the `ProgressView`:

```swift
ProgressView(value: progress.fractionCompleted)
    .tint(tintColor)
if let cacheStatusText = progress.cacheStatusText {
    Text(cacheStatusText)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
}
if !progress.activityMessages.isEmpty {
    VStack(alignment: .leading, spacing: 3) {
        ForEach(progress.activityMessages, id: \.self) { message in
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
Text(progress.detail)
    .font(.caption)
    .foregroundStyle(.secondary)
    .textSelection(.enabled)
    .lineLimit(2)
```

Remove the older duplicate `Text(progress.detail)` block if necessary so detail only appears once.

- [ ] **Step 6: Run app tests and verify green**

Run:

```bash
swift test --filter DashboardViewModelTests
```

Expected: PASS.

- [ ] **Step 7: Commit UI readout**

Run:

```bash
git add Sources/MLXDashboardApp/ContentView.swift Sources/MLXDashboardApp/ModelInstallProgress.swift Tests/MLXDashboardAppTests/DashboardViewModelTests.swift
git commit -m "Render always-visible download activity"
```

---

### Task 5: Final Verification

**Files:**
- Verify full package.
- Optionally run app for manual visual check.

- [ ] **Step 1: Run full tests**

Run:

```bash
swift test
```

Expected: PASS with no failing tests.

- [ ] **Step 2: Build app**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 3: Optional manual smoke**

Run:

```bash
./scripts/run.sh
```

Expected: app launches; during a model install, the banner shows cache status and recent activity lines under the progress bar.

- [ ] **Step 4: Final status check**

Run:

```bash
git status --short
```

Expected: only intentional files changed, or clean if every task was committed.
