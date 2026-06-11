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
