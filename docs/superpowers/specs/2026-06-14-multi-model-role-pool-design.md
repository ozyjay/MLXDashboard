# Multi-Model Role Pool Design

## Goal

MLXDashboard should support real multi-model provider routing for role aliases while keeping the local runtime understandable and safe for personal use.

The first slice will let a user run setups such as:

```text
ask    -> mlx-community/gemma-4-12B-it-4bit
coding -> mlx-community/gemma-4-12B-it-4bit
plan   -> mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit
```

In that example MLXDashboard starts two `mlx_lm.server` processes, not three:

- one shared Gemma process for ask and coding
- one Devstral process for planning

## Non-Goals

- Do not add remote-access support.
- Do not expose managed `mlx_lm.server` beyond `127.0.0.1`.
- Do not add model presets, memory classes, or context-budget UI in this slice.
- Do not attempt automatic memory-pressure detection in this slice.
- Do not run one process per alias when multiple aliases use the same model.

## Runtime Model

MLXDashboard will manage a local role server pool. The pool starts one server per unique model required by:

- `settings.activeModel`
- `settings.providerRoleAssignments.ask`
- `settings.providerRoleAssignments.plan`
- `settings.providerRoleAssignments.coding`

Empty assignments are ignored. Duplicate model IDs share one server process.

All managed model servers must bind to:

```text
127.0.0.1
```

The default active model server keeps using `settings.mlxPort`, currently `8080`. Additional unique role models use deterministic ports starting after the default port, such as:

```text
8081
8082
8083
```

If a preferred role port is unavailable, startup for that role server fails cleanly and the provider falls back to the active/default server for that role.

## Provider Routing

The provider continues to expose one OpenAI-compatible endpoint on `settings.providerPort`, currently `8123`.

The advertised models remain:

- `mlx-ask`
- `mlx-plan`
- `mlx-coding`
- active model ID

For chat/completion requests, the provider keeps its current role inference rules:

- `mlx-ask` maps to ask
- `mlx-plan` maps to plan
- `mlx-coding` maps to coding
- `mlx-fast` is accepted as a legacy alias for coding but is not advertised
- planning-mode system/developer prompts override alias role to plan

After inferring the role, the provider chooses an upstream:

1. If the role has an assigned model and that model has a running pool server, route to that server.
2. If the selected alias maps to the active model, route to the active/default server.
3. If the role server is missing, stopped, or failed, route to the active/default server and log the fallback reason.

Before proxying upstream, the provider rewrites the payload model field to the model loaded by the selected upstream server. It still normalizes messages and strips unsupported tool-calling fields exactly as it does now.

## UI Behavior

The first UI slice should keep the existing controls and add a compact role-server status area.

Starting behavior:

- `Start Server` starts the active/default model server.
- It also starts additional unique assigned role model servers.
- `Start Provider` starts the single provider process and routes through the role pool.

Stopping behavior:

- `Stop Server` stops every owned model server.
- `Stop Provider` only stops the provider process.
- Closing the app stops provider and all owned model servers, using the existing close policy for downloads.

Role-server status should show:

| Field | Meaning |
| --- | --- |
| Role | Ask, Plan, or Coding |
| Assigned model | Model ID from role assignment settings |
| Upstream port | Local server port if one exists |
| Status | running, shared, fallback, failed, or unassigned |
| Detail | Short reason, such as "shared with coding" or "port unavailable" |

Manual controls in the first slice should be small:

- restart a role server
- stop a role server

If a role server is stopped manually, provider requests for that role fall back to the active/default server until the user restarts the role server or starts all servers again.

## Logging and Diagnostics

Provider logs should make routing visible without requiring inspection of debug payloads.

Examples:

```text
Provider routed mlx-plan role=plan upstream=mlx-community/Devstral... port=8081
Provider routed mlx-coding role=coding upstream=mlx-community/gemma... port=8082 shared=true
Provider routing fallback for mlx-coding: role server failed; using active model mlx-community/Devstral...
```

Debug records should include:

- selected alias
- inferred role
- desired role model
- upstream model
- upstream base URL or port
- fallback reason when present

## Error Handling

Role server startup failures should not prevent the whole app from being usable.

If the active/default server fails:

- `Start Server` should report failure, as it does today.
- Provider routing should not claim role servers are usable as a replacement for the active/default server in this slice.

If an additional role server fails:

- mark that role status as failed or fallback
- keep other successfully started servers running
- keep provider available
- route affected aliases to active/default

If a role server later stops unexpectedly:

- status should update on the next known check or action
- provider requests should fall back instead of returning a role-routing error

## Port Policy

Ports are local-only and deterministic.

The active/default server uses `settings.mlxPort`.

Additional role servers should use the next free candidate ports from:

```text
settings.mlxPort + 1
settings.mlxPort + 2
settings.mlxPort + 3
```

The first slice only needs enough ports for the active model plus three role assignments. If candidate ports are exhausted or unavailable, the affected role server fails with a clear status.

## Testing Strategy

Unit tests should cover:

- duplicate role assignments share one planned server
- distinct assigned models produce distinct planned servers
- all model server arguments preserve `--host 127.0.0.1`
- `--host` remains stripped from user-provided server flags
- provider chooses the role upstream when a matching role server exists
- provider falls back to the active/default upstream when role server is missing
- routing debug payload includes upstream model and fallback reason
- stopping the server pool stops every owned process

Integration-style tests should use fake process launchers and fake upstream clients rather than starting real MLX processes.

Manual verification should include:

1. Assign ask and coding to Gemma.
2. Assign plan to Devstral.
3. Start servers and provider.
4. Confirm the role status table shows Gemma shared by ask/coding and Devstral for plan.
5. Send Android Studio requests through `mlx-coding` and `mlx-plan`.
6. Confirm logs show `mlx-coding` routed to Gemma and `mlx-plan` routed to Devstral.
7. Stop the Gemma role server.
8. Confirm `mlx-coding` falls back to the active/default model and logs the fallback.

## Open Decisions Deferred

- Memory class warnings and hard limits.
- Model presets such as Conservative, Balanced, and Experimental.
- Context-budget controls per role.
- Verifier and stretch roles.
- Running multiple independent provider endpoints.
