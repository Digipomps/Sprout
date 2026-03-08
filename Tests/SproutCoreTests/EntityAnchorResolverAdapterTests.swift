import XCTest
import Foundation
import SproutResolverAdapter
@testable import SproutCore

final class EntityAnchorResolverAdapterTests: XCTestCase {
    private var rootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixedNow: Date {
        ISO8601DateFormatter().date(from: "2026-02-26T08:01:00Z")!
    }

    func testResolvesDirectIdentityFromAnchorAndIssuesInclusionProof() async throws {
        let starter = try loadStarterPayload()
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
        let adapter = EntityAnchorResolverAdapter(
            anchorSnapshot: snapshot,
            scenario: EntityAnchorResolverScenario(allowedDomains: [starter.domain], requireFreshPayload: false),
            now: { nowDate }
        )

        let request = EntityResolutionRequest(
            identity_public_key: starter.identity_public_key,
            domain: starter.domain,
            scaffold_admin_public_key: snapshot.admin_public_key,
            purpose: "bootstrap.join_scaffold",
            goal: "Join scaffold and register identity",
            interests: ["haven.core.bootstrap", "haven.core.bridge"],
            evidence: nil
        )

        let decision = try await adapter.resolveEntity(request)
        let proof = try XCTUnwrap(decision.inclusion_proof)

        XCTAssertEqual(decision.status, .resolved)
        XCTAssertEqual(decision.entity_id, "entity_anchor_primary")
        XCTAssertTrue(try proof.verifySignature())
        XCTAssertEqual(proof.anchor_admin_public_key, snapshot.admin_public_key)
        XCTAssertEqual(proof.subject_identity_public_key, starter.identity_public_key)
    }

    func testResolvesLinkedIdentityWhenAnchorAcceptsEntityLinkContract() async throws {
        let starter = try loadStarterPayload()
        let contract = try loadEntityLinkContract()
        let evidence = EntityLinkEvidence(
            evidence_kind: .mutualLinkContract,
            contract: contract,
            note: "accepted by entity anchor"
        )
        let summary = try evidence.resolverSummary()

        let snapshot = try ResolverFixtureFactory.makeSignedEntityAnchorSnapshot(
            identities: [
                EntityAnchorIdentityMember(
                    identity_public_key: contract.pubkey_b,
                    domain: contract.domain_b,
                    added_at: "2026-02-26T07:59:00Z",
                    source_contract_id: contract.contract_id
                )
            ],
            acceptedContractIDs: [contract.contract_id]
        )
        let nowDate = fixedNow
        let adapter = EntityAnchorResolverAdapter(
            anchorSnapshot: snapshot,
            scenario: EntityAnchorResolverScenario(allowedDomains: [starter.domain], requireFreshPayload: false),
            now: { nowDate }
        )

        let request = EntityResolutionRequest(
            identity_public_key: starter.identity_public_key,
            domain: starter.domain,
            scaffold_admin_public_key: snapshot.admin_public_key,
            purpose: "bootstrap.join_scaffold",
            goal: "Join scaffold and register identity",
            interests: ["haven.core.bootstrap", "haven.core.bridge"],
            evidence: summary
        )

        let decision = try await adapter.resolveEntity(request)
        XCTAssertEqual(decision.status, .resolved)
        XCTAssertEqual(decision.evidence_contract_id, contract.contract_id)
        XCTAssertEqual(decision.inclusion_proof?.evidence_contract_id, contract.contract_id)
    }

    func testRejectsUnacceptedEntityLinkContract() async throws {
        let starter = try loadStarterPayload()
        let contract = try loadEntityLinkContract()
        let evidence = EntityLinkEvidence(
            evidence_kind: .mutualLinkContract,
            contract: contract,
            note: "not accepted by entity anchor"
        )
        let summary = try evidence.resolverSummary()

        let snapshot = try ResolverFixtureFactory.makeSignedEntityAnchorSnapshot(
            identities: [
                EntityAnchorIdentityMember(
                    identity_public_key: contract.pubkey_b,
                    domain: contract.domain_b,
                    added_at: "2026-02-26T07:59:00Z"
                )
            ],
            acceptedContractIDs: []
        )
        let nowDate = fixedNow
        let adapter = EntityAnchorResolverAdapter(
            anchorSnapshot: snapshot,
            scenario: EntityAnchorResolverScenario(allowedDomains: [starter.domain], requireFreshPayload: false),
            now: { nowDate }
        )

        let request = EntityResolutionRequest(
            identity_public_key: starter.identity_public_key,
            domain: starter.domain,
            scaffold_admin_public_key: snapshot.admin_public_key,
            purpose: "bootstrap.join_scaffold",
            goal: "Join scaffold and register identity",
            interests: ["haven.core.bootstrap", "haven.core.bridge"],
            evidence: summary
        )

        let decision = try await adapter.resolveEntity(request)
        XCTAssertEqual(decision.status, .unresolved)
        XCTAssertNil(decision.inclusion_proof)
        XCTAssertEqual(decision.reason, "entity anchor did not accept the supplied inclusion evidence for this identity")
    }

    private func loadStarterPayload() throws -> StarterAuthPayload {
        try JSONDecoder().decode(
            StarterAuthPayload.self,
            from: Data(contentsOf: rootURL.appendingPathComponent("TestVectors/starter_auth_payload.signed.json"))
        )
    }

    private func loadEntityLinkContract() throws -> EntityLinkContract {
        try JSONDecoder().decode(
            EntityLinkContract.self,
            from: Data(contentsOf: rootURL.appendingPathComponent("TestVectors/entity_link_contract.mutual.json"))
        )
    }
}
