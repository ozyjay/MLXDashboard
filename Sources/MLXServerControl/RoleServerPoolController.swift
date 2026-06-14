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

        public init(modelID: String?, port: Int, endpoint: RoleServerEndpoint) {
            self.modelID = modelID
            self.port = port
            self.endpoint = endpoint
        }
    }

    public var servers: [Server]
    public var defaultEndpoint: RoleServerEndpoint
    public var roleEndpoints: [ProviderModelRole: RoleServerEndpoint]
    public var roleStatuses: [RoleServerStatusRow]

    public init(
        servers: [Server],
        defaultEndpoint: RoleServerEndpoint,
        roleEndpoints: [ProviderModelRole: RoleServerEndpoint],
        roleStatuses: [RoleServerStatusRow]
    ) {
        self.servers = servers
        self.defaultEndpoint = defaultEndpoint
        self.roleEndpoints = roleEndpoints
        self.roleStatuses = roleStatuses
    }

    public func endpoint(for role: ProviderModelRole) -> RoleServerEndpoint? {
        roleEndpoints[role]
    }

    public func status(for role: ProviderModelRole) -> RoleServerStatusRow {
        roleStatuses.first(where: { $0.role == role })
        ?? RoleServerStatusRow(
            role: role,
            assignedModel: nil,
            endpoint: nil,
            kind: .unassigned,
            detail: "No model assigned"
        )
    }
}

public final class RoleServerPoolController: ObservableObject {
    @Published public private(set) var state: ServerState
    @Published public private(set) var lastError: String?
    @Published public private(set) var roleStatuses: [RoleServerStatusRow]
    @Published public private(set) var defaultEndpoint: RoleServerEndpoint?
    @Published public private(set) var roleEndpoints: [ProviderModelRole: RoleServerEndpoint]
    public let processLauncher: ProcessLaunching
    public let portChecker: ServerPortChecking
    public let argumentBuilder: ServerProcessController
    public private(set) var processesByPort: [Int: ManagedProcess]
    public private(set) var plan: RoleServerPlan?

    public init(
        processLauncher: ProcessLaunching = FoundationProcessLauncher(),
        portChecker: ServerPortChecking = TCPServerPortChecker(),
        argumentBuilder: ServerProcessController = ServerProcessController()
    ) {
        self.state = .stopped
        self.lastError = nil
        self.roleStatuses = ProviderModelRole.orderedRoutingRoles.map { role in
            RoleServerStatusRow(
                role: role,
                assignedModel: nil,
                endpoint: nil,
                kind: .unassigned,
                detail: "No model assigned"
            )
        }
        self.defaultEndpoint = nil
        self.roleEndpoints = [:]
        self.processLauncher = processLauncher
        self.portChecker = portChecker
        self.argumentBuilder = argumentBuilder
        self.processesByPort = [:]
        self.plan = nil
    }

    public func endpoint(for role: ProviderModelRole) -> RoleServerEndpoint? {
        roleEndpoints[role]
    }

    public func status(for role: ProviderModelRole) -> RoleServerStatusRow {
        roleStatuses.first(where: { $0.role == role }) ?? Self.makeUnassignedStatus(for: role)
    }

    public func start(settings: DashboardSettings, pythonExecutable: URL) throws {
        guard state != .running else {
            return
        }

        state = .starting
        lastError = nil

        let nextPlan = Self.makePlan(settings: settings)
        plan = nextPlan
        roleStatuses = nextPlan.roleStatuses.map { row in
            guard row.kind == .planned else {
                return row
            }
            return RoleServerStatusRow(
                role: row.role,
                assignedModel: row.assignedModel,
                endpoint: row.endpoint,
                kind: .starting,
                detail: "Starting"
            )
        }

        let defaultPort = nextPlan.defaultEndpoint.port
        guard portChecker.isPortAvailable(host: DashboardSettings.localMLXHost, port: defaultPort) else {
            let error = ServerProcessControllerError.portUnavailable(
                host: DashboardSettings.localMLXHost,
                port: defaultPort
            )
            state = .failed
            lastError = error.localizedDescription
            throw error
        }

        var launchedProcesses: [Int: ManagedProcess] = [:]
        var unavailablePorts: Set<Int> = []

        do {
            for server in nextPlan.servers {
                if server.port != defaultPort,
                   !portChecker.isPortAvailable(host: DashboardSettings.localMLXHost, port: server.port) {
                    unavailablePorts.insert(server.port)
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
                launchedProcesses[server.port] = process
            }
        } catch {
            for process in launchedProcesses.values where process.isRunning {
                process.terminate()
            }
            processesByPort = [:]
            defaultEndpoint = nil
            roleEndpoints = [:]
            state = .failed
            lastError = String(describing: error)
            throw error
        }

        processesByPort = launchedProcesses
        defaultEndpoint = nextPlan.defaultEndpoint

        let runningPorts = Set(launchedProcesses.keys)
        roleEndpoints = nextPlan.roleEndpoints.filter { runningPorts.contains($0.value.port) }
        roleStatuses = Self.makeRoleStatuses(
            plan: nextPlan,
            defaultEndpoint: nextPlan.defaultEndpoint,
            runningRoleEndpoints: roleEndpoints,
            unavailablePorts: unavailablePorts
        )
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
        roleStatuses = Self.makeUnassignedStatuses()
        state = .stopped
    }

    public static func makePlan(settings: DashboardSettings) -> RoleServerPlan {
        let defaultModelID = settings.activeModel.flatMap { $0.isEmpty ? nil : $0 }
        let defaultPort = settings.mlxPort
        let defaultEndpoint = makeEndpoint(modelID: defaultModelID, port: defaultPort)

        var modelPorts: [String: Int] = [:]
        var servers: [RoleServerPlan.Server] = [
            RoleServerPlan.Server(modelID: defaultModelID, port: defaultPort, endpoint: defaultEndpoint)
        ]
        if let defaultModelID {
            modelPorts[defaultModelID] = defaultPort
        }
        var nextPort = defaultPort + 1
        var roleEndpoints: [ProviderModelRole: RoleServerEndpoint] = [:]
        var roleStatuses: [RoleServerStatusRow] = []

        for role in ProviderModelRole.orderedRoutingRoles {
            guard let assignedModel = settings.providerRoleAssignments.model(for: role), !assignedModel.isEmpty else {
                roleStatuses.append(
                    RoleServerStatusRow(
                        role: role,
                        assignedModel: nil,
                        endpoint: nil,
                        kind: .unassigned,
                        detail: "No model assigned"
                    )
                )
                continue
            }

            let port: Int
            if let existingPort = modelPorts[assignedModel] {
                port = existingPort
            } else {
                port = nextPort
                nextPort += 1
                modelPorts[assignedModel] = port
                let endpoint = makeEndpoint(modelID: assignedModel, port: port)
                servers.append(RoleServerPlan.Server(modelID: assignedModel, port: port, endpoint: endpoint))
            }

            let endpoint = makeEndpoint(modelID: assignedModel, port: port)
            roleEndpoints[role] = endpoint
            roleStatuses.append(
                RoleServerStatusRow(
                    role: role,
                    assignedModel: assignedModel,
                    endpoint: endpoint,
                    kind: .planned,
                    detail: "Ready to start"
                )
            )
        }

        return RoleServerPlan(
            servers: servers,
            defaultEndpoint: defaultEndpoint,
            roleEndpoints: roleEndpoints,
            roleStatuses: roleStatuses
        )
    }

    private static func makeEndpoint(modelID: String?, port: Int) -> RoleServerEndpoint {
        RoleServerEndpoint(
            modelID: modelID,
            port: port,
            baseURL: URL(string: "http://\(DashboardSettings.localMLXHost):\(port)")!
        )
    }

    private static func makeRoleStatuses(
        plan: RoleServerPlan,
        defaultEndpoint: RoleServerEndpoint,
        runningRoleEndpoints: [ProviderModelRole: RoleServerEndpoint],
        unavailablePorts: Set<Int>
    ) -> [RoleServerStatusRow] {
        var firstOwnedRoleByPort: Set<Int> = []

        return ProviderModelRole.orderedRoutingRoles.map { role in
            let plannedStatus = plan.status(for: role)
            guard let assignedModel = plannedStatus.assignedModel else {
                return makeUnassignedStatus(for: role)
            }

            let plannedEndpoint = plan.endpoint(for: role) ?? plannedStatus.endpoint ?? defaultEndpoint

            guard let runningEndpoint = runningRoleEndpoints[role] else {
                let detail: String
                if unavailablePorts.contains(plannedEndpoint.port) {
                    detail = "Port \(plannedEndpoint.port) unavailable; using active model"
                } else {
                    detail = "Using active model"
                }
                return RoleServerStatusRow(
                    role: role,
                    assignedModel: assignedModel,
                    endpoint: defaultEndpoint,
                    kind: .fallback,
                    detail: detail
                )
            }

            if runningEndpoint.port == defaultEndpoint.port {
                return RoleServerStatusRow(
                    role: role,
                    assignedModel: assignedModel,
                    endpoint: runningEndpoint,
                    kind: .shared,
                    detail: "Shared on port \(runningEndpoint.port)"
                )
            }

            let kind: RoleServerStatusKind = firstOwnedRoleByPort.insert(runningEndpoint.port).inserted ? .running : .shared
            let detail = kind == .running
                ? "Running on port \(runningEndpoint.port)"
                : "Shared on port \(runningEndpoint.port)"
            return RoleServerStatusRow(
                role: role,
                assignedModel: assignedModel,
                endpoint: runningEndpoint,
                kind: kind,
                detail: detail
            )
        }
    }

    private static func makeUnassignedStatuses() -> [RoleServerStatusRow] {
        ProviderModelRole.orderedRoutingRoles.map(makeUnassignedStatus(for:))
    }

    private static func makeUnassignedStatus(for role: ProviderModelRole) -> RoleServerStatusRow {
        RoleServerStatusRow(
            role: role,
            assignedModel: nil,
            endpoint: nil,
            kind: .unassigned,
            detail: "No model assigned"
        )
    }
}
