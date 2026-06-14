# Download Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Model Downloads settings surface that keeps standard Hugging Face downloads as the default while allowing opt-in Xet conservative and custom tuning.

**Architecture:** Persist download settings in `MLXCore.DashboardSettings`, derive Hugging Face environment variables in a small typed policy, and pass explicit environment into `HuggingFaceModelInstaller`. The SwiftUI app adds a compact Model Downloads section to the existing Controller settings surface, and a native menu command navigates to that section without creating a separate settings window.

**Tech Stack:** Swift Package Manager, SwiftUI, XCTest, Hugging Face `huggingface_hub.snapshot_download`, persisted JSON settings.

---

## File Structure

- Modify `Sources/MLXCore/DashboardSettings.swift`
  - Add `HuggingFaceDownloadMode`.
  - Add `HuggingFaceDownloadSettings`.
  - Add `downloadSettings` to `DashboardSettings`.
  - Keep older `settings.json` decoding backward-compatible.

- Modify `Tests/MLXCoreTests/CorePersistenceTests.swift`
  - Cover persistence of `downloadSettings`.
  - Cover defaults when old JSON lacks `downloadSettings`.
  - Cover clamping/custom environment behavior.

- Modify `Sources/MLXPythonBridge/HuggingFaceModels.swift`
  - Replace default-policy `disableXet` ownership with explicit installer environment.
  - Keep compatibility with forced standard retry.

- Modify `Tests/MLXPythonBridgeTests/PythonBridgeTests.swift`
  - Cover installer applying explicit environment.
  - Remove or adapt the low-level “disables Xet by default” test so default policy lives in `DashboardViewModel`.

- Modify `Sources/MLXDashboardApp/DashboardViewModel.swift`
  - Add install environment derivation from `settings.downloadSettings`.
  - Add save/update helpers for download settings.
  - Keep explicit retry-without-Xet forcing standard mode.
  - Add a navigation request for the Settings menu command.

- Modify `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`
  - Cover standard default install environment.
  - Cover Xet conservative install environment.
  - Cover custom clamping/install environment.
  - Cover forced retry-without-Xet overriding Xet mode.
  - Cover settings navigation request at the ViewModel layer.

- Modify `Sources/MLXDashboardApp/ContentView.swift`
  - Add the Model Downloads settings UI in `ControllerTab`.
  - Disable custom fields outside `xetCustom`.
  - Use bounded numeric controls for custom values.
  - Respond to the ViewModel navigation request.

- Modify `Sources/MLXDashboardApp/MLXDashboardApp.swift`
  - Add a native Settings menu command that triggers the ViewModel navigation request.

## Task 1: Persist Download Settings

**Files:**
- Modify: `Sources/MLXCore/DashboardSettings.swift`
- Modify: `Tests/MLXCoreTests/CorePersistenceTests.swift`

- [ ] **Step 1: Write failing persistence/default tests**

Add these tests to `Tests/MLXCoreTests/CorePersistenceTests.swift`:

```swift
func testSettingsStorePersistsDownloadSettings() throws {
    let root = try temporaryDirectory()
    let store = SettingsStore(fileURL: root.appending(path: "config/settings.json"))
    let settings = DashboardSettings(
        downloadSettings: HuggingFaceDownloadSettings(
            mode: .xetCustom,
            xetConcurrency: 3,
            downloadTimeoutSeconds: 120,
            etagTimeoutSeconds: 45
        )
    )

    try store.save(settings)

    let reloaded = try store.load()
    XCTAssertEqual(reloaded.downloadSettings.mode, .xetCustom)
    XCTAssertEqual(reloaded.downloadSettings.xetConcurrency, 3)
    XCTAssertEqual(reloaded.downloadSettings.downloadTimeoutSeconds, 120)
    XCTAssertEqual(reloaded.downloadSettings.etagTimeoutSeconds, 45)
}

func testDashboardSettingsDefaultsDownloadSettingsWhenMissing() throws {
    let json = Data(
        #"{"activeModel":"mlx-community/Tiny","mlxHost":"127.0.0.1","mlxPort":8080,"providerHost":"127.0.0.1","providerPort":8123,"serverFlags":[],"providerDebugCaptureEnabled":true,"providerRoleAssignments":{}}"#.utf8
    )

    let settings = try JSONDecoder().decode(DashboardSettings.self, from: json)

    XCTAssertEqual(settings.downloadSettings, .standardDefault)
}

func testDownloadSettingsClampsCustomValues() {
    let settings = HuggingFaceDownloadSettings(
        mode: .xetCustom,
        xetConcurrency: 50,
        downloadTimeoutSeconds: 2,
        etagTimeoutSeconds: 999
    ).validated()

    XCTAssertEqual(settings.xetConcurrency, 16)
    XCTAssertEqual(settings.downloadTimeoutSeconds, 10)
    XCTAssertEqual(settings.etagTimeoutSeconds, 120)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter CorePersistenceTests/testSettingsStorePersistsDownloadSettings
swift test --filter CorePersistenceTests/testDashboardSettingsDefaultsDownloadSettingsWhenMissing
swift test --filter CorePersistenceTests/testDownloadSettingsClampsCustomValues
```

Expected: compile failures naming missing `HuggingFaceDownloadSettings`, `downloadSettings`, or `standardDefault`.

- [ ] **Step 3: Add settings types and persistence**

In `Sources/MLXCore/DashboardSettings.swift`, insert these types after `ProviderRoleAssignments`:

```swift
public enum HuggingFaceDownloadMode: String, Codable, CaseIterable, Equatable, Sendable {
    case standard
    case xetConservative
    case xetCustom

    public var displayName: String {
        switch self {
        case .standard:
            "Standard download"
        case .xetConservative:
            "Xet conservative"
        case .xetCustom:
            "Xet custom"
        }
    }
}

public struct HuggingFaceDownloadSettings: Codable, Equatable, Sendable {
    public static let standardDefault = HuggingFaceDownloadSettings()
    public static let conservativeDefault = HuggingFaceDownloadSettings(mode: .xetConservative)

    public var mode: HuggingFaceDownloadMode
    public var xetConcurrency: Int
    public var downloadTimeoutSeconds: Int
    public var etagTimeoutSeconds: Int

    public init(
        mode: HuggingFaceDownloadMode = .standard,
        xetConcurrency: Int = 4,
        downloadTimeoutSeconds: Int = 60,
        etagTimeoutSeconds: Int = 30
    ) {
        self.mode = mode
        self.xetConcurrency = xetConcurrency
        self.downloadTimeoutSeconds = downloadTimeoutSeconds
        self.etagTimeoutSeconds = etagTimeoutSeconds
    }

    public func validated() -> HuggingFaceDownloadSettings {
        HuggingFaceDownloadSettings(
            mode: mode,
            xetConcurrency: Self.clamp(xetConcurrency, lower: 1, upper: 16),
            downloadTimeoutSeconds: Self.clamp(downloadTimeoutSeconds, lower: 10, upper: 600),
            etagTimeoutSeconds: Self.clamp(etagTimeoutSeconds, lower: 5, upper: 120)
        )
    }

    private static func clamp(_ value: Int, lower: Int, upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}
```

Then update `DashboardSettings`:

```swift
public var downloadSettings: HuggingFaceDownloadSettings
```

Add the initializer parameter after `providerRoleAssignments`:

```swift
downloadSettings: HuggingFaceDownloadSettings = .standardDefault
```

Assign it in the initializer:

```swift
self.downloadSettings = downloadSettings.validated()
```

Add the coding key:

```swift
case downloadSettings
```

Decode it with a default:

```swift
self.downloadSettings = (try container.decodeIfPresent(HuggingFaceDownloadSettings.self, forKey: .downloadSettings) ?? .standardDefault).validated()
```

- [ ] **Step 4: Run tests to verify Task 1 passes**

Run:

```bash
swift test --filter CorePersistenceTests
```

Expected: all `CorePersistenceTests` pass.

- [ ] **Step 5: Commit Task 1**

Run:

```bash
git add Sources/MLXCore/DashboardSettings.swift Tests/MLXCoreTests/CorePersistenceTests.swift
git commit -m "Add persisted download settings"
```

## Task 2: Build Download Environment Policy

**Files:**
- Modify: `Sources/MLXCore/DashboardSettings.swift`
- Modify: `Tests/MLXCoreTests/CorePersistenceTests.swift`

- [ ] **Step 1: Write failing environment tests**

Add these tests to `Tests/MLXCoreTests/CorePersistenceTests.swift`:

```swift
func testStandardDownloadEnvironmentDisablesXet() {
    let environment = HuggingFaceDownloadSettings.standardDefault.huggingFaceEnvironment

    XCTAssertEqual(environment["HF_HUB_DISABLE_XET"], "1")
    XCTAssertNil(environment["HF_XET_NUM_CONCURRENT_RANGE_GETS"])
    XCTAssertNil(environment["HF_XET_HIGH_PERFORMANCE"])
}

func testConservativeDownloadEnvironmentEnablesTunedXet() {
    let environment = HuggingFaceDownloadSettings.conservativeDefault.huggingFaceEnvironment

    XCTAssertNil(environment["HF_HUB_DISABLE_XET"])
    XCTAssertEqual(environment["HF_XET_NUM_CONCURRENT_RANGE_GETS"], "4")
    XCTAssertEqual(environment["HF_HUB_DOWNLOAD_TIMEOUT"], "60")
    XCTAssertEqual(environment["HF_HUB_ETAG_TIMEOUT"], "30")
    XCTAssertNil(environment["HF_XET_HIGH_PERFORMANCE"])
}

func testCustomDownloadEnvironmentUsesValidatedValues() {
    let environment = HuggingFaceDownloadSettings(
        mode: .xetCustom,
        xetConcurrency: 0,
        downloadTimeoutSeconds: 700,
        etagTimeoutSeconds: 1
    ).huggingFaceEnvironment

    XCTAssertNil(environment["HF_HUB_DISABLE_XET"])
    XCTAssertEqual(environment["HF_XET_NUM_CONCURRENT_RANGE_GETS"], "1")
    XCTAssertEqual(environment["HF_HUB_DOWNLOAD_TIMEOUT"], "600")
    XCTAssertEqual(environment["HF_HUB_ETAG_TIMEOUT"], "5")
    XCTAssertNil(environment["HF_XET_HIGH_PERFORMANCE"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter CorePersistenceTests/testStandardDownloadEnvironmentDisablesXet
swift test --filter CorePersistenceTests/testConservativeDownloadEnvironmentEnablesTunedXet
swift test --filter CorePersistenceTests/testCustomDownloadEnvironmentUsesValidatedValues
```

Expected: compile failures for missing `huggingFaceEnvironment`.

- [ ] **Step 3: Add environment mapping**

Add this computed property to `HuggingFaceDownloadSettings` in `Sources/MLXCore/DashboardSettings.swift`:

```swift
public var huggingFaceEnvironment: [String: String] {
    let settings = validated()
    switch settings.mode {
    case .standard:
        return ["HF_HUB_DISABLE_XET": "1"]
    case .xetConservative, .xetCustom:
        return [
            "HF_XET_NUM_CONCURRENT_RANGE_GETS": String(settings.xetConcurrency),
            "HF_HUB_DOWNLOAD_TIMEOUT": String(settings.downloadTimeoutSeconds),
            "HF_HUB_ETAG_TIMEOUT": String(settings.etagTimeoutSeconds)
        ]
    }
}
```

- [ ] **Step 4: Run tests to verify Task 2 passes**

Run:

```bash
swift test --filter CorePersistenceTests
```

Expected: all `CorePersistenceTests` pass.

- [ ] **Step 5: Commit Task 2**

Run:

```bash
git add Sources/MLXCore/DashboardSettings.swift Tests/MLXCoreTests/CorePersistenceTests.swift
git commit -m "Map download settings to Hugging Face environment"
```

## Task 3: Make Installer Accept Explicit Environment

**Files:**
- Modify: `Sources/MLXPythonBridge/HuggingFaceModels.swift`
- Modify: `Tests/MLXPythonBridgeTests/PythonBridgeTests.swift`

- [ ] **Step 1: Write failing installer environment test**

Replace `testHuggingFaceInstallerDisablesXetByDefault` in `Tests/MLXPythonBridgeTests/PythonBridgeTests.swift` with:

```swift
func testHuggingFaceInstallerAppliesProvidedDownloadEnvironment() async throws {
    let runner = RecordingCommandRunner(result: CommandResult(
        exitCode: 0,
        standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#,
        standardError: ""
    ))
    let installer = HuggingFaceModelInstaller(runner: runner)

    _ = try await installer.install(
        modelID: "mlx-community/Tiny",
        pythonExecutable: URL(filePath: "/tmp/python"),
        downloadEnvironment: [
            "HF_XET_NUM_CONCURRENT_RANGE_GETS": "2",
            "HF_HUB_DOWNLOAD_TIMEOUT": "90"
        ]
    )

    XCTAssertEqual(runner.commands.last?.environment["HF_XET_NUM_CONCURRENT_RANGE_GETS"], "2")
    XCTAssertEqual(runner.commands.last?.environment["HF_HUB_DOWNLOAD_TIMEOUT"], "90")
    XCTAssertNil(runner.commands.last?.environment["HF_HUB_DISABLE_XET"])
}
```

Update `testHuggingFaceInstallerDisablesXetWhenRequested` to call the explicit environment:

```swift
_ = try await installer.install(
    modelID: "mlx-community/Tiny",
    pythonExecutable: URL(filePath: "/tmp/python"),
    downloadEnvironment: ["HF_HUB_DISABLE_XET": "1"]
)
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter PythonBridgeTests/testHuggingFaceInstallerAppliesProvidedDownloadEnvironment
swift test --filter PythonBridgeTests/testHuggingFaceInstallerDisablesXetWhenRequested
```

Expected: compile failure for missing `downloadEnvironment`.

- [ ] **Step 3: Change installer signature and environment application**

In `Sources/MLXPythonBridge/HuggingFaceModels.swift`, change `install` signature from:

```swift
disableXet: Bool = true,
```

to:

```swift
downloadEnvironment: [String: String] = [:],
```

Replace start message logic with:

```swift
let isXetDisabled = downloadEnvironment["HF_HUB_DISABLE_XET"] == "1"
let startMessage = isXetDisabled
    ? "Started Hugging Face snapshot download for \(modelID.replacingOccurrences(of: "'", with: "\\'")) with Xet disabled"
    : "Started Hugging Face snapshot download for \(modelID.replacingOccurrences(of: "'", with: "\\'"))"
```

Replace:

```swift
let environment = disableXet ? ["HF_HUB_DISABLE_XET": "1"] : [:]
```

with:

```swift
let environment = downloadEnvironment
```

- [ ] **Step 4: Run tests to verify Task 3 passes**

Run:

```bash
swift test --filter PythonBridgeTests
```

Expected: all `PythonBridgeTests` pass.

- [ ] **Step 5: Commit Task 3**

Run:

```bash
git add Sources/MLXPythonBridge/HuggingFaceModels.swift Tests/MLXPythonBridgeTests/PythonBridgeTests.swift
git commit -m "Pass explicit download environment to installer"
```

## Task 4: Wire Settings Into Install Flows

**Files:**
- Modify: `Sources/MLXDashboardApp/DashboardViewModel.swift`
- Modify: `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Write failing ViewModel install environment tests**

Add these tests near existing install tests in `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`:

```swift
func testInstallSelectedModelUsesStandardDownloadEnvironmentByDefault() async throws {
    let paths = try temporaryAppPaths()
    let python = paths.venvDirectory.appending(path: "bin/python")
    try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: python.path, contents: Data())
    let runner = FakeCommandRunner(results: [
        "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        "whoami": CommandResult(exitCode: 0, standardOutput: #"{"name":"octocat"}"#, standardError: ""),
        "install": CommandResult(exitCode: 0, standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#, standardError: "")
    ])
    let viewModel = DashboardViewModel(
        settingsStore: SettingsStore(fileURL: paths.settingsFile),
        registry: ModelRegistry(fileURL: paths.modelRegistryFile),
        environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
        modelInstaller: HuggingFaceModelInstaller(runner: runner),
        authChecker: HuggingFaceAuthChecker(runner: runner)
    )
    viewModel.searchResults = [HuggingFaceModelSummary(id: "mlx-community/Tiny")]
    viewModel.selectedSearchModelID = "mlx-community/Tiny"

    await viewModel.installSelectedModel()

    let installCommand = runner.commands.last { ($0.arguments.last ?? "").contains("snapshot_download") }
    XCTAssertEqual(installCommand?.environment["HF_HUB_DISABLE_XET"], "1")
    XCTAssertNil(installCommand?.environment["HF_XET_NUM_CONCURRENT_RANGE_GETS"])
}

func testInstallSelectedModelUsesConservativeXetEnvironmentWhenConfigured() async throws {
    let paths = try temporaryAppPaths()
    let python = paths.venvDirectory.appending(path: "bin/python")
    try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: python.path, contents: Data())
    try SettingsStore(fileURL: paths.settingsFile).save(
        DashboardSettings(downloadSettings: .conservativeDefault)
    )
    let runner = FakeCommandRunner(results: [
        "import mlx_lm": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        "import huggingface_hub": CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        "whoami": CommandResult(exitCode: 0, standardOutput: #"{"name":"octocat"}"#, standardError: ""),
        "install": CommandResult(exitCode: 0, standardOutput: #"{"local_path":"/tmp/cache/models--mlx-community--Tiny/snapshots/abc"}"#, standardError: "")
    ])
    let viewModel = DashboardViewModel(
        settingsStore: SettingsStore(fileURL: paths.settingsFile),
        registry: ModelRegistry(fileURL: paths.modelRegistryFile),
        environmentManager: PythonEnvironmentManager(paths: paths, runner: runner),
        modelInstaller: HuggingFaceModelInstaller(runner: runner),
        authChecker: HuggingFaceAuthChecker(runner: runner)
    )
    viewModel.searchResults = [HuggingFaceModelSummary(id: "mlx-community/Tiny")]
    viewModel.selectedSearchModelID = "mlx-community/Tiny"

    await viewModel.installSelectedModel()

    let installCommand = runner.commands.last { ($0.arguments.last ?? "").contains("snapshot_download") }
    XCTAssertNil(installCommand?.environment["HF_HUB_DISABLE_XET"])
    XCTAssertEqual(installCommand?.environment["HF_XET_NUM_CONCURRENT_RANGE_GETS"], "4")
    XCTAssertEqual(installCommand?.environment["HF_HUB_DOWNLOAD_TIMEOUT"], "60")
    XCTAssertEqual(installCommand?.environment["HF_HUB_ETAG_TIMEOUT"], "30")
}
```

Update the existing `testContinueLastModelInstallRetriesFailedModelID` assertion so it still expects `HF_HUB_DISABLE_XET=1` by default.

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter DashboardViewModelTests/testInstallSelectedModelUsesStandardDownloadEnvironmentByDefault
swift test --filter DashboardViewModelTests/testInstallSelectedModelUsesConservativeXetEnvironmentWhenConfigured
```

Expected: compile or assertion failures until the ViewModel passes `downloadEnvironment`.

- [ ] **Step 3: Update `installModel` to use settings policy**

In `Sources/MLXDashboardApp/DashboardViewModel.swift`, replace the `disableXet` parameter with:

```swift
forceStandardDownload: Bool = false
```

At the start of the download section, derive settings:

```swift
let downloadSettings = forceStandardDownload ? .standardDefault : settings.downloadSettings.validated()
let downloadEnvironment = downloadSettings.huggingFaceEnvironment
let isStandardDownload = downloadSettings.mode == .standard
```

Update copy branches to use `isStandardDownload` instead of `disableXet`.

Change the installer call to:

```swift
downloadEnvironment: downloadEnvironment,
```

Update explicit retry calls:

```swift
await installModel(HuggingFaceModelSummary(id: modelID), isContinuation: true, forceStandardDownload: true)
```

Add this helper near `setProviderDebugCaptureEnabled(_:)`:

```swift
func updateDownloadSettings(_ downloadSettings: HuggingFaceDownloadSettings) {
    settings.downloadSettings = downloadSettings.validated()
    saveSettings()
}
```

- [ ] **Step 4: Run tests to verify Task 4 passes**

Run:

```bash
swift test --filter DashboardViewModelTests/testInstallSelectedModelUsesStandardDownloadEnvironmentByDefault
swift test --filter DashboardViewModelTests/testInstallSelectedModelUsesConservativeXetEnvironmentWhenConfigured
swift test --filter DashboardViewModelTests/testRetryLastModelInstallWithoutXetDisablesXetForInstallCommand
swift test --filter DashboardViewModelTests/testContinueLastModelInstallRetriesFailedModelID
```

Expected: selected install, continue, and retry-without-Xet tests pass.

- [ ] **Step 5: Commit Task 4**

Run:

```bash
git add Sources/MLXDashboardApp/DashboardViewModel.swift Tests/MLXDashboardAppTests/DashboardViewModelTests.swift
git commit -m "Use download settings for model installs"
```

## Task 5: Add Settings Navigation Request

**Files:**
- Modify: `Sources/MLXDashboardApp/DashboardViewModel.swift`
- Modify: `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`
- Modify: `Sources/MLXDashboardApp/ContentView.swift`
- Modify: `Sources/MLXDashboardApp/MLXDashboardApp.swift`

- [ ] **Step 1: Write failing navigation policy test**

Add this test to `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`:

```swift
func testRequestModelDownloadSettingsNavigationIncrementsRequestID() {
    let viewModel = DashboardViewModel()
    let initial = viewModel.modelDownloadSettingsNavigationRequestID

    viewModel.requestModelDownloadSettingsNavigation()

    XCTAssertEqual(viewModel.modelDownloadSettingsNavigationRequestID, initial + 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter DashboardViewModelTests/testRequestModelDownloadSettingsNavigationIncrementsRequestID
```

Expected: compile failure for missing property/method.

- [ ] **Step 3: Add navigation request API**

In `Sources/MLXDashboardApp/DashboardViewModel.swift`, add a published property near other `@Published` properties:

```swift
@Published var modelDownloadSettingsNavigationRequestID = 0
```

Add this method near `saveSettings()`:

```swift
func requestModelDownloadSettingsNavigation() {
    modelDownloadSettingsNavigationRequestID += 1
}
```

- [ ] **Step 4: Wire menu command and view response**

In `Sources/MLXDashboardApp/MLXDashboardApp.swift`, add this command inside `.commands`:

```swift
CommandGroup(replacing: .appSettings) {
    Button("Settings...") {
        NSApp.activate(ignoringOtherApps: true)
        viewModel.requestModelDownloadSettingsNavigation()
    }
    .keyboardShortcut(",", modifiers: [.command])
}
```

In `Sources/MLXDashboardApp/ContentView.swift`, add this modifier to the outer `NavigationSplitView` chain:

```swift
.onChange(of: viewModel.modelDownloadSettingsNavigationRequestID) { _ in
    selectedSection = .controller
}
```

- [ ] **Step 5: Run tests to verify Task 5 passes**

Run:

```bash
swift test --filter DashboardViewModelTests/testRequestModelDownloadSettingsNavigationIncrementsRequestID
```

Expected: test passes.

- [ ] **Step 6: Commit Task 5**

Run:

```bash
git add Sources/MLXDashboardApp/DashboardViewModel.swift Sources/MLXDashboardApp/ContentView.swift Sources/MLXDashboardApp/MLXDashboardApp.swift Tests/MLXDashboardAppTests/DashboardViewModelTests.swift
git commit -m "Add settings menu navigation"
```

## Task 6: Add Model Downloads UI

**Files:**
- Modify: `Sources/MLXDashboardApp/ContentView.swift`

- [ ] **Step 1: Add focused SwiftUI settings section**

In `Sources/MLXDashboardApp/ContentView.swift`, add this view after `ControllerTab`:

```swift
private struct ModelDownloadsSettingsView: View {
    @EnvironmentObject private var viewModel: DashboardViewModel

    private var customFieldsDisabled: Bool {
        viewModel.settings.downloadSettings.mode != .xetCustom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model Downloads")
                .font(.headline)
            Text("Standard download is recommended until Xet is tested on this network.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Download mode", selection: Binding(
                get: { viewModel.settings.downloadSettings.mode },
                set: { mode in
                    var downloadSettings = viewModel.settings.downloadSettings
                    downloadSettings.mode = mode
                    if mode == .xetConservative {
                        downloadSettings = .conservativeDefault
                    }
                    viewModel.updateDownloadSettings(downloadSettings)
                }
            )) {
                ForEach(HuggingFaceDownloadMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Stepper(value: Binding(
                    get: { viewModel.settings.downloadSettings.xetConcurrency },
                    set: {
                        var downloadSettings = viewModel.settings.downloadSettings
                        downloadSettings.xetConcurrency = $0
                        viewModel.updateDownloadSettings(downloadSettings)
                    }
                ), in: 1...16) {
                    Text("Concurrency: \(viewModel.settings.downloadSettings.xetConcurrency)")
                }
                .disabled(customFieldsDisabled)

                Stepper(value: Binding(
                    get: { viewModel.settings.downloadSettings.downloadTimeoutSeconds },
                    set: {
                        var downloadSettings = viewModel.settings.downloadSettings
                        downloadSettings.downloadTimeoutSeconds = $0
                        viewModel.updateDownloadSettings(downloadSettings)
                    }
                ), in: 10...600, step: 10) {
                    Text("Download timeout: \(viewModel.settings.downloadSettings.downloadTimeoutSeconds)s")
                }
                .disabled(customFieldsDisabled)

                Stepper(value: Binding(
                    get: { viewModel.settings.downloadSettings.etagTimeoutSeconds },
                    set: {
                        var downloadSettings = viewModel.settings.downloadSettings
                        downloadSettings.etagTimeoutSeconds = $0
                        viewModel.updateDownloadSettings(downloadSettings)
                    }
                ), in: 5...120, step: 5) {
                    Text("ETag timeout: \(viewModel.settings.downloadSettings.etagTimeoutSeconds)s")
                }
                .disabled(customFieldsDisabled)
            }
            .font(.caption)
        }
        .padding(.top, 8)
    }
}
```

Then add it to `ControllerTab` below the Python package buttons:

```swift
Divider()
ModelDownloadsSettingsView()
```

- [ ] **Step 2: Run build**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit Task 6**

Run:

```bash
git add Sources/MLXDashboardApp/ContentView.swift
git commit -m "Add model download settings UI"
```

## Task 7: Final Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Run full test suite**

Run:

```bash
swift test
```

Expected: all tests pass with 0 failures.

- [ ] **Step 2: Run build**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Inspect final diff/status**

Run:

```bash
git status --short
git log --oneline -6
```

Expected: working tree is clean except for intentionally uncommitted user changes, and recent commits include the task commits.
