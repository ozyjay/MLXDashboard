import XCTest
import MLXCore
@testable import MLXServerControl

final class ServerControlTests: XCTestCase {
    func testControllerStartsAndStopsOwnedMLXServerProcess() throws {
        let process = FakeManagedProcess()
        let launcher = FakeProcessLauncher(process: process)
        let controller = ServerProcessController(processLauncher: launcher)
        let settings = DashboardSettings(activeModel: "mlx-community/Tiny")

        try controller.start(settings: settings, pythonExecutable: URL(filePath: "/venv/bin/python"))

        XCTAssertEqual(controller.state, .running)
        XCTAssertEqual(process.executableURL?.path, "/venv/bin/python")
        XCTAssertEqual(process.arguments, [
            "-m", "mlx_lm.server",
            "--host", "127.0.0.1",
            "--port", "8080",
            "--model", "mlx-community/Tiny"
        ])

        controller.stop()

        XCTAssertEqual(controller.state, .stopped)
        XCTAssertTrue(process.wasTerminated)
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
    var wasTerminated = false
    var isRunning = false

    func launch() throws {
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
