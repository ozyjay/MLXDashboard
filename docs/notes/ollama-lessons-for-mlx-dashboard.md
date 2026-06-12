# Ollama Lessons for MLXDashboard

These notes summarize what worked in the OllamaPull and OllamaAgent projects and how those patterns should shape MLXDashboard.

## OllamaPull

OllamaPull works well because it separates user workspaces clearly: search, queue, installed models, and inspection each have their own place. Its UI keeps the primary action visible, shows concise status messages near the action, and treats destructive cleanup as a confirmed operation. The queue and inspector also make long-running work understandable by showing phase, progress, speed, ETA, recent messages, and failures without burying the user in raw logs.

Patterns worth applying to MLXDashboard:

- Keep model discovery separate from installed/cache management.
- Keep setup, search, install, and delete messages close to the relevant controls.
- Keep destructive cache actions confirmed and explicit about what will be removed.
- Prefer compact command rows and dense tables for operational workflows.
- Revisit queued downloads and richer progress if Hugging Face install progress becomes available.

Patterns not to copy directly:

- Do not add OllamaPull's local Python web server architecture to MLXDashboard. MLXDashboard should stay a native SwiftUI app using its existing Swift/Python bridge.
- Do not bring over Ollama-specific blob cleanup semantics. Hugging Face cache layout and MLX model discovery need their own safety rules.

## OllamaAgent

OllamaAgent works well as a native macOS control plane. Its main window uses a sidebar workspace model, a compact status header, and dense model views that keep decisions close to the selected model. The code also keeps view policy out of large SwiftUI bodies: filtering, sorting, action enablement, row summaries, and status derivation are small, testable types.

Patterns worth applying to MLXDashboard:

- Use `NavigationSplitView` for a primary workspace window.
- Default to the most common task rather than a generic dashboard. For MLXDashboard, that is model discovery.
- Extract small policy helpers for action enablement and default-search decisions.
- Keep status information compact and scannable in the header or just above the main table.
- Keep installed-model management as its own workspace, not as a cramped side panel.

Patterns not to copy directly:

- Do not add menu-bar, proxy, warm-up, or keep-alive features unless MLXDashboard later needs long-running background control.
- Do not adopt Xcode-project-only structure just because OllamaAgent uses it. MLXDashboard can remain a Swift Package app.

## Applied MLXDashboard Direction

MLXDashboard should use an OllamaAgent-style sidebar with Discover as the default workspace. Discover should be a table-first experience matching the desired dense model list: model id, downloads, likes, and install action. Installed/cache management should move to a separate Installed workspace with scan, set active, and delete-from-cache controls.

The app should auto-search the default `Devstral-Small` query only when the managed Python environment already has the required packages. If packages are missing, the app should show a quiet actionable setup message instead of throwing a search failure into the default view.
