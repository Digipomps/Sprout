import Foundation
import SproutResolverAdapter

public enum BootstrapPlanningCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case localScaffoldTrustRootDescriptor = "local_scaffold_trust_root_descriptor"
    case scaffoldTrustRootHTTP = "scaffold_trust_root_http"
    case localStarterAuthPayload = "local_starter_auth_payload"
    case starterBootstrapIntentHTTP = "starter_bootstrap_intent_http"
    case offlineBridgeCatalog = "offline_bridge_catalog"
    case signedBridgeDiscoveryHTTP = "signed_bridge_discovery_http"
    case liveResolverHTTP = "live_resolver_http"
    case entityAnchorSnapshot = "entity_anchor_snapshot"
    case mockResolver = "mock_resolver"
    case remoteHostRouting = "remote_host_routing"
    case portholeAttachment = "porthole_attachment"
}

public enum BridgeDiscoveryPreference: String, Codable, Sendable {
    case auto
    case offlineCatalog = "offline_catalog"
    case remoteHTTP = "remote_http"
}

public enum EntityResolutionPreference: String, Codable, Sendable {
    case auto
    case liveHTTP = "live_http"
    case entityAnchorSnapshot = "entity_anchor_snapshot"
    case mock
}

public struct BootstrapPlanningEnvironment: Codable, Equatable, Sendable {
    public var runtime: SproutRuntimeProfile
    public var availableCapabilities: Set<BootstrapPlanningCapability>

    public init(
        runtime: SproutRuntimeProfile,
        availableCapabilities: Set<BootstrapPlanningCapability>
    ) {
        self.runtime = runtime
        self.availableCapabilities = availableCapabilities
    }
}

public struct BootstrapPlanningRequest: Codable, Equatable, Sendable {
    public var purposeGoal: BootstrapPurposeGoal?
    public var requestedPortholeKind: PortholeClientKind
    public var discoveryPreference: BridgeDiscoveryPreference
    public var entityResolutionPreference: EntityResolutionPreference

    public init(
        purposeGoal: BootstrapPurposeGoal?,
        requestedPortholeKind: PortholeClientKind,
        discoveryPreference: BridgeDiscoveryPreference = .auto,
        entityResolutionPreference: EntityResolutionPreference = .auto
    ) {
        self.purposeGoal = purposeGoal
        self.requestedPortholeKind = requestedPortholeKind
        self.discoveryPreference = discoveryPreference
        self.entityResolutionPreference = entityResolutionPreference
    }
}

public enum BootstrapPlanActionID: String, Codable, Sendable {
    case validateExplicitPurposeGoal = "validate-explicit-purpose-goal"
    case loadScaffoldTrustRootDescriptor = "load-scaffold-trust-root-descriptor"
    case fetchScaffoldTrustRootDescriptor = "fetch-scaffold-trust-root-descriptor"
    case missingScaffoldTrustRootDescriptor = "missing-scaffold-trust-root-descriptor"
    case loadStarterAuthPayload = "load-starter-auth-payload"
    case requestStarterBootstrapIntent = "request-starter-bootstrap-intent"
    case manualStarterBootstrap = "manual-starter-bootstrap"
    case loadOfflineBridgeCatalog = "load-offline-bridge-catalog"
    case discoverBridgeViaHTTP = "discover-bridge-via-http"
    case missingBridgeDiscovery = "missing-bridge-discovery"
    case resolveEntityViaLiveResolver = "resolve-entity-via-live-resolver"
    case resolveEntityViaSnapshot = "resolve-entity-via-snapshot"
    case resolveEntityViaMock = "resolve-entity-via-mock"
    case missingEntityResolution = "missing-entity-resolution"
    case configureRemoteHostRouting = "configure-remote-host-routing"
    case attachPorthole = "attach-porthole"
}

public struct BootstrapPlanAction: Codable, Equatable, Sendable {
    public var id: BootstrapPlanActionID
    public var description: String
    public var blocking: Bool

    public init(id: BootstrapPlanActionID, description: String, blocking: Bool) {
        self.id = id
        self.description = description
        self.blocking = blocking
    }
}

public struct BootstrapPlan: Codable, Equatable, Sendable {
    public var runtime: SproutRuntimeProfile
    public var requestedPortholeKind: PortholeClientKind
    public var actions: [BootstrapPlanAction]
    public var missingCapabilities: Set<BootstrapPlanningCapability>

    public init(
        runtime: SproutRuntimeProfile,
        requestedPortholeKind: PortholeClientKind,
        actions: [BootstrapPlanAction],
        missingCapabilities: Set<BootstrapPlanningCapability>
    ) {
        self.runtime = runtime
        self.requestedPortholeKind = requestedPortholeKind
        self.actions = actions
        self.missingCapabilities = missingCapabilities
    }

    public var readyForFirstConnection: Bool {
        !actions.contains(where: \.blocking)
    }
}

public struct BootstrapPlanner: Sendable {
    public init() {}

    public func plan(
        environment: BootstrapPlanningEnvironment,
        request: BootstrapPlanningRequest
    ) -> BootstrapPlan {
        var actions = [BootstrapPlanAction]()
        var missingCapabilities = Set<BootstrapPlanningCapability>()

        actions.append(validatePurposeGoal(request.purposeGoal))
        actions.append(scaffoldTrustRootAction(environment: environment, missingCapabilities: &missingCapabilities))
        actions.append(starterBootstrapAction(environment: environment, missingCapabilities: &missingCapabilities))
        actions.append(discoveryAction(environment: environment, request: request, missingCapabilities: &missingCapabilities))
        actions.append(entityResolutionAction(environment: environment, request: request, missingCapabilities: &missingCapabilities))
        actions.append(routeConfigurationAction(environment: environment, missingCapabilities: &missingCapabilities))
        actions.append(portholeAction(environment: environment, missingCapabilities: &missingCapabilities))

        return BootstrapPlan(
            runtime: environment.runtime,
            requestedPortholeKind: request.requestedPortholeKind,
            actions: actions,
            missingCapabilities: missingCapabilities
        )
    }

    private func scaffoldTrustRootAction(
        environment: BootstrapPlanningEnvironment,
        missingCapabilities: inout Set<BootstrapPlanningCapability>
    ) -> BootstrapPlanAction {
        if environment.availableCapabilities.contains(.localScaffoldTrustRootDescriptor) {
            return BootstrapPlanAction(
                id: .loadScaffoldTrustRootDescriptor,
                description: "Load the local scaffold-admin trust-root descriptor before bootstrap.",
                blocking: false
            )
        }

        if environment.availableCapabilities.contains(.scaffoldTrustRootHTTP) {
            return BootstrapPlanAction(
                id: .fetchScaffoldTrustRootDescriptor,
                description: "Fetch the scaffold-admin trust-root descriptor from the scaffold's well-known endpoint.",
                blocking: false
            )
        }

        missingCapabilities.formUnion([.localScaffoldTrustRootDescriptor, .scaffoldTrustRootHTTP])
        return BootstrapPlanAction(
            id: .missingScaffoldTrustRootDescriptor,
            description: "No explicit scaffold-admin trust-root descriptor is available. Legacy bootstrap can continue, but trust is reduced.",
            blocking: false
        )
    }

    private func validatePurposeGoal(_ purposeGoal: BootstrapPurposeGoal?) -> BootstrapPlanAction {
        guard let purposeGoal, purposeGoal.isExplicitlySet else {
            return BootstrapPlanAction(
                id: .validateExplicitPurposeGoal,
                description: "Purpose, goal, and interests must be set explicitly before bootstrap.",
                blocking: true
            )
        }

        return BootstrapPlanAction(
            id: .validateExplicitPurposeGoal,
            description: "Purpose, goal, and interests are explicit and can be forwarded during bootstrap.",
            blocking: false
        )
    }

    private func starterBootstrapAction(
        environment: BootstrapPlanningEnvironment,
        missingCapabilities: inout Set<BootstrapPlanningCapability>
    ) -> BootstrapPlanAction {
        if environment.availableCapabilities.contains(.localStarterAuthPayload) {
            return BootstrapPlanAction(
                id: .loadStarterAuthPayload,
                description: "Load starter auth payload from the local bootstrap context before contacting the scaffold.",
                blocking: false
            )
        }

        if environment.availableCapabilities.contains(.starterBootstrapIntentHTTP) {
            return BootstrapPlanAction(
                id: .requestStarterBootstrapIntent,
                description: "Fetch a signed starter bootstrap intent from the scaffold and materialize a local starter auth payload.",
                blocking: false
            )
        }

        missingCapabilities.formUnion([.localStarterAuthPayload, .starterBootstrapIntentHTTP])
        return BootstrapPlanAction(
            id: .manualStarterBootstrap,
            description: "No local starter auth payload is available. Provide one explicitly before bootstrap.",
            blocking: true
        )
    }

    private func discoveryAction(
        environment: BootstrapPlanningEnvironment,
        request: BootstrapPlanningRequest,
        missingCapabilities: inout Set<BootstrapPlanningCapability>
    ) -> BootstrapPlanAction {
        switch request.discoveryPreference {
        case .offlineCatalog:
            if environment.availableCapabilities.contains(.offlineBridgeCatalog) {
                return BootstrapPlanAction(
                    id: .loadOfflineBridgeCatalog,
                    description: "Load a signed bridge descriptor from the local offline catalog.",
                    blocking: false
                )
            }
            missingCapabilities.insert(.offlineBridgeCatalog)
            return BootstrapPlanAction(
                id: .missingBridgeDiscovery,
                description: "Offline bridge discovery was requested, but no local signed bridge catalog is available.",
                blocking: true
            )
        case .remoteHTTP:
            if environment.availableCapabilities.contains(.signedBridgeDiscoveryHTTP) {
                return BootstrapPlanAction(
                    id: .discoverBridgeViaHTTP,
                    description: "Query the scaffold's signed HTTP bridge discovery endpoint.",
                    blocking: false
                )
            }
            missingCapabilities.insert(.signedBridgeDiscoveryHTTP)
            return BootstrapPlanAction(
                id: .missingBridgeDiscovery,
                description: "Remote HTTP bridge discovery was requested, but no signed HTTP discovery path is available.",
                blocking: true
            )
        case .auto:
            if environment.availableCapabilities.contains(.offlineBridgeCatalog) {
                return BootstrapPlanAction(
                    id: .loadOfflineBridgeCatalog,
                    description: "Use the local signed bridge catalog first.",
                    blocking: false
                )
            }
            if environment.availableCapabilities.contains(.signedBridgeDiscoveryHTTP) {
                return BootstrapPlanAction(
                    id: .discoverBridgeViaHTTP,
                    description: "Use the scaffold's signed HTTP bridge discovery endpoint.",
                    blocking: false
                )
            }
            missingCapabilities.formUnion([.offlineBridgeCatalog, .signedBridgeDiscoveryHTTP])
            return BootstrapPlanAction(
                id: .missingBridgeDiscovery,
                description: "No bridge discovery path is available.",
                blocking: true
            )
        }
    }

    private func entityResolutionAction(
        environment: BootstrapPlanningEnvironment,
        request: BootstrapPlanningRequest,
        missingCapabilities: inout Set<BootstrapPlanningCapability>
    ) -> BootstrapPlanAction {
        switch request.entityResolutionPreference {
        case .liveHTTP:
            if environment.availableCapabilities.contains(.liveResolverHTTP) {
                return BootstrapPlanAction(
                    id: .resolveEntityViaLiveResolver,
                    description: "Resolve entity membership against the live scaffold resolver.",
                    blocking: false
                )
            }
            missingCapabilities.insert(.liveResolverHTTP)
            return BootstrapPlanAction(
                id: .missingEntityResolution,
                description: "Live entity resolution was requested, but no live resolver endpoint is configured.",
                blocking: true
            )
        case .entityAnchorSnapshot:
            if environment.availableCapabilities.contains(.entityAnchorSnapshot) {
                return BootstrapPlanAction(
                    id: .resolveEntityViaSnapshot,
                    description: "Resolve entity membership from the signed local entity anchor snapshot.",
                    blocking: false
                )
            }
            missingCapabilities.insert(.entityAnchorSnapshot)
            return BootstrapPlanAction(
                id: .missingEntityResolution,
                description: "Entity anchor snapshot resolution was requested, but no snapshot is available.",
                blocking: true
            )
        case .mock:
            if environment.availableCapabilities.contains(.mockResolver) {
                return BootstrapPlanAction(
                    id: .resolveEntityViaMock,
                    description: "Use mock entity resolution for controlled bootstrap testing or a locally supplied admission contract.",
                    blocking: false
                )
            }
            missingCapabilities.insert(.mockResolver)
            return BootstrapPlanAction(
                id: .missingEntityResolution,
                description: "Mock entity resolution was requested, but no mock resolver configuration is present.",
                blocking: true
            )
        case .auto:
            if environment.availableCapabilities.contains(.liveResolverHTTP) {
                return BootstrapPlanAction(
                    id: .resolveEntityViaLiveResolver,
                    description: "Use the live scaffold resolver for entity resolution.",
                    blocking: false
                )
            }
            if environment.availableCapabilities.contains(.entityAnchorSnapshot) {
                return BootstrapPlanAction(
                    id: .resolveEntityViaSnapshot,
                    description: "Use the signed local entity anchor snapshot for entity resolution.",
                    blocking: false
                )
            }
            if environment.availableCapabilities.contains(.mockResolver) {
                return BootstrapPlanAction(
                    id: .resolveEntityViaMock,
                    description: "Fallback to mock entity resolution for bootstrap testing or a locally supplied admission contract.",
                    blocking: false
                )
            }
            missingCapabilities.formUnion([.liveResolverHTTP, .entityAnchorSnapshot, .mockResolver])
            return BootstrapPlanAction(
                id: .missingEntityResolution,
                description: "No entity resolution path is available.",
                blocking: true
            )
        }
    }

    private func routeConfigurationAction(
        environment: BootstrapPlanningEnvironment,
        missingCapabilities: inout Set<BootstrapPlanningCapability>
    ) -> BootstrapPlanAction {
        if environment.availableCapabilities.contains(.remoteHostRouting) {
            return BootstrapPlanAction(
                id: .configureRemoteHostRouting,
                description: "Configure remote host routing for the selected bridge.",
                blocking: false
            )
        }

        missingCapabilities.insert(.remoteHostRouting)
        return BootstrapPlanAction(
            id: .configureRemoteHostRouting,
            description: "Remote host routing support is missing from this executable.",
            blocking: true
        )
    }

    private func portholeAction(
        environment: BootstrapPlanningEnvironment,
        missingCapabilities: inout Set<BootstrapPlanningCapability>
    ) -> BootstrapPlanAction {
        if environment.availableCapabilities.contains(.portholeAttachment) {
            return BootstrapPlanAction(
                id: .attachPorthole,
                description: "Request a porthole contract and prepare the requested handoff.",
                blocking: false
            )
        }

        missingCapabilities.insert(.portholeAttachment)
        return BootstrapPlanAction(
            id: .attachPorthole,
            description: "Porthole handoff support is missing from this executable.",
            blocking: true
        )
    }
}
