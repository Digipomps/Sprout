import XCTest
import Foundation
@testable import SproutCore
import SproutBridge
import SproutResolverAdapter

final class BootstrapStateMachineTests: XCTestCase {
    private var rootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixedNow: Date {
        ISO8601DateFormatter().date(from: "2026-02-26T08:01:00Z")!
    }

    func testHappyPathIssuesSignedPortholeContract() async throws {
        let starter = try loadStarterPayload()
        let descriptor = try loadBridgeDescriptor()
        let resolvedEntityID = "entity_example_primary"

        let result = await runWith(
            starter: starter,
            bridgeDescriptors: [descriptor],
            resolverScenario: MockResolverScenario(
                allowedDomains: ["example.haven.local"],
                entityBindings: [starter.identity_public_key: resolvedEntityID],
                requireFreshPayload: false
            )
        )

        XCTAssertEqual(result.finalState, .done)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.last?.to, .done)
        XCTAssertEqual(result.context.entityResolution?.status, .resolved)
        XCTAssertEqual(result.context.entityResolution?.entity_id, resolvedEntityID)
        XCTAssertEqual(result.context.scaffoldAdminIdentity?.admin_public_key, descriptor.owner_pubkey)
        XCTAssertEqual(result.context.portholeAccessContract?.entity_id, resolvedEntityID)
        XCTAssertEqual(result.context.portholeAccessContract?.client_kind, .cli)
        XCTAssertEqual(result.context.portholeAccessContract?.porthole_protocol, .cli)
        XCTAssertTrue(try XCTUnwrap(result.context.portholeAccessContract).verifySignature())

        let replayed = try await machineForReplay(now: fixedNow).replay(events: result.events)
        XCTAssertEqual(replayed, .done)
    }

    func testNegativeSignatureFailure() async throws {
        var starter = try loadStarterPayload()
        starter.signature.sig = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

        let result = await runWith(
            starter: starter,
            bridgeDescriptors: [try loadBridgeDescriptor()],
            resolverScenario: MockResolverScenario(allowedDomains: ["example.haven.local"])
        )

        XCTAssertEqual(result.finalState, .error)
        XCTAssertEqual(result.error, .invalidStarterAuthSignature)
    }

    func testNegativeWrongDomain() async throws {
        var starter = try loadStarterPayload()
        starter.domain = "wrong.haven.local"

        let result = await runWith(
            starter: starter,
            bridgeDescriptors: [try loadBridgeDescriptor()],
            resolverScenario: MockResolverScenario(
                allowedDomains: ["example.haven.local"],
                requireFreshPayload: false
            )
        )

        XCTAssertEqual(result.finalState, .error)
        XCTAssertEqual(result.error, .wrongDomain(expected: "example.haven.local", got: "wrong.haven.local"))
    }

    func testNegativeExpiredPayload() async throws {
        let starter = try loadStarterPayload()

        let result = await runWith(
            starter: starter,
            bridgeDescriptors: [try loadBridgeDescriptor()],
            resolverScenario: MockResolverScenario(allowedDomains: ["example.haven.local"]),
            now: ISO8601DateFormatter().date(from: "2026-02-26T08:06:00Z")!
        )

        XCTAssertEqual(result.finalState, .error)
        XCTAssertEqual(result.error, .expiredStarterAuthPayload)
    }

    func testNegativeMissingBridgeRoute() async throws {
        let starter = try loadStarterPayload()

        let result = await runWith(
            starter: starter,
            bridgeDescriptors: [],
            resolverScenario: MockResolverScenario(allowedDomains: ["example.haven.local"])
        )

        XCTAssertEqual(result.finalState, .error)
        XCTAssertEqual(result.error, .missingBridgeRoute)
    }

    func testNegativeCapabilityDenial() async throws {
        let starter = try loadStarterPayload()

        let result = await runWith(
            starter: starter,
            bridgeDescriptors: [try loadBridgeDescriptor()],
            resolverScenario: MockResolverScenario(
                allowedDomains: ["example.haven.local"],
                deniedCapabilities: ["cap.join"],
                entityBindings: [starter.identity_public_key: "entity_example_primary"]
            )
        )

        XCTAssertEqual(result.finalState, .error)
        XCTAssertEqual(result.error, .capabilityDenied(["cap.join"]))
    }

    func testNegativeEntityUnresolved() async throws {
        let starter = try loadStarterPayload()

        let result = await runWith(
            starter: starter,
            bridgeDescriptors: [try loadBridgeDescriptor()],
            resolverScenario: MockResolverScenario(
                allowedDomains: ["example.haven.local"],
                requireFreshPayload: false
            )
        )

        XCTAssertEqual(result.finalState, .error)
        XCTAssertEqual(result.error, .entityUnresolved("no explicit entity binding found for identity"))
    }

    func testNegativeInvalidEntityLinkEvidence() async throws {
        let starter = try loadStarterPayload()
        var contract = try loadEntityLinkContract()
        contract.pubkey_a = "QwRr_kCSs-lJlOraFdzCDYqqB7ZY_TlU644O-4vcpd4"

        let result = await runWith(
            starter: starter,
            bridgeDescriptors: [try loadBridgeDescriptor()],
            resolverScenario: MockResolverScenario(
                allowedDomains: ["example.haven.local"],
                entityBindings: [starter.identity_public_key: "entity_example_primary"],
                requireFreshPayload: false
            ),
            entityLinkContract: contract
        )

        XCTAssertEqual(result.finalState, .error)
        XCTAssertEqual(result.error, .invalidEntityLinkEvidence("entity-link evidence does not include acquired identity"))
    }

    func testNegativeInvalidEntityInclusionProof() async throws {
        let starter = try loadStarterPayload()
        let nowDate = fixedNow
        let resolver = TamperedInclusionProofResolver(
            base: MockResolverAdapter(
                scenario: MockResolverScenario(
                    allowedDomains: ["example.haven.local"],
                    entityBindings: [starter.identity_public_key: "entity_example_primary"],
                    requireFreshPayload: false
                ),
                now: { nowDate }
            )
        )

        let result = await runWith(
            starter: starter,
            bridgeDescriptors: [try loadBridgeDescriptor()],
            resolverScenario: MockResolverScenario(
                allowedDomains: ["example.haven.local"],
                entityBindings: [starter.identity_public_key: "entity_example_primary"],
                requireFreshPayload: false
            ),
            resolver: resolver
        )

        XCTAssertEqual(result.finalState, .error)
        XCTAssertEqual(result.error, .invalidEntityInclusionProof("entity inclusion proof signature is invalid"))
    }

    func testCanIssueWebPortholeContract() async throws {
        let starter = try loadStarterPayload()

        let result = await runWith(
            starter: starter,
            bridgeDescriptors: [try loadBridgeDescriptor()],
            resolverScenario: MockResolverScenario(
                allowedDomains: ["example.haven.local"],
                entityBindings: [starter.identity_public_key: "entity_example_primary"],
                requireFreshPayload: false
            ),
            requestedPortholeKind: .web
        )

        XCTAssertEqual(result.finalState, .done)
        XCTAssertEqual(result.context.portholeAccessContract?.client_kind, .web)
        XCTAssertEqual(result.context.portholeAccessContract?.porthole_protocol, .web)
    }

    func testHappyPathWithEntityAnchorResolverIssuesInclusionProof() async throws {
        let starter = try loadStarterPayload()
        let descriptor = try ResolverFixtureFactory.makeSignedBridgeDescriptor()
        let snapshot = try ResolverFixtureFactory.makeSignedEntityAnchorSnapshot(
            identities: [
                EntityAnchorIdentityMember(
                    identity_public_key: starter.identity_public_key,
                    domain: starter.domain,
                    added_at: "2026-02-26T07:59:00Z"
                )
            ]
        )
        let nowDate = fixedNow

        let dependencies = SproutBootstrapDependencies(
            identityProvider: { context in
                guard let payload = context.starterAuthPayload else {
                    throw BootstrapError.invalidContext("missing starter payload")
                }
                return BootstrapIdentity(domain: payload.domain, identity_public_key: payload.identity_public_key)
            },
            entityEvidenceProvider: { _ in nil },
            environmentProbe: { _ in
                BootstrapEnvironmentReport(discovery_modes: ["offline-catalog"], available_transports: ["wss"])
            },
            bridgeDiscovery: { _ in [descriptor] },
            scaffoldAdminIdentityProvider: { descriptor, _ in
                ScaffoldAdminIdentity(
                    scaffold_domain: descriptor.scaffold_domain,
                    admin_public_key: descriptor.owner_pubkey,
                    source_descriptor_id: descriptor.descriptor_id,
                    trust_origin: "bridge_descriptor_signature"
                )
            },
            bridgeConnector: { _, _ in },
            resolver: EntityAnchorResolverAdapter(
                anchorSnapshot: snapshot,
                scenario: EntityAnchorResolverScenario(
                    allowedDomains: ["example.haven.local"],
                    requireFreshPayload: false
                ),
                now: { nowDate }
            ),
            persistence: { _ in }
        )

        let machine = SproutBootstrapStateMachine(dependencies: dependencies, now: { nowDate })
        let context = BootstrapExecutionContext(
            runtime: .cliService,
            domain: "example.haven.local",
            requestedPortholeKind: .cli,
            purposeGoal: BootstrapPurposeGoal(
                purpose: "bootstrap.join_scaffold",
                goal: "Join scaffold and register identity",
                interests: ["haven.core.bootstrap", "haven.core.bridge"]
            ),
            starterAuthPayload: starter
        )

        let result = await machine.run(initialContext: context)

        XCTAssertEqual(result.finalState, .done)
        XCTAssertEqual(result.context.entityResolution?.status, .resolved)
        XCTAssertEqual(result.context.entityResolution?.inclusion_proof?.anchor_snapshot_id, snapshot.snapshot_id)
        XCTAssertEqual(result.context.entityResolution?.inclusion_proof?.anchor_admin_public_key, snapshot.admin_public_key)
    }

    private func runWith(
        domain: String = "example.haven.local",
        starter: StarterAuthPayload,
        bridgeDescriptors: [BridgeDescriptor],
        resolverScenario: MockResolverScenario,
        now: Date? = nil,
        entityLinkContract: EntityLinkContract? = nil,
        requestedPortholeKind: PortholeClientKind = .cli,
        resolver: (any SproutResolverAdapter)? = nil
    ) async -> BootstrapRunResult {
        let adjustedScenario = MockResolverScenario(
            allowedDomains: resolverScenario.allowedDomains,
            deniedCapabilities: resolverScenario.deniedCapabilities,
            membershipDeniedDomains: resolverScenario.membershipDeniedDomains,
            entityBindings: resolverScenario.entityBindings,
            requireEntityEvidence: resolverScenario.requireEntityEvidence,
            allowedPortholeClientKinds: resolverScenario.allowedPortholeClientKinds,
            allowedPortholeProtocols: resolverScenario.allowedPortholeProtocols,
            requireValidSignature: resolverScenario.requireValidSignature,
            requireFreshPayload: false,
            resolverSigningSeedBase64URL: resolverScenario.resolverSigningSeedBase64URL
        )

        let nowDate = now ?? fixedNow
        let dependencies = SproutBootstrapDependencies(
            identityProvider: { context in
                guard let payload = context.starterAuthPayload else {
                    throw BootstrapError.invalidContext("missing starter payload")
                }
                return BootstrapIdentity(
                    domain: payload.domain,
                    identity_public_key: payload.identity_public_key
                )
            },
            entityEvidenceProvider: { _ in
                guard let entityLinkContract else {
                    return nil
                }
                return EntityLinkEvidence(
                    evidence_kind: .mutualLinkContract,
                    contract: entityLinkContract,
                    note: "loaded from test fixture"
                )
            },
            environmentProbe: { _ in
                BootstrapEnvironmentReport(discovery_modes: ["offline-catalog"], available_transports: ["wss"])
            },
            bridgeDiscovery: { _ in bridgeDescriptors },
            scaffoldAdminIdentityProvider: { descriptor, _ in
                ScaffoldAdminIdentity(
                    scaffold_domain: descriptor.scaffold_domain,
                    admin_public_key: descriptor.owner_pubkey,
                    source_descriptor_id: descriptor.descriptor_id,
                    trust_origin: "bridge_descriptor_signature"
                )
            },
            bridgeConnector: { _, _ in },
            resolver: resolver ?? MockResolverAdapter(scenario: adjustedScenario, now: { nowDate }),
            persistence: { _ in }
        )

        let machine = SproutBootstrapStateMachine(
            dependencies: dependencies,
            now: { nowDate }
        )

        let context = BootstrapExecutionContext(
            runtime: .cliService,
            domain: domain,
            requestedPortholeKind: requestedPortholeKind,
            purposeGoal: BootstrapPurposeGoal(
                purpose: "bootstrap.join_scaffold",
                goal: "Join scaffold and register identity",
                interests: ["haven.core.bootstrap", "haven.core.bridge"]
            ),
            starterAuthPayload: starter
        )

        return await machine.run(initialContext: context)
    }

    private func machineForReplay(now: Date) -> SproutBootstrapStateMachine {
        let dependencies = SproutBootstrapDependencies(
            identityProvider: { _ in BootstrapIdentity(domain: "example.haven.local", identity_public_key: "pubkey") },
            entityEvidenceProvider: { _ in nil },
            environmentProbe: { _ in BootstrapEnvironmentReport(discovery_modes: [], available_transports: []) },
            bridgeDiscovery: { _ in [] },
            scaffoldAdminIdentityProvider: { _, _ in
                ScaffoldAdminIdentity(
                    scaffold_domain: "example.haven.local",
                    admin_public_key: "admin",
                    source_descriptor_id: "descriptor",
                    trust_origin: "test"
                )
            },
            bridgeConnector: { _, _ in },
            resolver: MockResolverAdapter(scenario: .permissive, now: { now }),
            persistence: { _ in }
        )
        return SproutBootstrapStateMachine(dependencies: dependencies, now: { now })
    }

    private func loadStarterPayload() throws -> StarterAuthPayload {
        try JSONDecoder().decode(
            StarterAuthPayload.self,
            from: Data(contentsOf: rootURL.appendingPathComponent("TestVectors/starter_auth_payload.signed.json"))
        )
    }

    private func loadBridgeDescriptor() throws -> BridgeDescriptor {
        try JSONDecoder().decode(
            BridgeDescriptor.self,
            from: Data(contentsOf: rootURL.appendingPathComponent("TestVectors/bridge_descriptor.signed.json"))
        )
    }

    private func loadEntityLinkContract() throws -> EntityLinkContract {
        try JSONDecoder().decode(
            EntityLinkContract.self,
            from: Data(contentsOf: rootURL.appendingPathComponent("TestVectors/entity_link_contract.mutual.json"))
        )
    }
}

private actor TamperedInclusionProofResolver: SproutResolverAdapter {
    private let base: any SproutResolverAdapter

    init(base: any SproutResolverAdapter) {
        self.base = base
    }

    func registerStarterAuth(payload: StarterAuthPayload) async throws -> ResolverRegistrationResult {
        try await base.registerStarterAuth(payload: payload)
    }

    func requestCapabilities(_ request: CapabilityRequest) async throws -> CapabilityDecision {
        try await base.requestCapabilities(request)
    }

    func resolveEntity(_ request: EntityResolutionRequest) async throws -> EntityResolutionDecision {
        var decision = try await base.resolveEntity(request)
        if var proof = decision.inclusion_proof {
            proof.entity_id = "\(proof.entity_id)_tampered"
            decision.inclusion_proof = proof
        }
        return decision
    }

    func performMembershipChecks(identityPublicKey: String, domain: String) async throws -> MembershipDecision {
        try await base.performMembershipChecks(identityPublicKey: identityPublicKey, domain: domain)
    }

    func issuePortholeAccessContract(_ request: PortholeAccessRequest) async throws -> PortholeAccessDecision {
        try await base.issuePortholeAccessContract(request)
    }
}
