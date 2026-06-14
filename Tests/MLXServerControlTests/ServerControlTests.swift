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

private struct FakeProcessLauncher: ProcessLaunching {
    let process: FakeManagedProcess

    func makeProcess() -> ManagedProcess {
        process
    }
}

private struct FakePortChecker: ServerPortChecking {
    let isAvailable: Bool

    func isPortAvailable(host: String, port: Int) -> Bool {
        isAvailable
    }
}
