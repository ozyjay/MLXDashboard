import XCTest
@testable import MLXCore

final class TelemetryStoreTests: XCTestCase {
    func testAppendLogPersistsPlainTextLogFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MLXDashboardTelemetryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = AppPaths(applicationSupport: root)
        let store = TelemetryStore(logFileURL: paths.logsDirectory.appending(path: "mlxdashboard.log"))

        store.appendLog("Provider rejected GET /api/ps: unsupported route")

        let logText = try String(contentsOf: paths.logsDirectory.appending(path: "mlxdashboard.log"), encoding: .utf8)
        XCTAssertTrue(logText.contains("Provider rejected GET /api/ps: unsupported route"))
        XCTAssertTrue(logText.contains("Z Provider rejected"))
    }
}
