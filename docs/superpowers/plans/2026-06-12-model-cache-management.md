# Model Cache Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe model cache deletion, selectable model install/activation, and friendlier Python/Hugging Face readiness messages.

**Architecture:** Keep cache filesystem operations in `MLXPythonBridge`, keep persistent model state in `MLXCore.ModelRegistry`, and let `DashboardViewModel` orchestrate UI state. The SwiftUI model tab gets row selection and explicit action buttons rather than per-row hidden state.

**Tech Stack:** Swift Package Manager, SwiftUI `Table` selection, XCTest, app-managed Python venv with `huggingface_hub`.

---

### Task 1: Safe Hugging Face Cache Deletion

**Files:**
- Modify: `Sources/MLXPythonBridge/MLXModelCacheScanner.swift`
- Test: `Tests/MLXPythonBridgeTests/PythonBridgeTests.swift`

- [ ] Write a failing test that creates `models--mlx-community--Tiny/snapshots/abc123`, calls a cache deletion API with model id `mlx-community/Tiny`, and asserts the whole repo folder is removed.
- [ ] Write a failing test that attempts to delete through an unsafe id such as `../Tiny` and asserts the cache root remains unchanged.
- [ ] Implement `MLXModelCacheManager.deleteModelCache(modelID:localPath:cacheRoot:)` so it resolves only `models--...` folders underneath the cache root.
- [ ] Run `swift test --filter PythonBridgeTests`.

### Task 2: Hugging Face Readiness And Install Detail

**Files:**
- Modify: `Sources/MLXPythonBridge/HuggingFaceModels.swift`
- Modify: `Sources/MLXDashboardApp/DashboardViewModel.swift`
- Test: `Tests/MLXPythonBridgeTests/PythonBridgeTests.swift`
- Test: `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`

- [ ] Write a failing test that `HuggingFaceAuthChecker` reports logged-in, logged-out, and unavailable states from `whoami()`.
- [ ] Write a failing test that installer returns the snapshot path printed by `snapshot_download`.
- [ ] Write a failing view model test that missing Python packages block selected model install and expose an actionable message.
- [ ] Implement auth checker, installer result decoding, install stage messages, and friendly error messages.
- [ ] Run `swift test --filter PythonBridgeTests` and `swift test --filter DashboardViewModelTests`.

### Task 3: Selection UI And Model Actions

**Files:**
- Modify: `Sources/MLXDashboardApp/ContentView.swift`
- Modify: `Sources/MLXDashboardApp/DashboardViewModel.swift`
- Test: `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`

- [ ] Write failing tests for installing selected search result, setting selected installed model active, and deleting selected installed model from cache.
- [ ] Add `selectedSearchModelID`, `selectedInstalledModelID`, `installSelectedModel()`, `setSelectedInstalledModelActive()`, and `deleteSelectedInstalledModelFromCache()`.
- [ ] Update the Models tab with selected-row tables and action buttons.
- [ ] Run `swift test --filter DashboardViewModelTests`.

### Task 4: Verification

**Files:**
- Validate: all modified files

- [ ] Run `swift test`.
- [ ] Run `swift build --product MLXDashboard`.
- [ ] Inspect `git diff` to confirm unrelated existing changes are preserved.
