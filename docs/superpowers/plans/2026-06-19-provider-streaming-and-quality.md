# Provider Streaming and Quality Hardening Plan

> **For agentic workers:** Use a test-first workflow. Keep provider behaviour grounded in `ProviderRouter` tests before changing MLXChat expectations.

## Goal

Harden MLXDashboard's streamed provider path so MLXChat can render incremental assistant replies reliably, then fix the quality issues surfaced during repo review:

- alias contract drift between `mlx-fast` and `mlx-coding`;
- provider host safety not being as strict as managed `mlx_lm.server` host safety;
- diagnostic capture recording too much chat content by default;
- lack of obvious CI coverage for these behaviours.

The target contract is a localhost-only provider that advertises current mode aliases, streams OpenAI-compatible chat-completion chunks correctly, and gives clients enough stable metadata to render readable chat output.

## Current Behaviour

Provider-side streaming already exists in the codebase:

- `ProviderRouter` detects `stream: true` for `/v1/chat/completions` and `/v1/completions`.
- Routed streamed requests go through `proxyStream`.
- `URLSessionProviderUpstreamClient` uses `URLSession.bytes(for:)` and yields newline or 4096-byte chunks.
- `NIOProviderServer` writes streamed provider responses using chunked transfer semantics.

This means MLXChat streaming should not require a new Dashboard endpoint. It does require stronger tests so provider-side streaming does not regress while the client starts depending on it.

## Contract Decisions

### Canonical role aliases

Use these aliases as the current public contract:

- `mlx-ask`
- `mlx-plan`
- `mlx-coding`

Keep `mlx-fast` as a legacy accepted alias, but do not advertise it as canonical in `/v1/models` or new docs.

### Streaming shape

The provider should preserve upstream OpenAI-style server-sent events for streamed chat-completions responses. Dashboard does not need to reinterpret normal streamed OpenAI chunks for MLXChat. It should proxy them reliably, preserve useful status and headers, and avoid buffering the full response unless explicitly required for a narrow diagnostic mode.

### Output readability

The provider should not try to format Markdown. Readability is a client responsibility. However, Dashboard should avoid transformations that collapse newline boundaries or concatenate chunks without separators. Streaming tests should include chunk boundaries around paragraphs, lists, and code fences so clients can preserve structure.

## Task 1: Add explicit streaming regression tests

**Files:**

- Modify `Tests/MLXProviderServerTests/ProviderRouterTests.swift`
- Modify test fakes in that file as needed

Add tests for:

- `ProviderRouter.route(...)` returns `.streamed` for `POST /v1/chat/completions` with `stream: true`.
- Streamed alias routing rewrites `mlx-ask`, `mlx-plan`, and `mlx-coding` to the selected upstream model while preserving `stream: true`.
- Streamed role routing uses the role endpoint when available.
- Streamed fallback routing uses the default endpoint or active model with the same fallback reasons as buffered routing.
- Upstream streamed error status is preserved and logged without dropping the body.
- Chunk boundaries preserve text containing paragraph breaks, numbered lists, bullets, and fenced code.

Acceptance:

```bash
swift test --filter MLXProviderServerTests
```

## Task 2: Keep canonical alias advertising consistent

**Files:**

- Modify `Sources/MLXProviderServer/ProviderRouter.swift` only if needed
- Modify `Tests/MLXProviderServerTests/ProviderRouterTests.swift`
- Update README/provider-contract docs after tests pass

Expected behaviour:

- `/v1/models` advertises `mlx-ask`, `mlx-plan`, `mlx-coding`, then the active runnable model.
- `/provider/v1/models` and `/api/v0/models` use `mlx-coding` for the coding role row.
- `mlx-fast` remains accepted as a legacy alias for routing and metadata lookup.
- New client docs should not require `mlx-fast`.

Acceptance tests:

- Existing alias-advertising tests continue to expect `mlx-coding`.
- Add or keep a separate legacy test proving `mlx-fast` routes as `.coding` without being advertised as canonical.

## Task 3: Clamp provider host to localhost

**Files:**

- Modify `Sources/MLXCore/DashboardSettings.swift`
- Modify `Sources/MLXDashboardApp/DashboardViewModel.swift` if necessary
- Modify `Tests/MLXCoreTests/CorePersistenceTests.swift`
- Add app-level tests if `startProvider()` needs coverage

Problem:

`mlxBaseURL` already forces `127.0.0.1`, but `providerBaseURL` currently uses persisted `providerHost`. `startProvider()` passes that host into `NIOProviderServer`. That leaves room for a persisted non-local host such as `0.0.0.0` to expose the provider.

Plan:

- Add a central safe provider host, such as `DashboardSettings.localProviderHost = "127.0.0.1"`.
- Make `providerBaseURL` use the safe host.
- Make provider startup bind to the safe host.
- Either ignore persisted `providerHost` or keep it only for backward-compatible decoding while clamping it at use sites.
- Document that the provider is localhost-only until a secured remote-access mode exists.

Acceptance tests:

- `DashboardSettings(providerHost: "0.0.0.0").providerBaseURL.absoluteString == "http://127.0.0.1:8123/v1"`.
- Decoding settings with `providerHost: "192.168.1.10"` still results in a local provider URL.
- `startProvider()` constructs `NIOProviderServer` with `127.0.0.1`.

## Task 4: Reduce diagnostic-capture privacy risk

**Files:**

- Modify `Sources/MLXCore/DashboardSettings.swift`
- Modify `Sources/MLXProviderServer/ProviderDebugRecorder.swift`
- Modify provider debug tests
- Update Dashboard UI copy if the setting is visible

Problem:

Diagnostic capture defaults to enabled and can persist chat content to disk. That is too broad for a normal default.

Plan:

- Default `providerDebugCaptureEnabled` to `false`.
- Keep safe metadata by default: timestamp, method, path, redacted headers, selected model, alias resolution, routing decision, top-level keys, request bytes, response status, and response bytes.
- Do not write full chat request or assistant reply text in the default recorder mode.
- If detailed body capture is needed later, add a separate clearly named setting with prominent UI wording.
- Redact or summarise message content if any future detailed capture mode is added.

Acceptance tests:

- Default `DashboardSettings().providerDebugCaptureEnabled` is `false`.
- Provider debug records do not include full chat content by default.
- Header redaction tests continue to pass.
- Mode advice and routing metadata are still present when debug capture is enabled.

## Task 5: Add CI coverage

**Files:**

- Create `.github/workflows/swift-tests.yml`

Plan:

- Run `swift test` on pushes and pull requests.
- Use macOS runners because these are macOS/SwiftUI-oriented packages.
- Keep the first workflow simple; do not require a live `mlx_lm.server` process in CI.

Suggested first workflow:

```yaml
name: Swift Tests

on:
  push:
  pull_request:

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run tests
        run: swift test
```

Acceptance:

- CI runs all package tests.
- Provider streaming tests run in CI without needing real model downloads or a live MLX runtime.

## Task 6: Coordinate MLXChat streaming work

Dashboard should be ready before MLXChat depends on streamed output.

Coordination checklist:

- [ ] Dashboard streaming regression tests pass.
- [ ] Dashboard canonical alias docs use `mlx-coding`.
- [ ] Dashboard provider host is clamped to localhost.
- [ ] Diagnostic capture no longer records full chat content by default.
- [ ] MLXChat adds a streaming client API and parser.
- [ ] MLXChat app renders streaming deltas into one growing assistant bubble.
- [ ] MLXChat output rendering preserves paragraphs, lists, and code fences.
- [ ] MLXChat smoke tests expect `mlx-coding` and treat `mlx-fast` as legacy only.

## Manual Verification

1. Run Dashboard tests:

   ```bash
   swift test
   ```

2. Start Dashboard and provider locally.

3. Send a streamed chat-completions request to the local provider and confirm events arrive incrementally.

4. Run the MLXChat app and confirm the streamed response remains readable as it grows.

## Documentation Updates After Implementation

- Update `README.md` provider contract summary if any stream details change.
- Update MLXChat's `docs/mlxdashboard-provider-contract.md` with the final streaming behaviour and canonical alias wording.
- Keep `docs/notes/mlx-lm-runtime-and-model-planning.md` focused on runtime guidance, not client rendering details.
