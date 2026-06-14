# Per-Model Install Progress History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make install progress and install log details recoverable by selecting the model row later, while keeping active install progress visible and improving fallback progress presentation.

**Architecture:** Store install progress by exact model ID in `DashboardViewModel`, with `modelInstallProgress` acting as the active-install compatibility view. Keep callback guards session-based so stale download callbacks cannot mutate current progress. Render the selected model's stored progress in Installed, and render compact activity previews from the same `ModelInstallProgress` data.

**Tech Stack:** Swift, SwiftUI, XCTest, existing MLXDashboard Swift Package targets.

---

## File Map

- Modify `Sources/MLXDashboardApp/ModelInstallProgress.swift`
  - Add separate full activity history and compact preview behavior.
  - Add explicit progress rendering state for determinate, indeterminate download, and phase fallback.
- Modify `Sources/MLXDashboardApp/DashboardViewModel.swift`
  - Add `installProgressByModelID` and `activeInstallModelID`.
  - Route all install progress writes through per-model storage.
  - Preserve per-model progress during unrelated actions.
  - Expose selected installed model progress for the Installed view.
- Modify `Sources/MLXDashboardApp/ContentView.swift`
  - Keep Discover's active install banner.
  - Show selected-model progress details in Installed when selected progress exists.
  - Let banner use compact preview rows and selected detail use a longer log.
- Modify `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`
  - Add view-model behavior tests for per-model progress history, clearing rules, callbacks, and selected progress.
- Modify `Tests/MLXDashboardAppTests/ContentViewTests.swift` only if existing UI snapshot or policy tests already cover this area. If no such tests exist, keep UI coverage in view-model and model tests.

---

### Task 1: Model Install Progress History And Display State

**Files:**
- Modify: `Sources/MLXDashboardApp/ModelInstallProgress.swift`
- Test: `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Write failing tests for activity history and compact preview**

Add tests near the existing `ModelInstallProgress` tests:

```swift
func testModelInstallProgressRetainsFiftyActivitiesAndPreviewsLatestFive() {
    var progress = ModelInstallProgress(
        modelID: "mlx-community/Tiny",
        phase: .downloading,
        detail: "Downloading"
    )

    for index in 1...60 {
        progress = progress.appendingActivity(
            HuggingFaceDownloadActivity(
                message: "event \(index)",
                tone: .info,
                source: .commandOutput
            )
        )
    }

    XCTAssertEqual(progress.activities.count, 50)
    XCTAssertEqual(progress.activities.first?.message, "event 11")
    XCTAssertEqual(progress.activities.last?.message, "event 60")
    XCTAssertEqual(progress.activityRows.map(\.message), ["event 56", "event 57", "event 58", "event 59", "event 60"])
    XCTAssertEqual(progress.fullActivityRows.count, 50)
}

func testModelInstallProgressShowsActivityRowsForTerminalPhases() {
    let progress = ModelInstallProgress(
        modelID: "mlx-community/Tiny",
        phase: .failed,
        detail: "Install failed",
        activities: [
            HuggingFaceDownloadActivity(message: "Downloading config", tone: .info, source: .commandOutput)
        ]
    )

    XCTAssertEqual(progress.activityRows.map(\.message), ["Downloading config"])
    XCTAssertEqual(progress.fullActivityRows.map(\.message), ["Downloading config"])
}

func testModelInstallProgressDisplayModeUsesDeterminateIndeterminateAndPhaseFallback() {
    let waiting = ModelInstallProgress(
        modelID: "mlx-community/Tiny",
        phase: .downloading,
        detail: "Downloading"
    )
    XCTAssertEqual(waiting.progressDisplayMode, .indeterminateDownload)

    let transfer = ModelInstallProgress(
        modelID: "mlx-community/Tiny",
        phase: .downloading,
        detail: "Downloading",
        downloadProgress: HuggingFaceDownloadProgress(
            fractionCompleted: 0.42,
            percentText: "42%",
            etaText: "7m 12s",
            rateText: "13.4MB/s"
        )
    )
    XCTAssertEqual(transfer.progressDisplayMode, .determinate(value: 0.42))

    let preparing = ModelInstallProgress(
        modelID: "mlx-community/Tiny",
        phase: .preparing,
        detail: "Preparing"
    )
    XCTAssertEqual(preparing.progressDisplayMode, .phaseFallback(value: 0.08))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter 'DashboardViewModelTests/testModelInstallProgressRetainsFiftyActivitiesAndPreviewsLatestFive|DashboardViewModelTests/testModelInstallProgressShowsActivityRowsForTerminalPhases|DashboardViewModelTests/testModelInstallProgressDisplayModeUsesDeterminateIndeterminateAndPhaseFallback'
```

Expected:
- FAIL because `fullActivityRows` and `progressDisplayMode` do not exist.
- Existing cap is 5 rather than 50.
- Existing `activityRows` hides terminal-phase activity.

- [ ] **Step 3: Implement model progress display state**

In `Sources/MLXDashboardApp/ModelInstallProgress.swift`, add this enum above `ModelInstallProgress`:

```swift
enum ModelInstallProgressDisplayMode: Equatable {
    case determinate(value: Double)
    case indeterminateDownload
    case phaseFallback(value: Double)
}
```

Update `ModelInstallProgress`:

```swift
private let activityHistoryLimit = 50
private let compactActivityLimit = 5

var progressDisplayMode: ModelInstallProgressDisplayMode {
    if phase == .downloading {
        if let downloadProgress {
            return .determinate(value: downloadProgress.fractionCompleted)
        }
        return .indeterminateDownload
    }
    return .phaseFallback(value: phase.fractionCompleted)
}

var activityRows: [ActivityRow] {
    compactActivityRows(from: activities)
}

var fullActivityRows: [ActivityRow] {
    activities.enumerated().map { offset, activity in
        ActivityRow(id: offset, message: activity.message)
    }
}

private func compactActivityRows(from activities: [HuggingFaceDownloadActivity]) -> [ActivityRow] {
    let startID = max(activities.count - compactActivityLimit, 0)
    return activities
        .suffix(compactActivityLimit)
        .enumerated()
        .map { offset, activity in
            ActivityRow(id: startID + offset, message: activity.message)
        }
}

func appendingActivity(_ activity: HuggingFaceDownloadActivity) -> ModelInstallProgress {
    guard activities.last != activity else { return self }

    var copy = self
    copy.activities.append(activity)
    if copy.activities.count > activityHistoryLimit {
        copy.activities = Array(copy.activities.suffix(activityHistoryLimit))
    }
    return copy
}
```

Remove the old `guard phase == .downloading else { return [] }` from `activityRows`.

- [ ] **Step 4: Run focused tests to verify they pass**

Run:

```bash
swift test --filter 'DashboardViewModelTests/testModelInstallProgressRetainsFiftyActivitiesAndPreviewsLatestFive|DashboardViewModelTests/testModelInstallProgressShowsActivityRowsForTerminalPhases|DashboardViewModelTests/testModelInstallProgressDisplayModeUsesDeterminateIndeterminateAndPhaseFallback'
```

Expected: PASS.

- [ ] **Step 5: Run existing progress tests**

Run:

```bash
swift test --filter 'DashboardViewModelTests/testModelInstallProgress'
```

Expected: PASS. If tests asserting latest-five storage now fail, update them to assert latest-five preview and 50-row stored history.

- [ ] **Step 6: Commit**

```bash
git add Sources/MLXDashboardApp/ModelInstallProgress.swift Tests/MLXDashboardAppTests/DashboardViewModelTests.swift
git commit -m "Track richer install progress activity history"
```

---

### Task 2: Per-Model Progress Store In DashboardViewModel

**Files:**
- Modify: `Sources/MLXDashboardApp/DashboardViewModel.swift`
- Test: `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Write failing tests for per-model storage and selected progress**

Add tests near install-progress view-model tests:

```swift
func testInstallProgressIsStoredByModelIDAndExposedForSelectedInstalledModel() async throws {
    let paths = try temporaryAppPaths()
    let viewModel = DashboardViewModel(
        settingsStore: SettingsStore(fileURL: paths.settingsFile),
        registry: ModelRegistry(fileURL: paths.modelRegistryFile),
        environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
    )
    let progress = ModelInstallProgress(
        modelID: "mlx-community/Tiny",
        phase: .downloading,
        detail: "Downloading"
    )

    viewModel.setInstallProgressForTesting(progress)
    viewModel.selectedInstalledModelID = "mlx-community/Tiny"

    XCTAssertEqual(viewModel.installProgressByModelID["mlx-community/Tiny"], progress)
    XCTAssertEqual(viewModel.selectedInstalledModelProgress, progress)
    XCTAssertEqual(viewModel.modelInstallProgress, progress)
}

func testSelectedInstalledModelProgressCanDifferFromActiveInstallProgress() async throws {
    let paths = try temporaryAppPaths()
    let viewModel = DashboardViewModel(
        settingsStore: SettingsStore(fileURL: paths.settingsFile),
        registry: ModelRegistry(fileURL: paths.modelRegistryFile),
        environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
    )
    let active = ModelInstallProgress(modelID: "mlx-community/Active", phase: .downloading, detail: "Active")
    let selected = ModelInstallProgress(modelID: "mlx-community/Selected", phase: .failed, detail: "Failed")

    viewModel.setInstallProgressForTesting(active)
    viewModel.setInstallProgressForTesting(selected, makeActive: false)
    viewModel.selectedInstalledModelID = "mlx-community/Selected"

    XCTAssertEqual(viewModel.modelInstallProgress, active)
    XCTAssertEqual(viewModel.selectedInstalledModelProgress, selected)
}
```

Add this test-only helper inside the existing `@testable` access context by making it `internal` in production:

```swift
func setInstallProgressForTesting(_ progress: ModelInstallProgress, makeActive: Bool = true) {
    setInstallProgress(progress, makeActive: makeActive)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter 'DashboardViewModelTests/testInstallProgressIsStoredByModelIDAndExposedForSelectedInstalledModel|DashboardViewModelTests/testSelectedInstalledModelProgressCanDifferFromActiveInstallProgress'
```

Expected:
- FAIL because `installProgressByModelID`, `selectedInstalledModelProgress`, and `setInstallProgressForTesting` do not exist.

- [ ] **Step 3: Add per-model storage properties**

In `DashboardViewModel`, replace the stored published progress:

```swift
@Published var modelInstallProgress: ModelInstallProgress?
```

with:

```swift
@Published private(set) var installProgressByModelID: [String: ModelInstallProgress] = [:]
@Published private(set) var activeInstallModelID: String?

var modelInstallProgress: ModelInstallProgress? {
    guard let activeInstallModelID else { return nil }
    return installProgressByModelID[activeInstallModelID]
}

var selectedInstalledModelProgress: ModelInstallProgress? {
    guard let selectedInstalledModelID else { return nil }
    return installProgressByModelID[selectedInstalledModelID]
}
```

Keep these `internal` rather than `private` so tests can inspect them through `@testable`.

- [ ] **Step 4: Add write helpers**

Add helpers near existing install-progress private methods:

```swift
func setInstallProgressForTesting(_ progress: ModelInstallProgress, makeActive: Bool = true) {
    setInstallProgress(progress, makeActive: makeActive)
}

private func setInstallProgress(_ progress: ModelInstallProgress, makeActive: Bool) {
    installProgressByModelID[progress.modelID] = progress
    if makeActive {
        activeInstallModelID = progress.modelID
    }
}

private func clearInstallProgress(for modelID: String) {
    installProgressByModelID[modelID] = nil
    if activeInstallModelID == modelID {
        activeInstallModelID = nil
    }
}

private func clearActiveInstallProgress() {
    guard let activeInstallModelID else { return }
    clearInstallProgress(for: activeInstallModelID)
}
```

The test helper is intentionally simple and internal. If preferred, wrap it in a `#if DEBUG` block only if the project already uses that pattern.

- [ ] **Step 5: Update existing progress reads**

Keep existing read call sites mostly unchanged because `modelInstallProgress` remains computed:

```swift
var canContinueLastModelInstall: Bool {
    guard !isInstallingModel,
          let progress = modelInstallProgress
    else { return false }
    return progress.phase.canContinueDownloading
}
```

No change is needed for read-only uses like `modelInstallProgress?.modelID`.

- [ ] **Step 6: Update `updateInstallProgress` to write by model ID**

Replace the existing body with:

```swift
private func updateInstallProgress(
    _ phase: ModelInstallPhase,
    modelID: String,
    detail: String,
    downloadProgress: HuggingFaceDownloadProgress? = nil
) {
    let existingProgress = installProgressByModelID[modelID]
    if phase == .downloading, existingProgress?.phase.isTerminalInstallPhase == true {
        return
    }
    let progress = ModelInstallProgress(
        modelID: modelID,
        phase: phase,
        detail: detail,
        downloadProgress: phase == .downloading ? (downloadProgress ?? existingProgress?.downloadProgress) : downloadProgress,
        cacheSummary: existingProgress?.cacheSummary,
        activities: existingProgress?.activities ?? []
    )
    setInstallProgress(progress, makeActive: true)
    modelInstallMessage = detail
}
```

- [ ] **Step 7: Update activity and cache callbacks**

Replace `appendInstallActivity` body with:

```swift
private func appendInstallActivity(
    _ activity: HuggingFaceDownloadActivity,
    modelID: String,
    installSessionID: Int? = nil
) {
    if let installSessionID {
        guard canApplyDownloadCallback(modelID: modelID, installSessionID: installSessionID) else { return }
    }
    guard let progress = installProgressByModelID[modelID] else { return }
    setInstallProgress(progress.appendingActivity(activity), makeActive: activeInstallModelID == modelID)
}
```

Replace `updateInstallCacheSummary` body with:

```swift
private func updateInstallCacheSummary(_ cacheSummary: DownloadCacheSummary, modelID: String) {
    guard var progress = installProgressByModelID[modelID] else { return }
    progress.cacheSummary = cacheSummary
    setInstallProgress(progress, makeActive: activeInstallModelID == modelID)
}
```

- [ ] **Step 8: Update callback guard**

Replace `canApplyDownloadCallback` with:

```swift
private func canApplyDownloadCallback(modelID: String, installSessionID: Int) -> Bool {
    activeInstallSessionID == installSessionID
        && activeInstallModelID == modelID
        && installProgressByModelID[modelID]?.phase == .downloading
}
```

- [ ] **Step 9: Replace direct `modelInstallProgress = nil` writes**

Replace direct nil assignment in "no selection" or unrelated-action paths with either message-only updates or targeted clears:

```swift
// No selected search model:
modelInstallMessage = "Select a model from search results before installing."

// No selected failed/incomplete model:
modelInstallMessage = "Select a failed or incomplete model before continuing."

// Set active / assign role:
modelInstallMessage = "Selected \(selectedInstalledModelID) as the active model."
// Do not clear progress.

// Delete selected model:
clearInstallProgress(for: selectedInstalledModelID)
```

Use `clearActiveInstallProgress()` only for behavior that truly discards the active entry. Do not use it for login checks, role assignment, workspace selection, or set-active actions.

- [ ] **Step 10: Run focused tests**

Run:

```bash
swift test --filter 'DashboardViewModelTests/testInstallProgressIsStoredByModelIDAndExposedForSelectedInstalledModel|DashboardViewModelTests/testSelectedInstalledModelProgressCanDifferFromActiveInstallProgress'
```

Expected: PASS.

- [ ] **Step 11: Run existing install tests**

Run:

```bash
swift test --filter 'DashboardViewModelTests/testInstall'
```

Expected: PASS after updating tests that were asserting `modelInstallProgress == nil` for unrelated actions.

- [ ] **Step 12: Commit**

```bash
git add Sources/MLXDashboardApp/DashboardViewModel.swift Tests/MLXDashboardAppTests/DashboardViewModelTests.swift
git commit -m "Store install progress per model"
```

---

### Task 3: Preserve Progress Across Unrelated Actions And Clear On Delete

**Files:**
- Modify: `Sources/MLXDashboardApp/DashboardViewModel.swift`
- Test: `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Write failing tests for clearing rules**

Add tests near existing set-active, role-assignment, and delete tests:

```swift
func testSetSelectedInstalledModelActiveDoesNotClearInstallProgressHistory() throws {
    let paths = try temporaryAppPaths()
    let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
    registry.upsert(ModelRecord(id: "mlx-community/Tiny", localPath: "/tmp/tiny", status: .installed))
    try registry.save()
    let viewModel = DashboardViewModel(
        settingsStore: SettingsStore(fileURL: paths.settingsFile),
        registry: registry,
        environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
    )
    let progress = ModelInstallProgress(modelID: "mlx-community/Tiny", phase: .installed, detail: "Installed")
    viewModel.setInstallProgressForTesting(progress)
    viewModel.selectedInstalledModelID = "mlx-community/Tiny"

    viewModel.setSelectedInstalledModelActive()

    XCTAssertEqual(viewModel.installProgressByModelID["mlx-community/Tiny"], progress)
    XCTAssertEqual(viewModel.selectedInstalledModelProgress, progress)
}

func testAssignSelectedInstalledModelToRoleDoesNotClearInstallProgressHistory() throws {
    let paths = try temporaryAppPaths()
    let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
    registry.upsert(ModelRecord(id: "mlx-community/Tiny", localPath: "/tmp/tiny", status: .installed))
    try registry.save()
    let viewModel = DashboardViewModel(
        settingsStore: SettingsStore(fileURL: paths.settingsFile),
        registry: registry,
        environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
    )
    let progress = ModelInstallProgress(modelID: "mlx-community/Tiny", phase: .installed, detail: "Installed")
    viewModel.setInstallProgressForTesting(progress)
    viewModel.selectedInstalledModelID = "mlx-community/Tiny"

    viewModel.assignSelectedInstalledModel(to: .ask)

    XCTAssertEqual(viewModel.installProgressByModelID["mlx-community/Tiny"], progress)
    XCTAssertEqual(viewModel.selectedInstalledModelProgress, progress)
}

func testDeleteSelectedInstalledModelClearsOnlyThatModelsProgressHistory() throws {
    let paths = try temporaryAppPaths()
    let cacheRoot = try temporaryDirectory()
    let tinyRepo = cacheRoot.appending(path: "models--mlx-community--Tiny/snapshots/abc123", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tinyRepo, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: tinyRepo.appending(path: "config.json").path, contents: Data())
    let registry = ModelRegistry(fileURL: paths.modelRegistryFile)
    registry.upsert(ModelRecord(id: "mlx-community/Tiny", localPath: tinyRepo.path, status: .installed))
    registry.upsert(ModelRecord(id: "mlx-community/Other", localPath: "/tmp/other", status: .installed))
    try registry.save()
    let viewModel = DashboardViewModel(
        settingsStore: SettingsStore(fileURL: paths.settingsFile),
        registry: registry,
        environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:])),
        huggingFaceCacheRoot: cacheRoot
    )
    viewModel.setInstallProgressForTesting(ModelInstallProgress(modelID: "mlx-community/Tiny", phase: .installed, detail: "Tiny"))
    viewModel.setInstallProgressForTesting(ModelInstallProgress(modelID: "mlx-community/Other", phase: .installed, detail: "Other"))
    viewModel.selectedInstalledModelID = "mlx-community/Tiny"

    viewModel.deleteSelectedInstalledModelFromCache()

    XCTAssertNil(viewModel.installProgressByModelID["mlx-community/Tiny"])
    XCTAssertNotNil(viewModel.installProgressByModelID["mlx-community/Other"])
}
```

- [ ] **Step 2: Run tests to verify they fail where behavior is still old**

Run:

```bash
swift test --filter 'DashboardViewModelTests/testSetSelectedInstalledModelActiveDoesNotClearInstallProgressHistory|DashboardViewModelTests/testAssignSelectedInstalledModelToRoleDoesNotClearInstallProgressHistory|DashboardViewModelTests/testDeleteSelectedInstalledModelClearsOnlyThatModelsProgressHistory'
```

Expected:
- FAIL until direct progress clearing is removed from unrelated actions and added to delete.

- [ ] **Step 3: Remove unrelated clears**

In `setSelectedInstalledModelActive`, remove:

```swift
modelInstallProgress = nil
```

In `assignSelectedInstalledModel(to:)`, remove:

```swift
modelInstallProgress = nil
```

In delete paths, replace broad clears with:

```swift
clearInstallProgress(for: selectedInstalledModelID)
```

Only apply it after a valid selected model ID is known.

- [ ] **Step 4: Run focused tests**

Run:

```bash
swift test --filter 'DashboardViewModelTests/testSetSelectedInstalledModelActiveDoesNotClearInstallProgressHistory|DashboardViewModelTests/testAssignSelectedInstalledModelToRoleDoesNotClearInstallProgressHistory|DashboardViewModelTests/testDeleteSelectedInstalledModelClearsOnlyThatModelsProgressHistory'
```

Expected: PASS.

- [ ] **Step 5: Run related existing tests**

Run:

```bash
swift test --filter 'DashboardViewModelTests/testDeleteSelectedInstalledModel|DashboardViewModelTests/testAssignSelectedInstalledModel|DashboardViewModelTests/testRunningProviderUsesActiveModel'
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MLXDashboardApp/DashboardViewModel.swift Tests/MLXDashboardAppTests/DashboardViewModelTests.swift
git commit -m "Preserve install progress during model actions"
```

---

### Task 4: Installed Workspace Selected-Model Progress Detail

**Files:**
- Modify: `Sources/MLXDashboardApp/ContentView.swift`
- Test: `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Write failing test for selected progress accessor fallback**

Add a view-model test that covers the display decision without testing SwiftUI rendering:

```swift
func testInstalledProgressPrefersSelectedModelProgressOverActiveProgressForDetail() throws {
    let paths = try temporaryAppPaths()
    let viewModel = DashboardViewModel(
        settingsStore: SettingsStore(fileURL: paths.settingsFile),
        registry: ModelRegistry(fileURL: paths.modelRegistryFile),
        environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
    )
    let active = ModelInstallProgress(modelID: "mlx-community/Active", phase: .downloading, detail: "Active")
    let selected = ModelInstallProgress(modelID: "mlx-community/Selected", phase: .failed, detail: "Selected failed")

    viewModel.setInstallProgressForTesting(active)
    viewModel.setInstallProgressForTesting(selected, makeActive: false)
    viewModel.selectedInstalledModelID = "mlx-community/Selected"

    XCTAssertEqual(viewModel.installedWorkspacePrimaryProgress, selected)
    XCTAssertEqual(viewModel.modelInstallProgress, active)
}

func testInstalledProgressFallsBackToActiveProgressWhenSelectedHasNoHistory() throws {
    let paths = try temporaryAppPaths()
    let viewModel = DashboardViewModel(
        settingsStore: SettingsStore(fileURL: paths.settingsFile),
        registry: ModelRegistry(fileURL: paths.modelRegistryFile),
        environmentManager: PythonEnvironmentManager(paths: paths, runner: FakeCommandRunner(results: [:]))
    )
    let active = ModelInstallProgress(modelID: "mlx-community/Active", phase: .downloading, detail: "Active")

    viewModel.setInstallProgressForTesting(active)
    viewModel.selectedInstalledModelID = "mlx-community/Other"

    XCTAssertEqual(viewModel.installedWorkspacePrimaryProgress, active)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter 'DashboardViewModelTests/testInstalledProgressPrefersSelectedModelProgressOverActiveProgressForDetail|DashboardViewModelTests/testInstalledProgressFallsBackToActiveProgressWhenSelectedHasNoHistory'
```

Expected: FAIL because `installedWorkspacePrimaryProgress` does not exist.

- [ ] **Step 3: Add display accessor**

In `DashboardViewModel`, add:

```swift
var installedWorkspacePrimaryProgress: ModelInstallProgress? {
    selectedInstalledModelProgress ?? modelInstallProgress
}
```

- [ ] **Step 4: Update Installed UI to use selected-model detail**

In `InstalledModelsView`, replace:

```swift
if let progress = viewModel.modelInstallProgress {
    InstallProgressBanner(progress: progress)
} else if let message = viewModel.modelInstallMessage {
    Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
}
```

with:

```swift
if let progress = viewModel.installedWorkspacePrimaryProgress {
    InstallProgressBanner(progress: progress, showsFullActivity: progress.modelID == viewModel.selectedInstalledModelID)
} else if let message = viewModel.modelInstallMessage {
    Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
}
```

Keep Discover using active install progress:

```swift
if let progress = viewModel.modelInstallProgress {
    InstallProgressBanner(progress: progress)
}
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
swift test --filter 'DashboardViewModelTests/testInstalledProgressPrefersSelectedModelProgressOverActiveProgressForDetail|DashboardViewModelTests/testInstalledProgressFallsBackToActiveProgressWhenSelectedHasNoHistory'
```

Expected: PASS.

- [ ] **Step 6: Build**

Run:

```bash
swift build
```

Expected: PASS. Fix any SwiftUI signature errors from `InstallProgressBanner` changes in Task 5 if implementing together.

- [ ] **Step 7: Commit**

```bash
git add Sources/MLXDashboardApp/ContentView.swift Sources/MLXDashboardApp/DashboardViewModel.swift Tests/MLXDashboardAppTests/DashboardViewModelTests.swift
git commit -m "Show selected model install progress"
```

---

### Task 5: Install Progress Banner Rendering Modes

**Files:**
- Modify: `Sources/MLXDashboardApp/ContentView.swift`
- Test: `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Write focused model tests if Task 1 did not add display mode coverage**

If Task 1 already added `testModelInstallProgressDisplayModeUsesDeterminateIndeterminateAndPhaseFallback`, skip this step. Otherwise add it exactly as listed in Task 1.

- [ ] **Step 2: Update `InstallProgressBanner` signature**

Change:

```swift
private struct InstallProgressBanner: View {
    let progress: ModelInstallProgress
```

to:

```swift
private struct InstallProgressBanner: View {
    let progress: ModelInstallProgress
    var showsFullActivity = false
```

- [ ] **Step 3: Render progress using explicit mode**

Replace:

```swift
if progress.isWaitingForDownloadData {
    ProgressView()
        .controlSize(.small)
        .tint(tintColor)
} else {
    ProgressView(value: progress.fractionCompleted)
        .tint(tintColor)
}
```

with:

```swift
switch progress.progressDisplayMode {
case .determinate(let value), .phaseFallback(let value):
    ProgressView(value: value)
        .tint(tintColor)
case .indeterminateDownload:
    ProgressView()
        .controlSize(.small)
        .tint(tintColor)
}
```

- [ ] **Step 4: Render compact or full activity rows**

Replace:

```swift
if !progress.activityRows.isEmpty {
    VStack(alignment: .leading, spacing: 3) {
        ForEach(progress.activityRows) { row in
            Text(row.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
```

with:

```swift
let rows = showsFullActivity ? progress.fullActivityRows : progress.activityRows
if !rows.isEmpty {
    VStack(alignment: .leading, spacing: 3) {
        ForEach(rows) { row in
            Text(row.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(showsFullActivity ? 2 : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
```

If SwiftUI complains about `let rows` inside `body`, extract:

```swift
private var displayedActivityRows: [ModelInstallProgress.ActivityRow] {
    showsFullActivity ? progress.fullActivityRows : progress.activityRows
}
```

and use `displayedActivityRows` in `body`.

- [ ] **Step 5: Run model display tests**

Run:

```bash
swift test --filter 'DashboardViewModelTests/testModelInstallProgressDisplayModeUsesDeterminateIndeterminateAndPhaseFallback|DashboardViewModelTests/testModelInstallProgressRetainsFiftyActivitiesAndPreviewsLatestFive'
```

Expected: PASS.

- [ ] **Step 6: Build**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/MLXDashboardApp/ContentView.swift Sources/MLXDashboardApp/ModelInstallProgress.swift Tests/MLXDashboardAppTests/DashboardViewModelTests.swift
git commit -m "Improve install progress presentation"
```

---

### Task 6: Final Verification

**Files:**
- No new code unless verification uncovers failures.

- [ ] **Step 1: Run full test suite**

Run:

```bash
swift test
```

Expected:
- Build completes.
- All tests pass.
- Expected current count is at least 191 tests.

- [ ] **Step 2: Run build**

Run:

```bash
swift build
```

Expected: Build complete with exit code 0.

- [ ] **Step 3: Inspect git diff**

Run:

```bash
git status --short
git diff --stat
```

Expected:
- Only files from this plan are modified.
- No unrelated generated files or local environment files are present.

- [ ] **Step 4: Commit any verification fixes**

If Step 1 or Step 2 required fixes:

```bash
git add Sources/MLXDashboardApp/ModelInstallProgress.swift Sources/MLXDashboardApp/DashboardViewModel.swift Sources/MLXDashboardApp/ContentView.swift Tests/MLXDashboardAppTests/DashboardViewModelTests.swift
git commit -m "Verify per-model install progress history"
```

If no fixes were needed, do not create an empty commit.

---

## Self-Review Notes

- Spec coverage:
  - Per-model storage: Tasks 2 and 3.
  - Selected installed model detail: Task 4.
  - Activity cap 50 and compact latest-five preview: Task 1 and Task 5.
  - Progress display determinate/indeterminate/fallback: Task 1 and Task 5.
  - Clearing rules: Task 3.
  - Stale callback guard: Task 2.
- Placeholder scan:
  - No `TBD`, `TODO`, "add appropriate", or unbounded "handle edge cases" steps.
- Type consistency:
  - `installProgressByModelID`, `activeInstallModelID`, `selectedInstalledModelProgress`, `installedWorkspacePrimaryProgress`, `progressDisplayMode`, and `fullActivityRows` are introduced before use in later tasks.
