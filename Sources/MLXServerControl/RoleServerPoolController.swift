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
    public var runtime: ModelRuntimeKind
    public var estimatedResidentMemoryGB: Double

    public init(
        modelID: String?,
        port: Int,
        baseURL: URL,
        runtime: ModelRuntimeKind = .mlxLM,
        estimatedResidentMemoryGB: Double = 0
    ) {
        self.modelID = modelID
        self.port = port
        self.baseURL = baseURL
        self.runtime = runtime
        self.estimatedResidentMemoryGB = estimatedResidentMemoryGB
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
        public var runtime: ModelRuntimeKind
        public var estimatedResidentMemoryGB: Double

        public init(
            modelID: String?,
            port: Int,
            endpoint: RoleServerEndpoint,
            runtime: ModelRuntimeKind = .mlxLM,
            estimatedResidentMemoryGB: Double = 0
        ) {
            self.modelID = modelID
            self.port = port
            self.endpoint = endpoint
            self.runtime = runtime
            self.estimatedResidentMemoryGB = estimatedResidentMemoryGB
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

public final class RoleServerPoolController: ObservableObject, @unchecked Sendable {
    @Published public private(set) var state: ServerState
    @Published public private(set) var lastError: String?
    @Published public private(set) var roleStatuses: [RoleServerStatusRow]
    @Published public private(set) var defaultEndpoint: RoleServerEndpoint?
    @Published public private(set) var roleEndpoints: [ProviderModelRole: RoleServerEndpoint]
    @Published public private(set) var readyPorts: Set<Int>
    public let processLauncher: ProcessLaunching
    public let portChecker: ServerPortChecking
    public let argumentBuilder: ServerProcessController
    private let healthChecker: ServerHealthChecking
    public private(set) var processesByPort: [Int: ManagedProcess]
    public private(set) var plan: RoleServerPlan?

    public init(
        processLauncher: ProcessLaunching = FoundationProcessLauncher(),
        portChecker: ServerPortChecking = TCPServerPortChecker(),
        argumentBuilder: ServerProcessController = ServerProcessController(),
        healthChecker: ServerHealthChecking = MLXHealthClient()
    ) {
        self.state = .stopped
        self.lastError = nil
        self.roleStatuses = Self.makeUnassignedStatuses()
        self.defaultEndpoint = nil
        self.roleEndpoints = [:]
        self.readyPorts = []
        self.processLauncher = processLauncher
        self.portChecker = portChecker
        self.argumentBuilder = argumentBuilder
        self.healthChecker = healthChecker
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
        guard state != .running && state != .starting else { return }
        state = .starting
        lastError = nil
        readyPorts = []
        defaultEndpoint = nil
        roleEndpoints = [:]

        let nextPlan = Self.makePlan(settings: settings)
        plan = nextPlan
        roleStatuses = nextPlan.roleStatuses.map { row in
            guard row.kind == .planned else { return row }
            return RoleServerStatusRow(
                role: row.role,
                assignedModel: row.assignedModel,
                endpoint: row.endpoint,
                kind: .starting,
                detail: "Loading \(row.endpoint?.runtime.displayName ?? "runtime")"
            )
        }

        let defaultPort = nextPlan.defaultEndpoint.port
        guard portChecker.isPortAvailable(host: DashboardSettings.localMLXHost, port: defaultPort) else {
            let error = ServerProcessControllerError.portUnavailable(
                host: DashboardSettings.localMLXHost,
                port: defaultPort
            )
            resetRuntimeState()
            state = .failed
            lastError = error.localizedDescription
            throw error
        }

        var launched: [Int: ManagedProcess] = [:]
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
                    serverFlags: settings.serverFlags,
                    runtime: server.runtime
                )
                process.environment = ProcessInfo.processInfo.environment
                process.terminationHandler = { [weak self] status in
                    DispatchQueue.main.async {
                        self?.handleProcessTermination(port: server.port, status: status)
                    }
                }
                try process.launch()
                launched[server.port] = process
            }
        } catch {
            for process in launched.values where process.isRunning {
                process.terminate()
            }
            resetRuntimeState()
            state = .failed
            lastError = String(describing: error)
            throw error
        }

        processesByPort = launched
        if !unavailablePorts.isEmpty {
            let statuses = Self.makeRoleStatuses(
                plan: nextPlan,
                defaultEndpoint: nextPlan.defaultEndpoint,
                runningRoleEndpoints: [:],
                unavailablePorts: unavailablePorts,
                portsAreReady: false
            )
            applyResolvedRoleStatuses(statuses)
        }
    }

    @discardableResult
    public func waitUntilReady(
        timeout: TimeInterval = 180,
        pollInterval: TimeInterval = 0.5
    ) async -> Bool {
        guard let currentPlan = plan else { return false }
        let processSnapshot = processesByPort
        var healthyPorts: Set<Int> = []
        for server in currentPlan.servers where processSnapshot[server.port]?.isRunning == true {
            let healthy = await healthChecker.waitUntilHealthy(
                baseURL: server.endpoint.baseURL,
                timeout: timeout,
                pollInterval: pollInterval
            )
            if healthy {
                healthyPorts.insert(server.port)
            }
        }

        let defaultReady = healthyPorts.contains(currentPlan.defaultEndpoint.port)
        await MainActor.run {
            readyPorts = healthyPorts
            if !defaultReady {
                for process in processesByPort.values where process.isRunning {
                    process.terminate()
                }
                processesByPort = [:]
                defaultEndpoint = nil
                roleEndpoints = [:]
                state = .failed
                lastError = "The default model runtime did not become healthy within \(Int(timeout)) seconds."
                roleStatuses = currentPlan.roleStatuses.map { row in
                    guard row.assignedModel != nil else { return row }
                    return RoleServerStatusRow(
                        role: row.role,
                        assignedModel: row.assignedModel,
                        endpoint: nil,
                        kind: .failed,
                        detail: "Default runtime failed readiness check"
                    )
                }
                return
            }

            let failedPorts = Set(processesByPort.keys).subtracting(healthyPorts)
            for port in failedPorts {
                if let process = processesByPort.removeValue(forKey: port), process.isRunning {
                    process.terminate()
                }
            }
            defaultEndpoint = currentPlan.defaultEndpoint
            roleEndpoints = currentPlan.roleEndpoints.filter { healthyPorts.contains($0.value.port) }
            roleStatuses = Self.makeRoleStatuses(
                plan: currentPlan,
                defaultEndpoint: currentPlan.defaultEndpoint,
                runningRoleEndpoints: roleEndpoints,
                unavailablePorts: failedPorts,
                portsAreReady: true
            )
            state = .running
            lastError = nil
        }
        return defaultReady
    }

    public func stopAll() {
        state = .stopping
        for process in processesByPort.values where process.isRunning {
            process.terminate()
        }
        resetRuntimeState()
        state = .stopped
    }

    public func stop(role: ProviderModelRole) {
        guard let removedEndpoint = removeRuntimeEndpoint(for: role) else { return }
        let assignedModel = status(for: role).assignedModel
        let fallbackEndpoint = defaultEndpoint ?? plan?.defaultEndpoint ?? removedEndpoint
        var statuses = resolvedRoleStatuses(
            plan: plan,
            defaultEndpoint: fallbackEndpoint,
            runningRoleEndpoints: roleEndpoints
        )
        if let index = statuses.firstIndex(where: { $0.role == role }) {
            statuses[index] = Self.makeStoppedStatus(
                for: role,
                assignedModel: assignedModel,
                defaultEndpoint: defaultEndpoint
            )
        }
        applyResolvedRoleStatuses(statuses)
    }

    public func restart(
        role: ProviderModelRole,
        settings: DashboardSettings,
        pythonExecutable: URL
    ) throws {
        let nextPlan = Self.makePlan(settings: settings)
        let activeDefault = defaultEndpoint ?? nextPlan.defaultEndpoint
        plan = nextPlan
        lastError = nil

        guard let plannedEndpoint = nextPlan.endpoint(for: role),
              let assignedModel = nextPlan.status(for: role).assignedModel
        else {
            removeRuntimeEndpoint(for: role)
            roleStatuses = nextPlan.roleStatuses
            return
        }

        removeRuntimeEndpoint(for: role)
        if plannedEndpoint.port == activeDefault.port {
            roleEndpoints[role] = activeDefault
            roleStatuses = resolvedRoleStatuses(
                plan: nextPlan,
                defaultEndpoint: activeDefault,
                runningRoleEndpoints: roleEndpoints
            )
            return
        }
        if roleEndpoints.values.contains(where: { $0.port == plannedEndpoint.port }) {
            roleEndpoints[role] = plannedEndpoint
            roleStatuses = resolvedRoleStatuses(
                plan: nextPlan,
                defaultEndpoint: activeDefault,
                runningRoleEndpoints: roleEndpoints
            )
            return
        }
        guard portChecker.isPortAvailable(host: DashboardSettings.localMLXHost, port: plannedEndpoint.port) else {
            roleStatuses = resolvedRoleStatuses(
                plan: nextPlan,
                defaultEndpoint: activeDefault,
                runningRoleEndpoints: roleEndpoints,
                unavailablePorts: [plannedEndpoint.port]
            )
            return
        }

        let process = processLauncher.makeProcess()
        process.executableURL = pythonExecutable
        process.arguments = argumentBuilder.makeArguments(
            modelID: assignedModel,
            port: plannedEndpoint.port,
            serverFlags: settings.serverFlags,
            runtime: plannedEndpoint.runtime
        )
        process.environment = ProcessInfo.processInfo.environment
        process.terminationHandler = { [weak self] status in
            DispatchQueue.main.async {
                self?.handleProcessTermination(port: plannedEndpoint.port, status: status)
            }
        }
        do {
            try process.launch()
            processesByPort[plannedEndpoint.port] = process
            readyPorts.remove(plannedEndpoint.port)
            if let index = roleStatuses.firstIndex(where: { $0.role == role }) {
                roleStatuses[index] = RoleServerStatusRow(
                    role: role,
                    assignedModel: assignedModel,
                    endpoint: plannedEndpoint,
                    kind: .starting,
                    detail: "Loading \(plannedEndpoint.runtime.displayName)"
                )
            }
        } catch {
            lastError = String(describing: error)
            throw error
        }
    }

    @discardableResult
    public func waitUntilRoleReady(
        _ role: ProviderModelRole,
        timeout: TimeInterval = 180
    ) async -> Bool {
        guard let currentPlan = plan,
              let endpoint = currentPlan.endpoint(for: role),
              processesByPort[endpoint.port]?.isRunning == true
        else { return false }
        let healthy = await healthChecker.waitUntilHealthy(
            baseURL: endpoint.baseURL,
            timeout: timeout,
            pollInterval: 0.5
        )
        await MainActor.run {
            if healthy {
                readyPorts.insert(endpoint.port)
                roleEndpoints[role] = endpoint
            } else if let process = processesByPort.removeValue(forKey: endpoint.port), process.isRunning {
                process.terminate()
            }
            let fallback = defaultEndpoint ?? currentPlan.defaultEndpoint
            roleStatuses = Self.makeRoleStatuses(
                plan: currentPlan,
                defaultEndpoint: fallback,
                runningRoleEndpoints: roleEndpoints,
                unavailablePorts: healthy ? [] : [endpoint.port],
                portsAreReady: true
            )
        }
        return healthy
    }

    public static func makePlan(settings: DashboardSettings) -> RoleServerPlan {
        let defaultModelID = settings.activeModel.flatMap { $0.isEmpty ? nil : $0 }
        let defaultPort = settings.mlxPort
        let defaultConfiguration = defaultModelID.map {
            settings.runtimeConfiguration(modelID: $0)
        } ?? .mlxLM()
        let defaultMemory = ModelMemoryEstimator.estimatedResidentMemoryGB(
            modelID: defaultModelID,
            runtimeConfiguration: defaultConfiguration
        )
        let defaultEndpoint = makeEndpoint(
            modelID: defaultModelID,
            port: defaultPort,
            configuration: defaultConfiguration,
            estimatedMemoryGB: defaultMemory
        )

        var modelPorts: [String: Int] = [:]
        var servers: [RoleServerPlan.Server] = [
            RoleServerPlan.Server(
                modelID: defaultModelID,
                port: defaultPort,
                endpoint: defaultEndpoint,
                runtime: defaultConfiguration.runtime,
                estimatedResidentMemoryGB: defaultMemory
            )
        ]
        if let defaultModelID {
            modelPorts[defaultModelID] = defaultPort
        }
        var plannedMemory = defaultMemory
        var nextPort = defaultPort + 1
        var roleEndpoints: [ProviderModelRole: RoleServerEndpoint] = [:]
        var roleStatuses: [RoleServerStatusRow] = []

        for role in ProviderModelRole.orderedRoutingRoles {
            guard let assignedModel = settings.providerRoleAssignments.model(for: role),
                  !assignedModel.isEmpty
            else {
                roleStatuses.append(makeUnassignedStatus(for: role))
                continue
            }

            if let existingPort = modelPorts[assignedModel] {
                let endpoint = servers.first(where: { $0.port == existingPort })?.endpoint
                    ?? defaultEndpoint
                roleEndpoints[role] = endpoint
                roleStatuses.append(
                    RoleServerStatusRow(
                        role: role,
                        assignedModel: assignedModel,
                        endpoint: endpoint,
                        kind: .planned,
                        detail: "Shared \(endpoint.runtime.displayName), estimated \(endpoint.estimatedResidentMemoryGB) GB"
                    )
                )
                continue
            }

            let configuration = settings.runtimeConfiguration(modelID: assignedModel)
            let estimatedMemory = ModelMemoryEstimator.estimatedResidentMemoryGB(
                modelID: assignedModel,
                runtimeConfiguration: configuration
            )
            let processLimitReached = servers.count >= settings.maxResidentModelProcesses
            let memoryLimitReached = plannedMemory + estimatedMemory > settings.residentModelMemoryBudgetGB
            if processLimitReached || memoryLimitReached {
                let reason = processLimitReached
                    ? "resident process limit \(settings.maxResidentModelProcesses) reached"
                    : "memory budget \(settings.residentModelMemoryBudgetGB) GB would be exceeded"
                roleStatuses.append(
                    RoleServerStatusRow(
                        role: role,
                        assignedModel: assignedModel,
                        endpoint: defaultModelID == nil ? nil : defaultEndpoint,
                        kind: defaultModelID == nil ? .failed : .fallback,
                        detail: "Deferred: \(reason); estimated \(estimatedMemory) GB"
                    )
                )
                continue
            }

            let port = nextPort
            nextPort += 1
            let endpoint = makeEndpoint(
                modelID: assignedModel,
                port: port,
                configuration: configuration,
                estimatedMemoryGB: estimatedMemory
            )
            modelPorts[assignedModel] = port
            plannedMemory += estimatedMemory
            servers.append(
                RoleServerPlan.Server(
                    modelID: assignedModel,
                    port: port,
                    endpoint: endpoint,
                    runtime: configuration.runtime,
                    estimatedResidentMemoryGB: estimatedMemory
                )
            )
            roleEndpoints[role] = endpoint
            roleStatuses.append(
                RoleServerStatusRow(
                    role: role,
                    assignedModel: assignedModel,
                    endpoint: endpoint,
                    kind: .planned,
                    detail: "\(configuration.runtime.displayName), estimated \(estimatedMemory) GB"
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

    private static func makeEndpoint(
        modelID: String?,
        port: Int,
        configuration: ModelRuntimeConfiguration,
        estimatedMemoryGB: Double
    ) -> RoleServerEndpoint {
        RoleServerEndpoint(
            modelID: modelID,
            port: port,
            baseURL: URL(string: "http://\(DashboardSettings.localMLXHost):\(port)")!,
            runtime: configuration.runtime,
            estimatedResidentMemoryGB: estimatedMemoryGB
        )
    }

    private static func makeRoleStatuses(
        plan: RoleServerPlan,
        defaultEndpoint: RoleServerEndpoint,
        runningRoleEndpoints: [ProviderModelRole: RoleServerEndpoint],
        unavailablePorts: Set<Int>,
        portsAreReady: Bool = true
    ) -> [RoleServerStatusRow] {
        var firstOwnedRoleByPort: Set<Int> = []
        return ProviderModelRole.orderedRoutingRoles.map { role in
            let planned = plan.status(for: role)
            guard let assignedModel = planned.assignedModel else {
                return makeUnassignedStatus(for: role)
            }
            if planned.kind == .fallback || planned.kind == .failed {
                return planned
            }
            let plannedEndpoint = plan.endpoint(for: role) ?? planned.endpoint ?? defaultEndpoint
            guard let runningEndpoint = runningRoleEndpoints[role] else {
                if unavailablePorts.contains(plannedEndpoint.port) {
                    let fallbackAvailable = defaultEndpoint.modelID != nil
                    return RoleServerStatusRow(
                        role: role,
                        assignedModel: assignedModel,
                        endpoint: fallbackAvailable ? defaultEndpoint : nil,
                        kind: fallbackAvailable ? .fallback : .failed,
                        detail: fallbackAvailable
                            ? "Port \(plannedEndpoint.port) unavailable; using active model"
                            : "Port \(plannedEndpoint.port) unavailable; no active model fallback"
                    )
                }
                if !portsAreReady && !unavailablePorts.contains(plannedEndpoint.port) {
                    return RoleServerStatusRow(
                        role: role,
                        assignedModel: assignedModel,
                        endpoint: plannedEndpoint,
                        kind: .starting,
                        detail: "Loading \(plannedEndpoint.runtime.displayName)"
                    )
                }
                let fallbackAvailable = defaultEndpoint.modelID != nil
                return RoleServerStatusRow(
                    role: role,
                    assignedModel: assignedModel,
                    endpoint: fallbackAvailable ? defaultEndpoint : nil,
                    kind: fallbackAvailable ? .fallback : .failed,
                    detail: fallbackAvailable
                        ? "Role runtime unavailable; using active model"
                        : "Role runtime unavailable; no active model fallback"
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
            let kind: RoleServerStatusKind = firstOwnedRoleByPort.insert(runningEndpoint.port).inserted
                ? .running
                : .shared
            return RoleServerStatusRow(
                role: role,
                assignedModel: assignedModel,
                endpoint: runningEndpoint,
                kind: kind,
                detail: "\(kind == .running ? "Running" : "Shared") on port \(runningEndpoint.port)"
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

    private static func makeStoppedStatus(
        for role: ProviderModelRole,
        assignedModel: String?,
        defaultEndpoint: RoleServerEndpoint?
    ) -> RoleServerStatusRow {
        let hasFallback = defaultEndpoint?.modelID != nil
        return RoleServerStatusRow(
            role: role,
            assignedModel: assignedModel,
            endpoint: nil,
            kind: hasFallback ? .fallback : .failed,
            detail: hasFallback ? "Stopped; using active model" : "Stopped; no active model fallback"
        )
    }

    @discardableResult
    private func removeRuntimeEndpoint(for role: ProviderModelRole) -> RoleServerEndpoint? {
        guard let endpoint = roleEndpoints.removeValue(forKey: role) else { return nil }
        readyPorts.remove(endpoint.port)
        if endpoint.port != defaultEndpoint?.port,
           !roleEndpoints.values.contains(where: { $0.port == endpoint.port }) {
            if let process = processesByPort.removeValue(forKey: endpoint.port), process.isRunning {
                process.terminate()
            }
        }
        return endpoint
    }

    private func resolvedRoleStatuses(
        plan: RoleServerPlan?,
        defaultEndpoint: RoleServerEndpoint,
        runningRoleEndpoints: [ProviderModelRole: RoleServerEndpoint],
        unavailablePorts: Set<Int> = []
    ) -> [RoleServerStatusRow] {
        guard let plan else { return Self.makeUnassignedStatuses() }
        return Self.makeRoleStatuses(
            plan: plan,
            defaultEndpoint: defaultEndpoint,
            runningRoleEndpoints: runningRoleEndpoints,
            unavailablePorts: unavailablePorts
        )
    }

    private func applyResolvedRoleStatuses(_ statuses: [RoleServerStatusRow]) {
        roleStatuses = statuses
        guard var currentPlan = plan else { return }
        currentPlan.roleStatuses = statuses
        plan = currentPlan
    }

    private func handleProcessTermination(port: Int, status: Int32) {
        processesByPort.removeValue(forKey: port)
        readyPorts.remove(port)
        guard state != .stopping && state != .stopped else { return }
        if defaultEndpoint?.port == port || plan?.defaultEndpoint.port == port {
            defaultEndpoint = nil
            roleEndpoints = [:]
            state = .failed
            lastError = "Default model runtime exited with status \(status)."
            return
        }
        roleEndpoints = roleEndpoints.filter { $0.value.port != port }
        if let plan, let fallback = defaultEndpoint {
            roleStatuses = Self.makeRoleStatuses(
                plan: plan,
                defaultEndpoint: fallback,
                runningRoleEndpoints: roleEndpoints,
                unavailablePorts: [port]
            )
        }
        lastError = status == 0 ? nil : "Role model runtime on port \(port) exited with status \(status)."
    }

    private func resetRuntimeState() {
        processesByPort = [:]
        plan = nil
        defaultEndpoint = nil
        roleEndpoints = [:]
        readyPorts = []
        roleStatuses = Self.makeUnassignedStatuses()
    }
}
