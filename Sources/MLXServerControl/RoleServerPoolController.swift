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
    public var modelID: String
    public var port: Int
    public var baseURL: URL

    public init(modelID: String, port: Int, baseURL: URL) {
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
        public var modelID: String
        public var port: Int
        public var endpoint: RoleServerEndpoint

        public init(modelID: String, port: Int, endpoint: RoleServerEndpoint) {
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
    public private(set) var processesByModelID: [String: ManagedProcess]
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
        self.processesByModelID = [:]
        self.plan = nil
    }

    public static func makePlan(settings: DashboardSettings) -> RoleServerPlan {
        let defaultModelID = normalizedModelID(settings.activeModel, fallback: "default")
        let defaultPort = settings.mlxPort
        let defaultEndpoint = makeEndpoint(modelID: defaultModelID, port: defaultPort)

        var modelPorts: [String: Int] = [defaultModelID: defaultPort]
        var servers: [RoleServerPlan.Server] = [
            RoleServerPlan.Server(
                modelID: defaultModelID,
                port: defaultPort,
                endpoint: defaultEndpoint
            )
        ]
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

    private static func normalizedModelID(_ modelID: String?, fallback: String) -> String {
        guard let modelID, !modelID.isEmpty else {
            return fallback
        }
        return modelID
    }

    private static func makeEndpoint(modelID: String, port: Int) -> RoleServerEndpoint {
        RoleServerEndpoint(
            modelID: modelID,
            port: port,
            baseURL: URL(string: "http://\(DashboardSettings.localMLXHost):\(port)")!
        )
    }
}
