# Per-Model Install Progress History Design

## Goal

Make install progress and install log details recoverable after the user navigates away, works in another area of the dashboard, or selects the installing model later. An active install should feel attached to the model row, not like a transient global banner that can be lost.

## Problem

The app currently exposes one global `modelInstallProgress`. The same banner appears in Discover and Installed, but it is not keyed by selected model. Some unrelated model actions clear the global progress. Activity rows are limited to the latest five and are only surfaced while the phase is `downloading`.

The result is that a long install can still be running while the detailed context feels gone or hard to recover.

The progress bar also feels absent when the Hugging Face downloader has not emitted parseable transfer progress. The UI currently shows an indeterminate spinner while waiting for download data, then switches to a determinate bar only when parsed percent/rate data exists.

## Scope

This feature changes install progress state management and the Installed/Discover progress presentation. It does not change Hugging Face download mechanics, cache layout, model compatibility rules, provider routing, or `mlx_lm.server` behavior.

Progress history is in-memory for this pass. Persisting progress logs across app restart is out of scope.

## User Experience

The app keeps a compact active-install banner near the relevant controls so the current behavior remains familiar.

The Installed workspace also shows progress details for the selected model when that model has install progress history. If a model is installing, paused, failed, or recently installed, selecting its row brings back the same progress detail and activity log for that exact model ID.

The selected-model progress view does not disappear because the user checks login, sets another model active, assigns a role, or navigates between Discover and Installed. Actions that start or resume an install for the same model update that model's progress entry.

## Progress Display

The progress presentation has three states:

1. Determinate transfer progress when parsed Hugging Face transfer percent is available.
2. Indeterminate download progress when the download is active but transfer percent is not available.
3. Phase fallback progress for non-download phases such as preparing, checking packages, checking login, finalizing, installed, paused, blocked, and failed.

When transfer percent is unavailable, the UI still shows useful status text such as phase, cache growth, incomplete blobs, recent activity, and the "waiting for download data" message. This makes quiet or Xet-heavy downloads visibly active even before a byte-level progress line appears.

## Data Model

Replace the single progress source of truth with per-model install progress state, conceptually:

```swift
var installProgressByModelID: [String: ModelInstallProgress]
var activeInstallModelID: String?
```

The existing `modelInstallProgress` API may remain as a computed compatibility bridge for the active install during implementation, but writes update the per-model store.

`ModelInstallProgress` continues to represent one model's install state. It keeps enough history to make the selected-model detail useful:

- latest phase;
- detail text;
- latest parsed download progress;
- latest cache summary;
- activity history.

Activity history increases from the latest five rows to an in-memory cap of 50 rows per model. The compact banner shows only the most recent five.

## Selection Behavior

When `selectedInstalledModelID` changes, the Installed workspace reads `installProgressByModelID[selectedInstalledModelID]` and shows that progress if present.

The active global banner reads `installProgressByModelID[activeInstallModelID]`.

If the selected model differs from the active install, the selected-model detail shows the selected model's own progress history while the compact active banner can still show the currently running install.

## Clearing Rules

Do not clear per-model progress history when the user:

- checks Hugging Face login;
- sets a model active;
- assigns a model to a provider role;
- navigates between workspaces;
- selects another row.

Clear or replace progress history only when:

- a new install starts for the same model ID;
- the selected model is deleted from cache;
- the app explicitly prunes old in-memory entries.

Terminal progress entries for installed, failed, paused, and blocked models remain available for the current app session.

## Install Callbacks

Download progress, activity rows, and cache summaries are applied to the progress entry for the callback model ID and active install session. Stale callbacks from older install sessions continue to be ignored.

Callbacks do not depend on the currently visible workspace or selected row.

## Error Handling

If download percent cannot be parsed, keep the install in the active indeterminate download state and continue showing cache/activity status.

If an install fails, keep the failed progress entry for the model with the failure detail and recent activity history.

If the user selects a model with no progress history, the Installed workspace falls back to the existing model message/status columns.

## Testing

Add focused tests for:

- active installs writing progress into `installProgressByModelID`;
- selecting an installing model exposes that model's progress detail;
- unrelated actions such as setting active or assigning a role do not clear progress history;
- deleting a model clears that model's progress history;
- activity history retains more than five rows while the compact preview remains capped;
- stale callbacks from older install sessions do not mutate current progress;
- progress display uses determinate transfer progress when available and indeterminate/phase fallback when not.

## Non-Goals

- No persisted install log database.
- No multi-download queue.
- No changes to Hugging Face download implementation.
- No changes to provider routing or role assignment behavior.
