import XCTest
import MLXCore
@testable import MLXServerControl

final class ServerControlTests: XCTestCase {
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

    func testRoleServerPoolStartsDefaultWithoutModelArgumentWhenActiveModelMissing() throws {
        let base = FakeManagedProcess()
        let plan = FakeManagedProcess()
        let launcher = FakeProcessLauncher(processes: [base, plan])
        let controller = RoleServerPoolController(
            processLauncher: launcher,
            portChecker: FakePortChecker(isAvailable: true)
        )
        let settings = DashboardSettings(
            activeModel: nil,
            mlxPort: 8080,
            providerRoleAssignments: ProviderRoleAssignments(plan: "plan")
        )

        try controller.start(settings: settings, pythonExecutable: URL(filePath: "/usr/bin/python3"))

        XCTAssertEqual(base.arguments, ["-m", "mlx_lm", "server", "--host", "127.0.0.1", "--port", "8080"])
        XCTAssertEqual(plan.arguments, ["-m", "mlx_lm", "server", "--host", "127.0.0.1", "--port", "8081", "--model", "plan"])
        XCTAssertNil(controller.defaultEndpoint?.modelID)
        XCTAssertEqual(controller.endpoint(for: .plan)?.modelID, "plan")
    }

    func testRoleServerPoolStopsEveryOwnedProcess() throws {
        let base = FakeManagedProcess()
        let ask = FakeManagedProcess()
        let plan = FakeManagedProcess()
        let launcher = FakeProcessLauncher(processes: [base, ask, plan])
        let controller = RoleServerPoolController(
            processLauncher: launcher,
            portChecker: FakePortChecker(isAvailable: true)
        )
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

    func testProviderModelRolesHaveDeterministicRoutingOrder() {
        XCTAssertEqual(ProviderModelRole.orderedRoutingRoles, [.ask, .plan, .coding])
        XCTAssertEqual(ProviderModelRole.ask.displayName, "Ask")
        XCTAssertEqual(ProviderModelRole.plan.displayName, "Plan")
        XCTAssertEqual(ProviderModelRole.coding.displayName, "Coding")
    }

    func testControllerStartsAndStopsOwnedMLXServerProcess() throws {
        let process = FakeManagedProcess()
        let launcher = FakeProcessLauncher(process: process)
        let controller = ServerProcessController(processLauncher: launcher, portChecker: FakePortChecker(isAvailable: true))
        let settings = DashboardSettings(activeModel: "mlx-community/Tiny")

        try controller.start(settings: settings, pythonExecutable: URL(filePath: "/venv/bin/python"))

        XCTAssertEqual(controller.state, .running)
        XCTAssertEqual(process.executableURL?.path, "/venv/bin/python")
        XCTAssertEqual(process.arguments, [
            "-m", "mlx_lm", "server",
            "--host", "127.0.0.1",
            "--port", "8080",
            "--model", "mlx-community/Tiny"
        ])

        controller.stop()

        XCTAssertEqual(controller.state, .stopped)
        XCTAssertTrue(process.wasTerminated)
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

    func testControllerFailsBeforeLaunchingWhenMLXPortIsUnavailable() throws {
        let process = FakeManagedProcess()
        let launcher = FakeProcessLauncher(process: process)
        let controller = ServerProcessController(processLauncher: launcher, portChecker: FakePortChecker(isAvailable: false))
        let settings = DashboardSettings(mlxPort: 8080)

        XCTAssertThrowsError(
            try controller.start(settings: settings, pythonExecutable: URL(filePath: "/venv/bin/python"))
        ) { error in
            XCTAssertEqual(error as? ServerProcessControllerError, .portUnavailable(host: "127.0.0.1", port: 8080))
        }
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.lastError, "Cannot start mlx-lm because 127.0.0.1:8080 is already in use.")
        XCTAssertFalse(process.wasLaunched)
    }

    func testMLXServerAlwaysBindsToLocalhostEvenWhenSettingsHostIsUnsafe() {
        let controller = ServerProcessController()
        let settings = DashboardSettings(mlxHost: "0.0.0.0")

        let arguments = controller.makeArguments(settings: settings)

        XCTAssertEqual(arguments.hostArgumentValue, "127.0.0.1")
    }

    func testMLXServerFlagsCannotOverrideLocalhostBinding() {
        let controller = ServerProcessController()
        let settings = DashboardSettings(
            mlxHost: "127.0.0.1",
            serverFlags: ["--trust-remote-code", "--host", "0.0.0.0", "--host=::", "--extra"]
        )

        let arguments = controller.makeArguments(settings: settings)

        XCTAssertEqual(arguments.hostArgumentValue, "127.0.0.1")
        XCTAssertFalse(arguments.contains("0.0.0.0"))
        XCTAssertFalse(arguments.contains("--host=::"))
        XCTAssertTrue(arguments.contains("--trust-remote-code"))
        XCTAssertTrue(arguments.contains("--extra"))
    }
}

private extension Array where Element == String {
    var hostArgumentValue: String? {
        guard let index = firstIndex(of: "--host"),
              indices.contains(index + 1)
        else {
            return nil
        }
        return self[index + 1]
    }
}

private final class FakeManagedProcess: ManagedProcess {
    var executableURL: URL?
    var arguments: [String] = []
    var environment: [String: String]?
    var wasLaunched = false
    var wasTerminated = false
    var isRunning = false

    func launch() throws {
        wasLaunched = true
        isRunning = true
    }

    func terminate() {
        wasTerminated = true
        isRunning = false
    }
}

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

private struct FakePortChecker: ServerPortChecking {
    var isAvailable: Bool = true
    var unavailablePorts: Set<Int> = []

    func isPortAvailable(host: String, port: Int) -> Bool {
        isAvailable && !unavailablePorts.contains(port)
    }
}
