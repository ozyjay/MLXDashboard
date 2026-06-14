# Download Settings Design

## Goal

Give MLXDashboard explicit control over Hugging Face download behavior while keeping the safe default as standard non-Xet downloads. Xet remains opt-in until it has been tested well on the user's home internet.

## User Experience

Add a `Model Downloads` settings section to the existing Controller/settings surface. Add a native Settings menu item that focuses or navigates to that settings area, rather than introducing a separate preferences window in this iteration.

The section offers three modes:

- `Standard download`: default and recommended. Disables Xet.
- `Xet conservative`: enables Xet with modest concurrency and longer timeouts.
- `Xet custom`: enables Xet and lets the user tune concurrency and timeouts.

The UI keeps the advanced Xet fields disabled unless an Xet mode is selected. The copy should be concise and operational, for example: `Standard download is recommended until Xet is tested on this network.`

## Settings Model

Persist a new download settings value in `DashboardSettings`.

Suggested shape:

```swift
public enum HuggingFaceDownloadMode: String, Codable, Equatable, Sendable {
    case standard
    case xetConservative
    case xetCustom
}

public struct HuggingFaceDownloadSettings: Codable, Equatable, Sendable {
    public var mode: HuggingFaceDownloadMode
    public var xetConcurrency: Int
    public var downloadTimeoutSeconds: Int
    public var etagTimeoutSeconds: Int
}
```

Defaults:

```text
mode: standard
xetConcurrency: 4
downloadTimeoutSeconds: 60
etagTimeoutSeconds: 30
```

Backward compatibility: decoding older `settings.json` files must default to the standard download settings when the new field is absent.

## Install Data Flow

`DashboardViewModel` derives install environment from persisted download settings and passes it to the installer. The low-level installer should not own product policy beyond applying the explicit environment it receives.

Mode behavior:

```text
standard:
  HF_HUB_DISABLE_XET=1

xetConservative:
  HF_XET_NUM_CONCURRENT_RANGE_GETS=4
  HF_HUB_DOWNLOAD_TIMEOUT=60
  HF_HUB_ETAG_TIMEOUT=30

xetCustom:
  HF_XET_NUM_CONCURRENT_RANGE_GETS=<validated custom value>
  HF_HUB_DOWNLOAD_TIMEOUT=<validated custom value>
  HF_HUB_ETAG_TIMEOUT=<validated custom value>
```

Do not set `HF_HUB_DISABLE_XET` in either Xet mode. Do not set `HF_XET_HIGH_PERFORMANCE`; it is too aggressive for the stated home-internet use case.

## Validation

Clamp custom values before saving or before building the environment:

- Xet concurrency: `1...16`
- Download timeout seconds: `10...600`
- ETag timeout seconds: `5...120`

The UI should use bounded numeric controls where practical, so invalid values are difficult to enter.

## Components

- `MLXCore`
  - Add `HuggingFaceDownloadMode`.
  - Add `HuggingFaceDownloadSettings`.
  - Add `downloadSettings` to `DashboardSettings`.
  - Keep backward-compatible decoding defaults.

- `MLXPythonBridge`
  - Adjust `HuggingFaceModelInstaller` to accept a download environment dictionary, or a typed option that maps to environment values.
  - Preserve progress/activity parsing and install error behavior.

- `MLXDashboardApp`
  - Add a Model Downloads settings section.
  - Add a Settings menu command that navigates to or focuses the settings section.
  - Use the persisted setting for normal installs, continue installs, and retry installs.
  - Keep any explicit `Retry without Xet` action compatible by forcing the standard environment for that retry.

## Error Handling

Existing install failure handling remains in place. Xet-specific warning detection can remain as diagnostic signal. If Xet conservative or custom mode stalls, the existing pause and retry-without-Xet workflow should still work.

## Testing

Add or update tests for:

- `DashboardSettings` persists `downloadSettings`.
- Older settings JSON decodes to standard download mode.
- Standard mode sets `HF_HUB_DISABLE_XET=1`.
- Xet conservative sets concurrency and timeout environment variables without `HF_HUB_DISABLE_XET`.
- Xet custom clamps invalid values and emits the validated environment.
- Continue/retry install paths use the persisted setting, except explicit retry-without-Xet forces standard.
- Settings menu navigation/focus behavior is covered at the policy/ViewModel layer if direct menu testing is not practical.

## Out of Scope

- Moving all settings to a separate macOS Settings window.
- Adding high-performance Xet mode.
- Changing Hugging Face model discovery behavior.
- Changing `mlx_lm.server` startup, host binding, context budgeting, or model-role presets.
