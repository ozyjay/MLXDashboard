# Download Activity Readout Design

## Goal

MLXDashboard should make Hugging Face model installs understandable while they are running. The user should be able to tell whether a download is transferring bytes, waiting on Hugging Face/Xet, reusing cache files, stalled, failed, or finishing without opening Terminal or inspecting cache directories manually.

This follows the OllamaPull lesson that long-running model work needs visible phase, progress, speed, ETA, recent messages, and failures close to the action.

## Scope

Add an always-visible operational readout to the existing install banner. Do not add a separate queue workspace, local web server, Ollama-style blob semantics, or runtime startup changes.

## User Experience

During model installation, the existing `InstallProgressBanner` remains visible and gains a compact activity area under the progress bar.

The activity area shows:

- Phase and model id using the current banner header.
- Transfer stats when available: percent, ETA, and rate.
- Cache activity when transfer progress is quiet: cache size, incomplete blob count, and active pending files.
- Recent activity lines in chronological order, capped to the latest five entries.
- A warning-style message when the process is alive but no cache growth has been observed for 30 seconds.

Example activity lines:

- `Started Hugging Face snapshot download`
- `Created snapshot metadata`
- `3 large blobs pending`
- `Xet transfer: connection struggling, concurrency reduced`
- `No cache growth for 45s`

The readout is always visible during an active install. It is not hidden behind an expander.

## Data Model

Add a structured download activity model that can carry:

- Message text.
- Severity or tone: info, warning, error.
- Optional timestamp.
- Optional source: command output, cache scan, Xet log, or app phase.

Extend `ModelInstallProgress` to hold recent activity entries and cache summary data while preserving the existing `HuggingFaceDownloadProgress` path for reliable byte progress.

## Signal Sources

Use three signal sources during an active install:

1. Command output from `snapshot_download`.
   - Continue parsing reliable byte progress from tqdm-style output.
   - Also classify useful non-progress lines rather than dropping them.

2. Hugging Face cache state.
   - Sample the repo cache directory for the selected model every 2 seconds while the install is running.
   - Report total cache size, incomplete blob count, and pending incomplete blob names/counts.
   - Detect no-growth intervals of 30 seconds or longer.

3. Xet logs.
   - When Hugging Face uses Xet, classify high-signal messages such as connection struggling or concurrency reductions.
   - Do not show raw JSON log lines in the UI.

## Error Handling

If cache sampling or Xet log reading fails, keep the install running and add a low-noise activity line only when useful. These diagnostics should never convert a working download into a failed install.

If the install command exits non-zero, keep the existing failed phase behavior and include recent activity context in the banner.

## Testing

Add tests for:

- Parsing and classifying non-progress Hugging Face/Xet activity lines.
- Preserving reliable byte progress behavior.
- Formatting cache summary text for growing, quiet, and incomplete-cache states.
- Updating `ModelInstallProgress` with recent activity without unbounded growth.
- Rendering model progress status text from activity data through `ModelInstallProgress` computed properties.

Use TDD for behavior changes: write failing tests first, verify the failure, implement the minimal production changes, then re-run the focused tests and the relevant package tests.
