import Foundation

public protocol ManagedProcess: AnyObject {
    var executableURL: URL? { get set }
    var arguments: [String] { get set }
    var environment: [String: String]? { get set }
    var isRunning: Bool { get }

    func launch() throws
    func terminate()
}

public final class FoundationManagedProcess: ManagedProcess {
    private let process: Process

    public init(process: Process = Process()) {
        self.process = process
    }

    public var executableURL: URL? {
        get { process.executableURL }
        set { process.executableURL = newValue }
    }

    public var arguments: [String] {
        get { process.arguments ?? [] }
        set { process.arguments = newValue }
    }

    public var environment: [String: String]? {
        get { process.environment }
        set { process.environment = newValue }
    }

    public var isRunning: Bool {
        process.isRunning
    }

    public func launch() throws {
        try process.run()
    }

    public func terminate() {
        process.terminate()
    }
}

public protocol ProcessLaunching {
    func makeProcess() -> ManagedProcess
}

public struct FoundationProcessLauncher: ProcessLaunching {
    public init() {}

    public func makeProcess() -> ManagedProcess {
        FoundationManagedProcess()
    }
}
