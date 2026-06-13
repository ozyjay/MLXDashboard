import Foundation
import Darwin

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

public protocol ServerPortChecking: Sendable {
    func isPortAvailable(host: String, port: Int) -> Bool
}

public struct TCPServerPortChecker: ServerPortChecking {
    public init() {}

    public func isPortAvailable(host: String, port: Int) -> Bool {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer { Darwin.close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            return false
        }

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(socketDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
