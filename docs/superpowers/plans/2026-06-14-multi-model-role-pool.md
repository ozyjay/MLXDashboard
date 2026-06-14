# Multi-Model Role Pool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local multi-model role server pool so `mlx-ask`, `mlx-plan`, and `mlx-fast` can route to different assigned MLX models while duplicate assignments share one process.

**Architecture:** Introduce a focused role-pool controller in `MLXServerControl` that plans one `mlx_lm.server` per unique model, always bound to `127.0.0.1`. Refactor provider upstream proxying so `ProviderRouter` selects a per-request upstream endpoint from the pool and falls back to the default active endpoint when a role endpoint is missing or stopped. Surface compact role-server status rows in the existing dashboard controls.

**Tech Stack:** Swift Package Manager, SwiftUI, Combine, XCTest, SwiftNIO provider server, `mlx_lm.server` managed through `Process`.

---

## File Structure

- Modify `Sources/MLXCore/DashboardSettings.swift`
  - Add `ProviderModelRole.orderedRoutingRoles` and `displayName`.
  - Keep role ordering centralized as ask, plan, coding for deterministic port assignment and UI rows.

- Modify `Sources/MLXServerControl/ServerProcessController.swift`
  - Add `makeArguments(modelID:port:serverFlags:)`.
  - Keep `makeArguments(settings:)` as compatibility wrapper.
  - Keep `--host 127.0.0.1` hardcoded and `--host` stripping unchanged.

- Create `Sources/MLXServerControl/RoleServerPoolController.swift`
  - Plan model-to-port assignments from `DashboardSettings`.
  - Start one process per unique assigned model.
  - Publish role status rows for ask, plan, and coding.
  - Expose default and role upstream endpoints for the provider.
  - Stop all owned processes, restart one role's backing process, and stop one role's backing process.

- Modify `Tests/MLXServerControlTests/ServerControlTests.swift`
  - Add argument-builder coverage for explicit model and port.
  - Add role-pool planning, duplicate-sharing, failure, and stop-all tests.
  - Extend the fake launcher so tests can create multiple fake processes.

- Modify `Sources/MLXProviderServer/ProviderTypes.swift`
  - Add `ProviderUpstreamEndpoint`.
  - Add `ProviderUpstreamProxyClient` with `proxy(_:to:)` and `proxyStream(_:to:)`.

- Modify `Sources/MLXProviderServer/URLSessionProviderUpstreamClient.swift`
  - Keep existing `ProviderUpstreamClient` behavior for compatibility.
  - Add `URLSessionProviderUpstreamProxyClient` that proxies to the selected endpoint URL per request.

- Modify `Sources/MLXProviderServer/ProviderRouter.swift`
  - Accept a default endpoint provider and a role endpoint provider.
  - Route aliases and planning-mode prompts to role endpoints when available.
  - Rewrite payload `model` to the selected upstream model.
  - Include upstream base URL, upstream port, and fallback reason in diagnostics.

- Modify `Tests/MLXProviderServerTests/ProviderRouterTests.swift`
  - Replace or adapt fake upstreams for the new proxy-client path.
  - Add routing tests for role endpoint selection, shared model endpoints, fallback, and debug payload fields.

- Modify `Sources/MLXDashboardApp/DashboardViewModel.swift`
  - Replace the single runtime process path with `RoleServerPoolController`.
  - Keep public behavior of Start Server, Stop Server, Restart Server, and Start Provider.
  - Store a thread-safe upstream endpoint snapshot read by `ProviderRouter`.
  - Add restart/stop methods for one role server.

- Modify `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`
  - Cover start-server launching only unique role models.
  - Cover provider startup receiving role endpoints.
  - Cover stopping server pool stopping every owned process.

- Modify `Sources/MLXDashboardApp/ContentView.swift`
  - Add a compact role-server status table under the existing server controls.
  - Add restart and stop controls per role row.

## Task 1: Centralize Role Ordering and Server Arguments

**Files:**
- Modify: `Sources/MLXCore/DashboardSettings.swift`
- Modify: `Sources/MLXServerControl/ServerProcessController.swift`
- Modify: `Tests/MLXServerControlTests/ServerControlTests.swift`

- [ ] **Step 1: Add failing tests for ordered roles and explicit arguments**

Add these tests to `Tests/MLXServerControlTests/ServerControlTests.swift`:

```swift
func testProviderModelRolesHaveDeterministicRoutingOrder() {
    XCTAssertEqual(ProviderModelRole.orderedRoutingRoles, [.ask, .plan, .coding])
    XCTAssertEqual(ProviderModelRole.ask.displayName, "Ask")
    XCTAssertEqual(ProviderModelRole.plan.displayName, "Plan")
    XCTAssertEqual(ProviderModelRole.coding.displayName, "Coding")
}

func testMakeArgumentsUsesExplicitModelPortAndLocalhost() {
    let controller = ServerProcessController()

    let arguments = controller.makeArguments(
        modelID: "mlx-community/Devstral",
        port: 8081,
        serverFlags: ["--temp", "0.2", "--host", "0.0.0.0", "--host=0.0.0.0"]
    )

    XCTAssertEqual(
        arguments,
        [
            "-m", "mlx_lm", "server",
            "--host", "127.0.0.1",
            "--port", "8081",
            "--model", "mlx-community/Devstral",
            "--temp", "0.2"
        ]
    )
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter ServerControlTests/testProviderModelRolesHaveDeterministicRoutingOrder
swift test --filter ServerControlTests/testMakeArgumentsUsesExplicitModelPortAndLocalhost
```

Expected: compile failure for missing `orderedRoutingRoles`, `displayName`, and `makeArguments(modelID:port:serverFlags:)`.

- [ ] **Step 3: Implement role ordering and explicit argument builder**

In `Sources/MLXCore/DashboardSettings.swift`, update `ProviderModelRole`:

```swift
public enum ProviderModelRole: String, Codable, Equatable, Sendable {
    case ask
    case plan
    case coding

    public static let orderedRoutingRoles: [ProviderModelRole] = [.ask, .plan, .coding]

    public var displayName: String {
        switch self {
        case .ask:
            "Ask"
        case .plan:
            "Plan"
        case .coding:
            "Coding"
        }
    }
}
```

In `Sources/MLXServerControl/ServerProcessController.swift`, replace `makeArguments(settings:)` with:

```swift
public func makeArguments(settings: DashboardSettings) -> [String] {
    makeArguments(
        modelID: settings.activeModel,
        port: settings.mlxPort,
        serverFlags: settings.serverFlags
    )
}

public func makeArguments(modelID: String?, port: Int, serverFlags: [String]) -> [String] {
    var arguments = [
        "-m", "mlx_lm", "server",
        "--host", DashboardSettings.localMLXHost,
        "--port", String(port)
    ]
    if let modelID, !modelID.isEmpty {
        arguments += ["--model", modelID]
    }
    arguments += sanitizedServerFlags(serverFlags)
    return arguments
}
```

- [ ] **Step 4: Run tests to verify Task 1 passes**

Run:

```bash
swift test --filter ServerControlTests/testProviderModelRolesHaveDeterministicRoutingOrder
swift test --filter ServerControlTests/testMakeArgumentsUsesExplicitModelPortAndLocalhost
swift test --filter ServerControlTests/testServerStartsProcessWithArguments
swift test --filter ServerControlTests/testServerArgumentsBindToLocalhostEvenWhenSettingsHostDiffers
swift test --filter ServerControlTests/testServerArgumentsStripUserProvidedHostFlags
```

Expected: all listed tests pass.

- [ ] **Step 5: Commit Task 1**

Run:

```bash
git add Sources/MLXCore/DashboardSettings.swift Sources/MLXServerControl/ServerProcessController.swift Tests/MLXServerControlTests/ServerControlTests.swift
git commit -m "Prepare role ordering and server arguments"
```

## Task 2: Build Role Server Pool Planning

**Files:**
- Create: `Sources/MLXServerControl/RoleServerPoolController.swift`
- Modify: `Tests/MLXServerControlTests/ServerControlTests.swift`

- [ ] **Step 1: Write failing pool-planning tests**

Add these tests to `Tests/MLXServerControlTests/ServerControlTests.swift`:

```swift
func testRoleServerPlanSharesDuplicateAssignedModels() {
    let settings = DashboardSettings(
        activeModel: "mlx-community/gemma4",
        mlxPort: 8080,
        providerRoleAssignments: ProviderRoleAssignments(
            ask: "mlx-community/gemma4",
            plan: "mlx-community/devstral",
            coding: "mlx-community/gemma4"
        )
    )

    let plan = RoleServerPoolController.makePlan(settings: settings)

    XCTAssertEqual(plan.servers.map(\.modelID), ["mlx-community/gemma4", "mlx-community/devstral"])
    XCTAssertEqual(plan.servers.map(\.port), [8080, 8081])
    XCTAssertEqual(plan.defaultEndpoint.modelID, "mlx-community/gemma4")
    XCTAssertEqual(plan.defaultEndpoint.port, 8080)
    XCTAssertEqual(plan.endpoint(for: .ask)?.port, 8080)
    XCTAssertEqual(plan.endpoint(for: .plan)?.port, 8081)
    XCTAssertEqual(plan.endpoint(for: .coding)?.port, 8080)
}

func testRoleServerPlanAssignsDistinctRolePortsAfterDefaultPort() {
    let settings = DashboardSettings(
        activeModel: "mlx-community/base",
        mlxPort: 9000,
        providerRoleAssignments: ProviderRoleAssignments(
            ask: "mlx-community/ask",
            plan: "mlx-community/plan",
            coding: "mlx-community/coding"
        )
    )

    let plan = RoleServerPoolController.makePlan(settings: settings)

    XCTAssertEqual(plan.servers.map(\.modelID), [
        "mlx-community/base",
        "mlx-community/ask",
        "mlx-community/plan",
        "mlx-community/coding"
    ])
    XCTAssertEqual(plan.servers.map(\.port), [9000, 9001, 9002, 9003])
    XCTAssertEqual(plan.endpoint(for: .ask)?.port, 9001)
    XCTAssertEqual(plan.endpoint(for: .plan)?.port, 9002)
    XCTAssertEqual(plan.endpoint(for: .coding)?.port, 9003)
}

func testRoleServerPlanMarksUnassignedRoles() {
    let settings = DashboardSettings(
        activeModel: "mlx-community/base",
        providerRoleAssignments: ProviderRoleAssignments(plan: "mlx-community/plan")
    )

    let plan = RoleServerPoolController.makePlan(settings: settings)

    XCTAssertEqual(plan.status(for: .ask).kind, .unassigned)
    XCTAssertEqual(plan.status(for: .plan).kind, .planned)
    XCTAssertEqual(plan.status(for: .coding).kind, .unassigned)
}

func testRoleServerPlanPreservesMissingActiveModel() {
    let settings = DashboardSettings(
        activeModel: nil,
        mlxPort: 8080,
        providerRoleAssignments: ProviderRoleAssignments(plan: "mlx-community/devstral")
    )

    let plan = RoleServerPoolController.makePlan(settings: settings)

    XCTAssertNil(plan.defaultEndpoint.modelID)
    XCTAssertEqual(plan.defaultEndpoint.port, 8080)
    XCTAssertEqual(plan.servers.map(\.modelID), [nil, "mlx-community/devstral"])
    XCTAssertEqual(plan.servers.map(\.port), [8080, 8081])
    XCTAssertEqual(plan.endpoint(for: .plan)?.modelID, "mlx-community/devstral")
    XCTAssertEqual(plan.endpoint(for: .plan)?.port, 8081)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter ServerControlTests/testRoleServerPlanSharesDuplicateAssignedModels
swift test --filter ServerControlTests/testRoleServerPlanAssignsDistinctRolePortsAfterDefaultPort
swift test --filter ServerControlTests/testRoleServerPlanMarksUnassignedRoles
swift test --filter ServerControlTests/testRoleServerPlanPreservesMissingActiveModel
```

Expected: compile failure for missing `RoleServerPoolController` and related types.

- [ ] **Step 3: Add role pool planning types**

Create `Sources/MLXServerControl/RoleServerPoolController.swift`:

```swift
import Combine
import Foundation
import MLXCore

public enum RoleServerStatusKind: String, Equatable, Sendable {
    case unassigned
    case planned
    case starting
    case running
    case shared
    case fallback
    case failed
    case stopped
}

public struct RoleServerEndpoint: Equatable, Sendable {
    public var modelID: String?
    public var port: Int
    public var baseURL: URL

    public init(modelID: String?, port: Int, baseURL: URL) {
        self.modelID = modelID
        self.port = port
        self.baseURL = baseURL
    }
}

public struct RoleServerStatusRow: Identifiable, Equatable, Sendable {
    public var id: ProviderModelRole { role }
    public var role: ProviderModelRole
    public var assignedModel: String?
    public var endpoint: RoleServerEndpoint?
    public var kind: RoleServerStatusKind
    public var detail: String

    public init(
        role: ProviderModelRole,
        assignedModel: String?,
        endpoint: RoleServerEndpoint?,
        kind: RoleServerStatusKind,
        detail: String
    ) {
        self.role = role
        self.assignedModel = assignedModel
        self.endpoint = endpoint
        self.kind = kind
        self.detail = detail
    }
}

public struct RoleServerPlan: Equatable, Sendable {
    public struct Server: Equatable, Sendable {
        public var modelID: String?
        public var port: Int
        public var endpoint: RoleServerEndpoint
    }

    public var servers: [Server]
    public var defaultEndpoint: RoleServerEndpoint
    public var roleEndpoints: [ProviderModelRole: RoleServerEndpoint]
    public var roleStatuses: [RoleServerStatusRow]

    public func endpoint(for role: ProviderModelRole) -> RoleServerEndpoint? {
        roleEndpoints[role]
    }

    public func status(for role: ProviderModelRole) -> RoleServerStatusRow {
        roleStatuses.first { $0.role == role } ?? RoleServerStatusRow(
            role: role,
            assignedModel: nil,
            endpoint: nil,
            kind: .unassigned,
            detail: "No model assigned"
        )
    }
}

public final class RoleServerPoolController: ObservableObject {
    @Published public private(set) var state: ServerState = .stopped
    @Published public private(set) var lastError: String?
    @Published public private(set) var roleStatuses: [RoleServerStatusRow] = ProviderModelRole.orderedRoutingRoles.map {
        RoleServerStatusRow(role: $0, assignedModel: nil, endpoint: nil, kind: .unassigned, detail: "No model assigned")
    }

    public private(set) var defaultEndpoint: RoleServerEndpoint?
    public private(set) var roleEndpoints: [ProviderModelRole: RoleServerEndpoint] = [:]

    private let processLauncher: ProcessLaunching
    private let portChecker: ServerPortChecking
    private let argumentBuilder = ServerProcessController()
    private var processesByPort: [Int: ManagedProcess] = [:]
    private var plan: RoleServerPlan?

    public init(
        processLauncher: ProcessLaunching = FoundationProcessLauncher(),
        portChecker: ServerPortChecking = TCPServerPortChecker()
    ) {
        self.processLauncher = processLauncher
        self.portChecker = portChecker
    }

    public static func makePlan(settings: DashboardSettings) -> RoleServerPlan {
        let activeModel = settings.activeModel?.isEmpty == false ? settings.activeModel : nil
        var modelPorts: [String: Int] = [:]
        if let activeModel {
            modelPorts[activeModel] = settings.mlxPort
        }
        var servers: [RoleServerPlan.Server] = []

        func endpoint(modelID: String?, port: Int) -> RoleServerEndpoint {
            RoleServerEndpoint(
                modelID: modelID,
                port: port,
                baseURL: URL(string: "http://\(DashboardSettings.localMLXHost):\(port)")!
            )
        }

        let defaultEndpoint = endpoint(modelID: activeModel, port: settings.mlxPort)
        servers.append(RoleServerPlan.Server(modelID: activeModel, port: settings.mlxPort, endpoint: defaultEndpoint))

        var nextPort = settings.mlxPort + 1
        var roleEndpoints: [ProviderModelRole: RoleServerEndpoint] = [:]
        var roleStatuses: [RoleServerStatusRow] = []

        for role in ProviderModelRole.orderedRoutingRoles {
            guard let assignedModel = settings.providerRoleAssignments.model(for: role), !assignedModel.isEmpty else {
                roleStatuses.append(RoleServerStatusRow(role: role, assignedModel: nil, endpoint: nil, kind: .unassigned, detail: "No model assigned"))
                continue
            }
            let port: Int
            if let existingPort = modelPorts[assignedModel] {
                port = existingPort
            } else {
                port = nextPort
                nextPort += 1
                modelPorts[assignedModel] = port
                let nextEndpoint = endpoint(modelID: assignedModel, port: port)
                servers.append(RoleServerPlan.Server(modelID: assignedModel, port: port, endpoint: nextEndpoint))
            }
            let selectedEndpoint = endpoint(modelID: assignedModel, port: port)
            roleEndpoints[role] = selectedEndpoint
            roleStatuses.append(RoleServerStatusRow(role: role, assignedModel: assignedModel, endpoint: selectedEndpoint, kind: .planned, detail: "Ready to start"))
        }

        return RoleServerPlan(
            servers: servers,
            defaultEndpoint: defaultEndpoint,
            roleEndpoints: roleEndpoints,
            roleStatuses: roleStatuses
        )
    }
}
```

- [ ] **Step 4: Run tests to verify Task 2 passes**

Run:

```bash
swift test --filter ServerControlTests/testRoleServerPlan
```

Expected: all three role plan tests pass.

- [ ] **Step 5: Commit Task 2**

Run:

```bash
git add Sources/MLXServerControl/RoleServerPoolController.swift Tests/MLXServerControlTests/ServerControlTests.swift
git commit -m "Add role server pool planning"
```

## Task 3: Start, Stop, and Report Role Pool Processes

**Files:**
- Modify: `Sources/MLXServerControl/RoleServerPoolController.swift`
- Modify: `Tests/MLXServerControlTests/ServerControlTests.swift`

- [ ] **Step 1: Extend fake process launcher for multiple processes**

In `Tests/MLXServerControlTests/ServerControlTests.swift`, replace the single-process fake launcher with this queue-backed launcher while keeping the current `FakeManagedProcess` type:

```swift
private final class FakeProcessLauncher: ProcessLaunching {
    var processes: [FakeManagedProcess]

    init(process: FakeManagedProcess = FakeManagedProcess()) {
        self.processes = [process]
    }

    init(processes: [FakeManagedProcess]) {
        self.processes = processes
    }

    func makeProcess() -> ManagedProcess {
        if processes.isEmpty {
            let process = FakeManagedProcess()
            processes.append(process)
            return process
        }
        return processes.removeFirst()
    }
}
```

Keep the existing `FakeManagedProcess` type and replace `FakePortChecker` in Step 2.

- [ ] **Step 2: Add failing lifecycle tests**

Add these tests to `Tests/MLXServerControlTests/ServerControlTests.swift`:

```swift
func testRoleServerPoolStartsOneProcessPerUniqueModel() throws {
    let gemma = FakeManagedProcess()
    let devstral = FakeManagedProcess()
    let launcher = FakeProcessLauncher(processes: [gemma, devstral])
    let controller = RoleServerPoolController(
        processLauncher: launcher,
        portChecker: FakePortChecker(isAvailable: true)
    )
    let settings = DashboardSettings(
        activeModel: "mlx-community/gemma4",
        mlxPort: 8080,
        providerRoleAssignments: ProviderRoleAssignments(
            ask: "mlx-community/gemma4",
            plan: "mlx-community/devstral",
            coding: "mlx-community/gemma4"
        )
    )

    try controller.start(settings: settings, pythonExecutable: URL(filePath: "/usr/bin/python3"))

    XCTAssertTrue(gemma.wasLaunched)
    XCTAssertTrue(devstral.wasLaunched)
    XCTAssertEqual(gemma.arguments, [
        "-m", "mlx_lm", "server", "--host", "127.0.0.1", "--port", "8080", "--model", "mlx-community/gemma4"
    ])
    XCTAssertEqual(devstral.arguments, [
        "-m", "mlx_lm", "server", "--host", "127.0.0.1", "--port", "8081", "--model", "mlx-community/devstral"
    ])
    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(controller.endpoint(for: .ask)?.port, 8080)
    XCTAssertEqual(controller.endpoint(for: .plan)?.port, 8081)
    XCTAssertEqual(controller.endpoint(for: .coding)?.port, 8080)
    XCTAssertEqual(controller.roleStatuses.map(\.kind), [.shared, .running, .shared])
}

func testRoleServerPoolStopsEveryOwnedProcess() throws {
    let base = FakeManagedProcess()
    let ask = FakeManagedProcess()
    let plan = FakeManagedProcess()
    let launcher = FakeProcessLauncher(processes: [base, ask, plan])
    let controller = RoleServerPoolController(processLauncher: launcher, portChecker: FakePortChecker(isAvailable: true))
    let settings = DashboardSettings(
        activeModel: "base",
        providerRoleAssignments: ProviderRoleAssignments(ask: "ask", plan: "plan")
    )

    try controller.start(settings: settings, pythonExecutable: URL(filePath: "/usr/bin/python3"))
    controller.stopAll()

    XCTAssertTrue(base.wasTerminated)
    XCTAssertTrue(ask.wasTerminated)
    XCTAssertTrue(plan.wasTerminated)
    XCTAssertEqual(controller.state, .stopped)
    XCTAssertNil(controller.defaultEndpoint)
    XCTAssertEqual(controller.roleEndpoints, [:])
}

func testRoleServerPoolKeepsDefaultRunningWhenAdditionalRolePortUnavailable() throws {
    let base = FakeManagedProcess()
    let launcher = FakeProcessLauncher(processes: [base])
    let controller = RoleServerPoolController(
        processLauncher: launcher,
        portChecker: FakePortChecker(unavailablePorts: [8081])
    )
    let settings = DashboardSettings(
        activeModel: "base",
        mlxPort: 8080,
        providerRoleAssignments: ProviderRoleAssignments(plan: "plan")
    )

    try controller.start(settings: settings, pythonExecutable: URL(filePath: "/usr/bin/python3"))

    XCTAssertTrue(base.wasLaunched)
    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(controller.endpoint(for: .plan), nil)
    XCTAssertEqual(controller.status(for: .plan).kind, .fallback)
    XCTAssertEqual(controller.status(for: .plan).detail, "Port 8081 unavailable; using active model")
}
```

Update `FakePortChecker` so it can target specific ports:

```swift
private struct FakePortChecker: ServerPortChecking {
    var isAvailable: Bool = true
    var unavailablePorts: Set<Int> = []

    func isPortAvailable(host: String, port: Int) -> Bool {
        isAvailable && !unavailablePorts.contains(port)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:

```bash
swift test --filter ServerControlTests/testRoleServerPoolStartsOneProcessPerUniqueModel
swift test --filter ServerControlTests/testRoleServerPoolStopsEveryOwnedProcess
swift test --filter ServerControlTests/testRoleServerPoolKeepsDefaultRunningWhenAdditionalRolePortUnavailable
```

Expected: compile failure for missing `start`, `stopAll`, `endpoint(for:)`, and `status(for:)`.

- [ ] **Step 4: Implement pool lifecycle**

Add these methods to `RoleServerPoolController`:

```swift
public func endpoint(for role: ProviderModelRole) -> RoleServerEndpoint? {
    roleEndpoints[role]
}

public func status(for role: ProviderModelRole) -> RoleServerStatusRow {
    roleStatuses.first { $0.role == role } ?? RoleServerStatusRow(
        role: role,
        assignedModel: nil,
        endpoint: nil,
        kind: .unassigned,
        detail: "No model assigned"
    )
}

public func start(settings: DashboardSettings, pythonExecutable: URL) throws {
    guard state != .running else { return }
    state = .starting
    lastError = nil

    let nextPlan = Self.makePlan(settings: settings)
    guard portChecker.isPortAvailable(host: DashboardSettings.localMLXHost, port: nextPlan.defaultEndpoint.port) else {
        let error = ServerProcessControllerError.portUnavailable(
            host: DashboardSettings.localMLXHost,
            port: nextPlan.defaultEndpoint.port
        )
        state = .failed
        lastError = error.localizedDescription
        throw error
    }

    var nextProcesses: [Int: ManagedProcess] = [:]
    var runningEndpointsByPort: [Int: RoleServerEndpoint] = [:]

    for server in nextPlan.servers {
        if server.port != nextPlan.defaultEndpoint.port,
           !portChecker.isPortAvailable(host: DashboardSettings.localMLXHost, port: server.port) {
            continue
        }
        let process = processLauncher.makeProcess()
        process.executableURL = pythonExecutable
        process.arguments = argumentBuilder.makeArguments(
            modelID: server.modelID,
            port: server.port,
            serverFlags: settings.serverFlags
        )
        process.environment = ProcessInfo.processInfo.environment
        try process.launch()
        nextProcesses[server.port] = process
        runningEndpointsByPort[server.port] = server.endpoint
    }

    processesByPort = nextProcesses
    plan = nextPlan
    defaultEndpoint = runningEndpointsByPort[nextPlan.defaultEndpoint.port]
    roleEndpoints = Dictionary(uniqueKeysWithValues: ProviderModelRole.orderedRoutingRoles.compactMap { role in
        guard let plannedEndpoint = nextPlan.endpoint(for: role),
              runningEndpointsByPort[plannedEndpoint.port] != nil
        else { return nil }
        return (role, plannedEndpoint)
    })
    roleStatuses = statuses(from: nextPlan, runningEndpointsByPort: runningEndpointsByPort)
    state = .running
}

public func stopAll() {
    state = .stopping
    for process in processesByPort.values where process.isRunning {
        process.terminate()
    }
    processesByPort = [:]
    plan = nil
    defaultEndpoint = nil
    roleEndpoints = [:]
    roleStatuses = ProviderModelRole.orderedRoutingRoles.map {
        RoleServerStatusRow(role: $0, assignedModel: nil, endpoint: nil, kind: .unassigned, detail: "No model assigned")
    }
    state = .stopped
}

private func statuses(
    from plan: RoleServerPlan,
    runningEndpointsByPort: [Int: RoleServerEndpoint]
) -> [RoleServerStatusRow] {
    var firstRoleForModel: [String: ProviderModelRole] = [:]
    for role in ProviderModelRole.orderedRoutingRoles {
        let status = plan.status(for: role)
        guard let assignedModel = status.assignedModel else { continue }
        firstRoleForModel[assignedModel] = firstRoleForModel[assignedModel] ?? role
    }

    return ProviderModelRole.orderedRoutingRoles.map { role in
        let planned = plan.status(for: role)
        guard let assignedModel = planned.assignedModel, let endpoint = planned.endpoint else {
            return planned
        }
        guard runningEndpointsByPort[endpoint.port] != nil else {
            return RoleServerStatusRow(
                role: role,
                assignedModel: assignedModel,
                endpoint: nil,
                kind: .fallback,
                detail: "Port \(endpoint.port) unavailable; using active model"
            )
        }
        if endpoint.port == plan.defaultEndpoint.port || firstRoleForModel[assignedModel] != role {
            return RoleServerStatusRow(
                role: role,
                assignedModel: assignedModel,
                endpoint: endpoint,
                kind: .shared,
                detail: "Shared on port \(endpoint.port)"
            )
        }
        return RoleServerStatusRow(
            role: role,
            assignedModel: assignedModel,
            endpoint: endpoint,
            kind: .running,
            detail: "Running on port \(endpoint.port)"
        )
    }
}
```

- [ ] **Step 5: Run tests to verify Task 3 passes**

Run:

```bash
swift test --filter ServerControlTests/testRoleServerPool
swift test --filter ServerControlTests/testServer
```

Expected: server-control tests pass.

- [ ] **Step 6: Commit Task 3**

Run:

```bash
git add Sources/MLXServerControl/RoleServerPoolController.swift Tests/MLXServerControlTests/ServerControlTests.swift
git commit -m "Manage role server pool lifecycle"
```

## Task 4: Add Per-Request Provider Upstream Endpoints

**Files:**
- Modify: `Sources/MLXProviderServer/ProviderTypes.swift`
- Modify: `Sources/MLXProviderServer/URLSessionProviderUpstreamClient.swift`
- Modify: `Sources/MLXProviderServer/ProviderRouter.swift`
- Modify: `Tests/MLXProviderServerTests/ProviderRouterTests.swift`

- [ ] **Step 1: Write failing provider routing tests**

Add these tests to `Tests/MLXProviderServerTests/ProviderRouterTests.swift`:

```swift
func testRoleAliasRoutesToAssignedUpstreamEndpoint() async throws {
    let upstream = FakeProxyUpstream()
    let router = ProviderRouter(
        upstream: upstream,
        activeModelProvider: { "mlx-community/gemma4" },
        roleAssignmentsProvider: { ProviderRoleAssignments(plan: "mlx-community/devstral") },
        defaultEndpointProvider: {
            ProviderUpstreamEndpoint(modelID: "mlx-community/gemma4", baseURL: URL(string: "http://127.0.0.1:8080")!, port: 8080)
        },
        roleEndpointProvider: { role in
            role == .plan
                ? ProviderUpstreamEndpoint(modelID: "mlx-community/devstral", baseURL: URL(string: "http://127.0.0.1:8081")!, port: 8081)
                : nil
        }
    )
    let request = makeChatRequest(model: "mlx-plan")

    _ = try await router.route(request)

    XCTAssertEqual(upstream.requests.count, 1)
    XCTAssertEqual(upstream.requests[0].endpoint.modelID, "mlx-community/devstral")
    XCTAssertEqual(upstream.requests[0].endpoint.port, 8081)
    XCTAssertEqual(upstream.decodedBodies[0]["model"] as? String, "mlx-community/devstral")
}

func testRoleAliasFallsBackToDefaultEndpointWhenRoleEndpointMissing() async throws {
    let upstream = FakeProxyUpstream()
    let logger = CapturingProviderLogger()
    let router = ProviderRouter(
        upstream: upstream,
        eventLogger: logger.log,
        activeModelProvider: { "mlx-community/gemma4" },
        roleAssignmentsProvider: { ProviderRoleAssignments(plan: "mlx-community/devstral") },
        defaultEndpointProvider: {
            ProviderUpstreamEndpoint(modelID: "mlx-community/gemma4", baseURL: URL(string: "http://127.0.0.1:8080")!, port: 8080)
        },
        roleEndpointProvider: { _ in nil }
    )
    let request = makeChatRequest(model: "mlx-plan")

    _ = try await router.route(request)

    XCTAssertEqual(upstream.requests[0].endpoint.modelID, "mlx-community/gemma4")
    XCTAssertEqual(upstream.requests[0].endpoint.port, 8080)
    XCTAssertEqual(upstream.decodedBodies[0]["model"] as? String, "mlx-community/gemma4")
    XCTAssertTrue(logger.messages.contains { $0.contains("role server unavailable") })
}
```

Add this fake near the existing `FakeUpstream`:

```swift
private final class FakeProxyUpstream: ProviderUpstreamProxyClient, @unchecked Sendable {
    struct CapturedRequest {
        var request: ProviderRequest
        var endpoint: ProviderUpstreamEndpoint
    }

    var requests: [CapturedRequest] = []
    var decodedBodies: [[String: Any]] = []
    var response = ProviderResponse(status: 200, headers: ["content-type": "application/json"], body: Data(#"{"ok":true}"#.utf8))

    func proxy(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint) async throws -> ProviderResponse {
        requests.append(CapturedRequest(request: request, endpoint: endpoint))
        decodedBodies.append((try JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:])
        return response
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter ProviderRouterTests/testRoleAliasRoutesToAssignedUpstreamEndpoint
swift test --filter ProviderRouterTests/testRoleAliasFallsBackToDefaultEndpointWhenRoleEndpointMissing
```

Expected: compile failure for missing `ProviderUpstreamEndpoint`, `ProviderUpstreamProxyClient`, and new router initializer parameters.

- [ ] **Step 3: Add endpoint and proxy-client types**

In `Sources/MLXProviderServer/ProviderTypes.swift`, add:

```swift
public struct ProviderUpstreamEndpoint: Equatable, Sendable {
    public var modelID: String
    public var baseURL: URL
    public var port: Int?

    public init(modelID: String, baseURL: URL, port: Int?) {
        self.modelID = modelID
        self.baseURL = baseURL
        self.port = port
    }
}

public protocol ProviderUpstreamProxyClient: Sendable {
    func proxy(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint) async throws -> ProviderResponse
    func proxyStream(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint) async throws -> ProviderStreamedResponse
}

public extension ProviderUpstreamProxyClient {
    func proxyStream(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint) async throws -> ProviderStreamedResponse {
        let response = try await proxy(request, to: endpoint)
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            if !response.body.isEmpty {
                continuation.yield(response.body)
            }
            continuation.finish()
        }
        return ProviderStreamedResponse(status: response.status, headers: response.headers, chunks: chunks)
    }
}
```

- [ ] **Step 4: Add URLSession proxy client**

In `Sources/MLXProviderServer/URLSessionProviderUpstreamClient.swift`, add:

```swift
public struct URLSessionProviderUpstreamProxyClient: ProviderUpstreamProxyClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func proxy(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint) async throws -> ProviderResponse {
        try await proxy(request, baseURL: endpoint.baseURL)
    }

    public func proxyStream(_ request: ProviderRequest, to endpoint: ProviderUpstreamEndpoint) async throws -> ProviderStreamedResponse {
        try await proxyStream(request, baseURL: endpoint.baseURL)
    }

    private func proxy(_ request: ProviderRequest, baseURL: URL) async throws -> ProviderResponse {
        let url = baseURL.appending(path: request.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var upstreamRequest = URLRequest(url: url)
        upstreamRequest.httpMethod = request.method
        upstreamRequest.httpBody = request.body
        for (key, value) in request.headers where key != "host" {
            upstreamRequest.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: upstreamRequest)
        let httpResponse = response as? HTTPURLResponse
        return ProviderResponse(
            status: httpResponse?.statusCode ?? 502,
            headers: httpResponse?.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                if let key = entry.key as? String, let value = entry.value as? String {
                    result[key] = value
                }
            } ?? [:],
            body: data
        )
    }

    private func proxyStream(_ request: ProviderRequest, baseURL: URL) async throws -> ProviderStreamedResponse {
        let response = try await proxy(request, baseURL: baseURL)
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            if !response.body.isEmpty {
                continuation.yield(response.body)
            }
            continuation.finish()
        }
        return ProviderStreamedResponse(status: response.status, headers: response.headers, chunks: chunks)
    }
}
```

Keep the existing `URLSessionProviderUpstreamClient` in place.

- [ ] **Step 5: Update router initializer and routing decision**

In `Sources/MLXProviderServer/ProviderRouter.swift`, change the stored upstream property and add endpoint providers:

```swift
private let upstream: any ProviderUpstreamProxyClient
private let defaultEndpointProvider: @Sendable () -> ProviderUpstreamEndpoint?
private let roleEndpointProvider: @Sendable (ProviderModelRole) -> ProviderUpstreamEndpoint?
```

Change the initializer parameters to:

```swift
public init(
    upstream: any ProviderUpstreamProxyClient,
    eventLogger: @escaping @Sendable (String) -> Void = { _ in },
    activeModelProvider: @escaping @Sendable () -> String? = { nil },
    roleAssignmentsProvider: @escaping @Sendable () -> ProviderRoleAssignments = { ProviderRoleAssignments() },
    defaultEndpointProvider: @escaping @Sendable () -> ProviderUpstreamEndpoint? = { nil },
    roleEndpointProvider: @escaping @Sendable (ProviderModelRole) -> ProviderUpstreamEndpoint? = { _ in nil }
) {
    self.upstream = upstream
    self.eventLogger = eventLogger
    self.activeModelProvider = activeModelProvider
    self.roleAssignmentsProvider = roleAssignmentsProvider
    self.defaultEndpointProvider = defaultEndpointProvider
    self.roleEndpointProvider = roleEndpointProvider
}
```

Update the request rewrite path so it asks `routingDecision` for an endpoint and uses that endpoint model:

```swift
let decision = routingDecision(selectedModel: selectedModel, payload: payload, activeModel: activeModel)
payload["model"] = decision.upstreamEndpoint.modelID
```

Update proxy calls:

```swift
let rewritten = requestWithActiveModelIfAvailable(request)
if isStreamingRequest(rewritten.request) {
    return .streamed(try await upstream.proxyStream(rewritten.request, to: rewritten.debugContext.routing.upstreamEndpoint))
}
return .buffered(try await upstream.proxy(rewritten.request, to: rewritten.debugContext.routing.upstreamEndpoint))
```

Replace `routingDecision` fallback calculation with endpoint selection:

```swift
let defaultEndpoint = defaultEndpointProvider() ?? ProviderUpstreamEndpoint(
    modelID: activeModel,
    baseURL: URL(string: "http://127.0.0.1:8080")!,
    port: nil
)
let desiredRoleModel = inferredRole.flatMap { roleAssignmentsProvider().model(for: $0) }
let roleEndpoint = inferredRole.flatMap { roleEndpointProvider($0) }
let selectedEndpoint: ProviderUpstreamEndpoint
let fallbackReason: String?
if let inferredRole, desiredRoleModel != nil, let roleEndpoint {
    selectedEndpoint = roleEndpoint
    fallbackReason = nil
} else if inferredRole != nil, desiredRoleModel == nil {
    selectedEndpoint = defaultEndpoint
    fallbackReason = "no model assigned for inferred role"
} else if inferredRole != nil {
    selectedEndpoint = defaultEndpoint
    fallbackReason = "role server unavailable; using active model"
} else {
    selectedEndpoint = defaultEndpoint
    fallbackReason = nil
}
```

Add `upstreamEndpoint: ProviderUpstreamEndpoint` to `ProviderRoutingDecision`, set `upstreamModel` from `upstreamEndpoint.modelID`, and add these fields to `debugPayload`:

```swift
payload["upstream_base_url"] = upstreamEndpoint.baseURL.absoluteString
if let port = upstreamEndpoint.port {
    payload["upstream_port"] = port
}
```

- [ ] **Step 6: Run provider tests**

Run:

```bash
swift test --filter ProviderRouterTests
```

Expected: provider router tests pass after updating existing tests to construct `FakeProxyUpstream` or a tiny adapter that records the endpoint.

- [ ] **Step 7: Commit Task 4**

Run:

```bash
git add Sources/MLXProviderServer/ProviderTypes.swift Sources/MLXProviderServer/URLSessionProviderUpstreamClient.swift Sources/MLXProviderServer/ProviderRouter.swift Tests/MLXProviderServerTests/ProviderRouterTests.swift
git commit -m "Route provider requests to role endpoints"
```

## Task 5: Wire the Pool into DashboardViewModel

**Files:**
- Modify: `Sources/MLXDashboardApp/DashboardViewModel.swift`
- Modify: `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`

- [ ] **Step 1: Add failing ViewModel integration tests**

Add these tests to `Tests/MLXDashboardAppTests/DashboardViewModelTests.swift`:

```swift
@MainActor
func testStartServerStartsUniqueRoleServerPoolProcesses() async throws {
    let gemma = FakeManagedProcess()
    let devstral = FakeManagedProcess()
    let serverPool = RoleServerPoolController(
        processLauncher: FakeProcessLauncher(processes: [gemma, devstral]),
        portChecker: FakePortChecker(isAvailable: true)
    )
    let viewModel = makeViewModel(serverPoolController: serverPool)
    viewModel.settings.activeModel = "mlx-community/gemma4"
    viewModel.settings.providerRoleAssignments = ProviderRoleAssignments(
        ask: "mlx-community/gemma4",
        plan: "mlx-community/devstral",
        coding: "mlx-community/gemma4"
    )

    try await viewModel.startServer()

    XCTAssertTrue(gemma.wasLaunched)
    XCTAssertTrue(devstral.wasLaunched)
    XCTAssertEqual(viewModel.roleServerStatuses.map(\.kind), [.shared, .running, .shared])
}

@MainActor
func testStopServerStopsRoleServerPoolProcesses() async throws {
    let gemma = FakeManagedProcess()
    let devstral = FakeManagedProcess()
    let serverPool = RoleServerPoolController(
        processLauncher: FakeProcessLauncher(processes: [gemma, devstral]),
        portChecker: FakePortChecker(isAvailable: true)
    )
    let viewModel = makeViewModel(serverPoolController: serverPool)
    viewModel.settings.activeModel = "gemma"
    viewModel.settings.providerRoleAssignments = ProviderRoleAssignments(plan: "devstral")

    try await viewModel.startServer()
    await viewModel.stopServer()

    XCTAssertTrue(gemma.wasTerminated)
    XCTAssertTrue(devstral.wasTerminated)
}
```

Update the existing `makeViewModel` helper signature to include `serverPoolController: RoleServerPoolController = RoleServerPoolController()` and pass that argument into the `DashboardViewModel` initializer.

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter DashboardViewModelTests/testStartServerStartsUniqueRoleServerPoolProcesses
swift test --filter DashboardViewModelTests/testStopServerStopsRoleServerPoolProcesses
```

Expected: compile failure for missing initializer parameter and `roleServerStatuses`.

- [ ] **Step 3: Add endpoint snapshot state**

In `Sources/MLXDashboardApp/DashboardViewModel.swift`, add this private state type near `ActiveModelSelection` and `ProviderRoleAssignmentState`:

```swift
private final class ProviderUpstreamEndpointState: @unchecked Sendable {
    private let lock = NSLock()
    private var defaultEndpointValue: ProviderUpstreamEndpoint?
    private var roleEndpointsValue: [ProviderModelRole: ProviderUpstreamEndpoint] = [:]

    var defaultEndpoint: ProviderUpstreamEndpoint? {
        lock.withLock { defaultEndpointValue }
    }

    func endpoint(for role: ProviderModelRole) -> ProviderUpstreamEndpoint? {
        lock.withLock { roleEndpointsValue[role] }
    }

    func update(defaultEndpoint: RoleServerEndpoint?, roleEndpoints: [ProviderModelRole: RoleServerEndpoint]) {
        lock.withLock {
            self.defaultEndpointValue = defaultEndpoint.map {
                ProviderUpstreamEndpoint(modelID: $0.modelID, baseURL: $0.baseURL, port: $0.port)
            }
            self.roleEndpointsValue = Dictionary(uniqueKeysWithValues: roleEndpoints.map { role, endpoint in
                (
                    role,
                    ProviderUpstreamEndpoint(modelID: endpoint.modelID, baseURL: endpoint.baseURL, port: endpoint.port)
                )
            })
        }
    }

    func clear() {
        lock.withLock {
            defaultEndpointValue = nil
            roleEndpointsValue = [:]
        }
    }
}
```

- [ ] **Step 4: Replace single server controller wiring**

In `DashboardViewModel`, replace:

```swift
let serverController: ServerProcessController
```

with:

```swift
let serverPoolController: RoleServerPoolController
private let providerUpstreamEndpointState: ProviderUpstreamEndpointState
```

Add:

```swift
@Published private(set) var roleServerStatuses: [RoleServerStatusRow] = []
```

Update the initializer parameter:

```swift
serverPoolController: RoleServerPoolController = RoleServerPoolController(),
providerUpstreamEndpointState: ProviderUpstreamEndpointState = ProviderUpstreamEndpointState(),
```

Assign both properties and set the initial statuses:

```swift
self.serverPoolController = serverPoolController
self.providerUpstreamEndpointState = providerUpstreamEndpointState
self.roleServerStatuses = serverPoolController.roleStatuses
```

Update `startServer()`:

```swift
try serverPoolController.start(settings: settings, pythonExecutable: pythonExecutable)
roleServerStatuses = serverPoolController.roleStatuses
providerUpstreamEndpointState.update(
    defaultEndpoint: serverPoolController.defaultEndpoint,
    roleEndpoints: serverPoolController.roleEndpoints
)
```

Update `stopServer()`:

```swift
serverPoolController.stopAll()
roleServerStatuses = serverPoolController.roleStatuses
providerUpstreamEndpointState.clear()
```

Update `restartServer()` to call `stopServer()` then `startServer()`.

- [ ] **Step 5: Wire provider start to endpoint-aware upstreams**

In `startProvider()`, replace the single base URL client with:

```swift
let upstream = URLSessionProviderUpstreamProxyClient()
let router = ProviderRouter(
    upstream: upstream,
    eventLogger: { [weak self] message in self?.appendLog(message) },
    activeModelProvider: { [activeModelSelection] in activeModelSelection.modelID },
    roleAssignmentsProvider: { [providerRoleAssignmentState] in providerRoleAssignmentState.assignments },
    defaultEndpointProvider: { [providerUpstreamEndpointState] in providerUpstreamEndpointState.defaultEndpoint },
    roleEndpointProvider: { [providerUpstreamEndpointState] role in providerUpstreamEndpointState.endpoint(for: role) }
)
```

- [ ] **Step 6: Run ViewModel tests**

Run:

```bash
swift test --filter DashboardViewModelTests
```

Expected: dashboard view-model tests pass after updating helper construction from `serverController:` to `serverPoolController:`.

- [ ] **Step 7: Commit Task 5**

Run:

```bash
git add Sources/MLXDashboardApp/DashboardViewModel.swift Tests/MLXDashboardAppTests/DashboardViewModelTests.swift
git commit -m "Wire dashboard to role server pool"
```

## Task 6: Add Role Status UI and Manual Role Controls

**Files:**
- Modify: `Sources/MLXServerControl/RoleServerPoolController.swift`
- Modify: `Sources/MLXDashboardApp/DashboardViewModel.swift`
- Modify: `Sources/MLXDashboardApp/ContentView.swift`
- Modify: `Tests/MLXServerControlTests/ServerControlTests.swift`

- [ ] **Step 1: Add failing stop-role test**

Add this test to `Tests/MLXServerControlTests/ServerControlTests.swift`:

```swift
func testStoppingOneRoleFallsBackOnlyThatRoleWhenProcessIsUnique() throws {
    let base = FakeManagedProcess()
    let plan = FakeManagedProcess()
    let controller = RoleServerPoolController(
        processLauncher: FakeProcessLauncher(processes: [base, plan]),
        portChecker: FakePortChecker(isAvailable: true)
    )
    let settings = DashboardSettings(
        activeModel: "base",
        providerRoleAssignments: ProviderRoleAssignments(plan: "plan")
    )
    try controller.start(settings: settings, pythonExecutable: URL(filePath: "/usr/bin/python3"))

    controller.stop(role: .plan)

    XCTAssertFalse(base.wasTerminated)
    XCTAssertTrue(plan.wasTerminated)
    XCTAssertNil(controller.endpoint(for: .plan))
    XCTAssertEqual(controller.status(for: .plan).kind, .fallback)
    XCTAssertEqual(controller.status(for: .plan).detail, "Stopped; using active model")
}

func testRestartingStoppedRoleLaunchesOnlyThatRoleProcess() throws {
    let base = FakeManagedProcess()
    let firstPlan = FakeManagedProcess()
    let restartedPlan = FakeManagedProcess()
    let controller = RoleServerPoolController(
        processLauncher: FakeProcessLauncher(processes: [base, firstPlan, restartedPlan]),
        portChecker: FakePortChecker(isAvailable: true)
    )
    let settings = DashboardSettings(
        activeModel: "base",
        providerRoleAssignments: ProviderRoleAssignments(plan: "plan")
    )
    try controller.start(settings: settings, pythonExecutable: URL(filePath: "/usr/bin/python3"))
    controller.stop(role: .plan)

    try controller.restart(role: .plan, settings: settings, pythonExecutable: URL(filePath: "/usr/bin/python3"))

    XCTAssertFalse(base.wasTerminated)
    XCTAssertTrue(firstPlan.wasTerminated)
    XCTAssertTrue(restartedPlan.wasLaunched)
    XCTAssertEqual(controller.endpoint(for: .plan)?.modelID, "plan")
    XCTAssertEqual(controller.status(for: .plan).kind, .running)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter ServerControlTests/testStoppingOneRoleFallsBackOnlyThatRoleWhenProcessIsUnique
swift test --filter ServerControlTests/testRestartingStoppedRoleLaunchesOnlyThatRoleProcess
```

Expected: compile failure for missing `stop(role:)` and `restart(role:settings:pythonExecutable:)`.

- [ ] **Step 3: Implement stop-role support**

Add this method to `RoleServerPoolController`:

```swift
public func stop(role: ProviderModelRole) {
    guard let endpoint = roleEndpoints[role] else { return }
    let sharingRoles = roleEndpoints.filter { $0.value.port == endpoint.port }.map(\.key)
    if endpoint.port != defaultEndpoint?.port, sharingRoles.count == 1, sharingRoles.first == role,
       let process = processesByPort[endpoint.port] {
        if process.isRunning {
            process.terminate()
        }
        processesByPort.removeValue(forKey: endpoint.port)
    }
    roleEndpoints.removeValue(forKey: role)
    roleStatuses = roleStatuses.map { row in
        guard row.role == role else { return row }
        return RoleServerStatusRow(
            role: row.role,
            assignedModel: row.assignedModel,
            endpoint: nil,
            kind: .fallback,
            detail: "Stopped; using active model"
        )
    }
}
```

Then add this restart method to `RoleServerPoolController`:

```swift
public func restart(role: ProviderModelRole, settings: DashboardSettings, pythonExecutable: URL) throws {
    let nextPlan = Self.makePlan(settings: settings)
    guard let endpoint = nextPlan.endpoint(for: role) else {
        roleStatuses = roleStatuses.map { row in
            guard row.role == role else { return row }
            return RoleServerStatusRow(role: role, assignedModel: nil, endpoint: nil, kind: .unassigned, detail: "No model assigned")
        }
        roleEndpoints.removeValue(forKey: role)
        return
    }
    if endpoint.port == defaultEndpoint?.port {
        roleEndpoints[role] = endpoint
        roleStatuses = roleStatuses.map { row in
            guard row.role == role else { return row }
            return RoleServerStatusRow(
                role: row.role,
                assignedModel: endpoint.modelID,
                endpoint: endpoint,
                kind: .shared,
                detail: "Shared on port \(endpoint.port)"
            )
        }
        return
    }

    stop(role: role)
    guard portChecker.isPortAvailable(host: DashboardSettings.localMLXHost, port: endpoint.port) else {
        roleStatuses = roleStatuses.map { row in
            guard row.role == role else { return row }
            return RoleServerStatusRow(
                role: row.role,
                assignedModel: endpoint.modelID,
                endpoint: nil,
                kind: .fallback,
                detail: "Port \(endpoint.port) unavailable; using active model"
            )
        }
        return
    }

    let process = processLauncher.makeProcess()
    process.executableURL = pythonExecutable
    process.arguments = argumentBuilder.makeArguments(
        modelID: endpoint.modelID,
        port: endpoint.port,
        serverFlags: settings.serverFlags
    )
    process.environment = ProcessInfo.processInfo.environment
    try process.launch()
    processesByPort[endpoint.port] = process
    roleEndpoints[role] = endpoint
    roleStatuses = roleStatuses.map { row in
        guard row.role == role else { return row }
        return RoleServerStatusRow(
            role: row.role,
            assignedModel: endpoint.modelID,
            endpoint: endpoint,
            kind: .running,
            detail: "Running on port \(endpoint.port)"
        )
    }
}
```

- [ ] **Step 4: Add ViewModel methods for role controls**

In `DashboardViewModel`, add:

```swift
func stopRoleServer(_ role: ProviderModelRole) {
    serverPoolController.stop(role: role)
    roleServerStatuses = serverPoolController.roleStatuses
    providerUpstreamEndpointState.update(
        defaultEndpoint: serverPoolController.defaultEndpoint,
        roleEndpoints: serverPoolController.roleEndpoints
    )
}

func restartRoleServer(_ role: ProviderModelRole) async {
    do {
        let pythonExecutable = try await resolvePythonExecutable()
        try serverPoolController.restart(role: role, settings: settings, pythonExecutable: pythonExecutable)
        roleServerStatuses = serverPoolController.roleStatuses
        providerUpstreamEndpointState.update(
            defaultEndpoint: serverPoolController.defaultEndpoint,
            roleEndpoints: serverPoolController.roleEndpoints
        )
    } catch {
        appendLog("Failed to restart \(role.displayName) role server: \(error.localizedDescription)")
    }
}
```

- [ ] **Step 5: Add compact role status table**

In `Sources/MLXDashboardApp/ContentView.swift`, add a `RoleServerStatusTable` near the existing server controls:

```swift
private struct RoleServerStatusTable: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Role Servers")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Role").font(.caption.bold())
                    Text("Assigned model").font(.caption.bold())
                    Text("Port").font(.caption.bold())
                    Text("Status").font(.caption.bold())
                    Text("Detail").font(.caption.bold())
                    Text("").font(.caption.bold())
                }
                ForEach(viewModel.roleServerStatuses) { row in
                    GridRow {
                        Text(row.role.displayName)
                        Text(row.assignedModel ?? "Unassigned")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(row.endpoint.map { String($0.port) } ?? "-")
                        Text(row.kind.rawValue)
                        Text(row.detail)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        HStack(spacing: 6) {
                            Button("Restart") {
                                Task { await viewModel.restartRoleServer(row.role) }
                            }
                            .disabled(row.assignedModel == nil)
                            Button("Stop") {
                                viewModel.stopRoleServer(row.role)
                            }
                            .disabled(row.endpoint == nil)
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }
}
```

Render it below the existing Start/Stop/Restart server button row:

```swift
RoleServerStatusTable(viewModel: viewModel)
```

- [ ] **Step 6: Run server and app tests**

Run:

```bash
swift test --filter ServerControlTests/testStoppingOneRoleFallsBackOnlyThatRoleWhenProcessIsUnique
swift test --filter ServerControlTests/testRestartingStoppedRoleLaunchesOnlyThatRoleProcess
swift test --filter DashboardViewModelTests
swift test --filter MLXDashboardAppTests
```

Expected: listed tests pass.

- [ ] **Step 7: Commit Task 6**

Run:

```bash
git add Sources/MLXServerControl/RoleServerPoolController.swift Sources/MLXDashboardApp/DashboardViewModel.swift Sources/MLXDashboardApp/ContentView.swift Tests/MLXServerControlTests/ServerControlTests.swift
git commit -m "Show and control role server status"
```

## Task 7: Full Verification

**Files:**
- No source edits expected unless verification exposes a defect.

- [ ] **Step 1: Run the full test suite**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 2: Build the app target**

Run:

```bash
swift build
```

Expected: build succeeds without errors.

- [ ] **Step 3: Inspect runtime safety invariants**

Run:

```bash
rg -n "\"0\\.0\\.0\\.0\"|--host|localMLXHost|ProviderUpstreamEndpoint|RoleServerPoolController" Sources Tests docs/notes/mlx-lm-runtime-and-model-planning.md
```

Expected:
- Managed `mlx_lm.server` argument builders use `DashboardSettings.localMLXHost`.
- User-provided `--host` flags remain stripped.
- No new managed MLX runtime path binds to `0.0.0.0`.

- [ ] **Step 4: Manual smoke test with two unique models**

Run the app and perform:

```text
1. Assign ask to Gemma.
2. Assign coding to the same Gemma model.
3. Assign plan to Devstral.
4. Start Server.
5. Start Provider.
6. Confirm role status rows show Ask shared, Coding shared, Plan running.
7. Send a request with model mlx-plan.
8. Confirm logs route mlx-plan to Devstral on the plan port.
9. Send a request with model mlx-fast.
10. Confirm logs route mlx-fast to Gemma on the shared port.
11. Stop the Gemma role row.
12. Confirm mlx-fast falls back to the active/default model and logs the fallback.
```

Expected: the app stays local-only, starts two MLX server processes for Gemma plus Devstral when Gemma is also the active/default model, and provider fallback is visible in logs.

- [ ] **Step 5: Commit verification fixes if any source changed**

If Step 1, Step 2, or Step 3 required source changes, run:

```bash
git add Sources Tests
git commit -m "Fix role server pool verification issues"
```

Expected: no commit is created when verification required no source changes.

## Self-Review Notes

- Spec coverage:
  - Unique model pool and duplicate sharing: Tasks 2 and 3.
  - Localhost binding and stripped host flags: Tasks 1 and 7.
  - Deterministic ports from `mlxPort`: Task 2.
  - Provider role routing and active fallback: Task 4.
  - Debug upstream model/base URL/port/fallback fields: Task 4.
  - Status UI and manual stop/restart controls: Task 6.
  - Stop Server stops every owned process: Task 3 and Task 5.
- Placeholder scan:
  - No deferred implementation markers are present.
- Type consistency:
  - `RoleServerEndpoint` lives in `MLXServerControl`.
  - `ProviderUpstreamEndpoint` lives in `MLXProviderServer`.
  - `DashboardViewModel` converts role endpoints to provider endpoints through `ProviderUpstreamEndpointState`.
