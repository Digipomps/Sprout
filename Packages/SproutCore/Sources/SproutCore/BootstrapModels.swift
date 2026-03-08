import Foundation
import SproutBridge
import SproutCrypto
import SproutEconomics
import SproutResolverAdapter

public enum SproutRuntimeProfile: String, Codable, Sendable {
    case cliService
    case iOSApp
    case macOSApp
    case onPremService
}

public enum SproutBootstrapState: String, Codable, CaseIterable, Sendable {
    case idle = "Idle"
    case loadContext = "LoadContext"
    case acquireIdentity = "AcquireIdentity"
    case collectPurposeInterest = "CollectPurposeInterest"
    case probeEnvironment = "ProbeEnvironment"
    case discoverBridges = "DiscoverBridges"
    case establishBridge = "EstablishBridge"
    case registerWithResolver = "RegisterWithResolver"
    case resolveEntity = "ResolveEntity"
    case membershipChecks = "MembershipChecks"
    case issuePortholeAccess = "IssuePortholeAccess"
    case persistBootstrap = "PersistBootstrap"
    case done = "Done"
    case error = "Error"
}

public struct BootstrapPurposeGoal: Codable, Equatable, Sendable {
    public var purpose: String
    public var goal: String
    public var interests: [String]

    public init(purpose: String, goal: String, interests: [String]) {
        self.purpose = purpose
        self.goal = goal
        self.interests = interests
    }

    public var isExplicitlySet: Bool {
        !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !interests.isEmpty
    }
}

public struct BootstrapIdentity: Codable, Equatable, Sendable {
    public var domain: String
    public var identity_public_key: String

    public init(domain: String, identity_public_key: String) {
        self.domain = domain
        self.identity_public_key = identity_public_key
    }
}

public enum EntityLinkEvidenceKind: String, Codable, Equatable, Sendable {
    case mutualLinkContract = "mutual_link_contract"
}

public struct EntityLinkEvidence: Codable, Equatable, Sendable {
    public var evidence_kind: EntityLinkEvidenceKind
    public var contract: EntityLinkContract
    public var note: String?

    public init(evidence_kind: EntityLinkEvidenceKind, contract: EntityLinkContract, note: String? = nil) {
        self.evidence_kind = evidence_kind
        self.contract = contract
        self.note = note
    }

    public func verify() throws -> Bool {
        switch evidence_kind {
        case .mutualLinkContract:
            return try contract.verifyMutualSignatures()
        }
    }

    public func contains(identityPublicKey: String) -> Bool {
        contract.pubkey_a == identityPublicKey || contract.pubkey_b == identityPublicKey
    }

    public func resolverSummary() throws -> EntityEvidenceSummary {
        let payloadHash = Hashing.sha256Base64URL(try contract.canonicalPayloadData())
        return EntityEvidenceSummary(
            evidence_type: evidence_kind.rawValue,
            contract_id: contract.contract_id,
            linked_public_keys: [contract.pubkey_a, contract.pubkey_b].sorted(),
            evidence_description: note ?? "mutual signatures over entity-link contract",
            evidence_sha256_b64url: payloadHash
        )
    }
}

public struct BootstrapEnvironmentReport: Codable, Equatable, Sendable {
    public var discovery_modes: [String]
    public var available_transports: [String]

    public init(discovery_modes: [String], available_transports: [String]) {
        self.discovery_modes = discovery_modes
        self.available_transports = available_transports
    }
}

public struct BootstrapEconomicsContext: Codable, Equatable, Sendable {
    public var declared_deposit_rau: Int64?
    public var pricing_contract: CloudBridgePricingContract?

    public init(
        declared_deposit_rau: Int64? = nil,
        pricing_contract: CloudBridgePricingContract? = nil
    ) {
        self.declared_deposit_rau = declared_deposit_rau
        self.pricing_contract = pricing_contract
    }
}

public struct BootstrapExecutionContext: Codable, Equatable, Sendable {
    public var runtime: SproutRuntimeProfile
    public var domain: String
    public var requestedPortholeKind: PortholeClientKind
    public var purposeGoal: BootstrapPurposeGoal?
    public var starterAuthPayload: StarterAuthPayload?
    public var identity: BootstrapIdentity?
    public var entityLinkEvidence: EntityLinkEvidence?
    public var entityResolution: EntityResolutionDecision?
    public var environmentReport: BootstrapEnvironmentReport?
    public var economics: BootstrapEconomicsContext?
    public var discoveredBridges: [BridgeDescriptor]
    public var selectedBridge: BridgeDescriptor?
    public var scaffoldAdminIdentity: ScaffoldAdminIdentity?
    public var registrationResult: ResolverRegistrationResult?
    public var capabilityDecision: CapabilityDecision?
    public var membershipDecision: MembershipDecision?
    public var portholeAccessContract: PortholeAccessContract?

    public init(
        runtime: SproutRuntimeProfile,
        domain: String,
        requestedPortholeKind: PortholeClientKind = .cli,
        purposeGoal: BootstrapPurposeGoal? = nil,
        starterAuthPayload: StarterAuthPayload? = nil,
        identity: BootstrapIdentity? = nil,
        entityLinkEvidence: EntityLinkEvidence? = nil,
        entityResolution: EntityResolutionDecision? = nil,
        environmentReport: BootstrapEnvironmentReport? = nil,
        economics: BootstrapEconomicsContext? = nil,
        discoveredBridges: [BridgeDescriptor] = [],
        selectedBridge: BridgeDescriptor? = nil,
        scaffoldAdminIdentity: ScaffoldAdminIdentity? = nil,
        registrationResult: ResolverRegistrationResult? = nil,
        capabilityDecision: CapabilityDecision? = nil,
        membershipDecision: MembershipDecision? = nil,
        portholeAccessContract: PortholeAccessContract? = nil
    ) {
        self.runtime = runtime
        self.domain = domain
        self.requestedPortholeKind = requestedPortholeKind
        self.purposeGoal = purposeGoal
        self.starterAuthPayload = starterAuthPayload
        self.identity = identity
        self.entityLinkEvidence = entityLinkEvidence
        self.entityResolution = entityResolution
        self.environmentReport = environmentReport
        self.economics = economics
        self.discoveredBridges = discoveredBridges
        self.selectedBridge = selectedBridge
        self.scaffoldAdminIdentity = scaffoldAdminIdentity
        self.registrationResult = registrationResult
        self.capabilityDecision = capabilityDecision
        self.membershipDecision = membershipDecision
        self.portholeAccessContract = portholeAccessContract
    }
}

public struct BootstrapTransitionEvent: Codable, Equatable, Sendable {
    public var index: Int
    public var timestamp: Date
    public var from: SproutBootstrapState
    public var to: SproutBootstrapState
    public var detail: String

    public init(index: Int, timestamp: Date, from: SproutBootstrapState, to: SproutBootstrapState, detail: String) {
        self.index = index
        self.timestamp = timestamp
        self.from = from
        self.to = to
        self.detail = detail
    }
}

public enum BootstrapError: Error, Equatable, Sendable {
    case invalidContext(String)
    case missingPurposeGoal
    case missingPurposeInterest
    case missingIdentity
    case wrongDomain(expected: String, got: String)
    case missingBridgeRoute
    case capabilityDenied([String])
    case membershipDenied(String)
    case resolverRejected(String)
    case invalidStarterAuthSignature
    case invalidEntityLinkEvidence(String)
    case invalidEntityInclusionProof(String)
    case expiredStarterAuthPayload
    case entityUnresolved(String)
    case missingScaffoldAdminIdentity
    case portholeAccessDenied(String)
    case invalidPortholeAccessContract(String)
    case networkCallWithoutPurposeGoal
    case invalidStateTransition(String)
    case persistenceFailure(String)
    case underlying(String)
}

public struct BootstrapRunResult: Sendable {
    public var finalState: SproutBootstrapState
    public var context: BootstrapExecutionContext
    public var events: [BootstrapTransitionEvent]
    public var error: BootstrapError?

    public init(
        finalState: SproutBootstrapState,
        context: BootstrapExecutionContext,
        events: [BootstrapTransitionEvent],
        error: BootstrapError?
    ) {
        self.finalState = finalState
        self.context = context
        self.events = events
        self.error = error
    }
}

public struct SproutBootstrapDependencies: Sendable {
    public var identityProvider: @Sendable (BootstrapExecutionContext) async throws -> BootstrapIdentity
    public var entityEvidenceProvider: @Sendable (BootstrapExecutionContext) async throws -> EntityLinkEvidence?
    public var environmentProbe: @Sendable (BootstrapExecutionContext) async throws -> BootstrapEnvironmentReport
    public var bridgeDiscovery: @Sendable (BootstrapExecutionContext) async throws -> [BridgeDescriptor]
    public var scaffoldAdminIdentityProvider: @Sendable (BridgeDescriptor, BootstrapExecutionContext) async throws -> ScaffoldAdminIdentity
    public var bridgeConnector: @Sendable (BridgeDescriptor, BootstrapExecutionContext) async throws -> Void
    public var resolver: any SproutResolverAdapter
    public var persistence: @Sendable (BootstrapExecutionContext) async throws -> Void

    public init(
        identityProvider: @escaping @Sendable (BootstrapExecutionContext) async throws -> BootstrapIdentity,
        entityEvidenceProvider: @escaping @Sendable (BootstrapExecutionContext) async throws -> EntityLinkEvidence?,
        environmentProbe: @escaping @Sendable (BootstrapExecutionContext) async throws -> BootstrapEnvironmentReport,
        bridgeDiscovery: @escaping @Sendable (BootstrapExecutionContext) async throws -> [BridgeDescriptor],
        scaffoldAdminIdentityProvider: @escaping @Sendable (BridgeDescriptor, BootstrapExecutionContext) async throws -> ScaffoldAdminIdentity,
        bridgeConnector: @escaping @Sendable (BridgeDescriptor, BootstrapExecutionContext) async throws -> Void,
        resolver: any SproutResolverAdapter,
        persistence: @escaping @Sendable (BootstrapExecutionContext) async throws -> Void
    ) {
        self.identityProvider = identityProvider
        self.entityEvidenceProvider = entityEvidenceProvider
        self.environmentProbe = environmentProbe
        self.bridgeDiscovery = bridgeDiscovery
        self.scaffoldAdminIdentityProvider = scaffoldAdminIdentityProvider
        self.bridgeConnector = bridgeConnector
        self.resolver = resolver
        self.persistence = persistence
    }
}
