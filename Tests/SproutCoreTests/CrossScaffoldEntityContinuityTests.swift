import XCTest
import SproutResolverAdapter
@testable import SproutCore

final class CrossScaffoldEntityContinuityTests: XCTestCase {
    private let fixedNow = ISO8601DateFormatter().date(from: "2026-02-26T08:03:00Z")!

    func testContinuityProofAndAdmissionChainVerify() throws {
        let proof = try ResolverFixtureFactory.makeCrossScaffoldContinuityProof()
        let request = try ResolverFixtureFactory.makeEntityAdmissionRequest(continuityProof: proof)
        let contract = try ResolverFixtureFactory.makeEntityAdmissionContract(
            continuityProof: proof,
            request: request
        )
        let evidence = EntityAdmissionEvidence(contract: contract, continuityProof: proof)

        XCTAssertTrue(try proof.verifySignature())
        XCTAssertTrue(try request.verifySignature())
        XCTAssertTrue(try contract.verifySignature())
        XCTAssertTrue(try request.matches(continuityProof: proof))
        XCTAssertTrue(try contract.matches(continuityProof: proof))
        XCTAssertTrue(contract.matches(admissionRequest: request))
        XCTAssertTrue(try evidence.verify(now: fixedNow))
    }

    func testAdmissionEvidenceBuildsResolverSummary() throws {
        let proof = try ResolverFixtureFactory.makeCrossScaffoldContinuityProof()
        let request = try ResolverFixtureFactory.makeEntityAdmissionRequest(continuityProof: proof)
        let contract = try ResolverFixtureFactory.makeEntityAdmissionContract(
            continuityProof: proof,
            request: request,
            targetEntityID: "entity_target_primary"
        )
        let evidence = EntityAdmissionEvidence(contract: contract, continuityProof: proof)
        let summary = try evidence.resolverSummary()

        XCTAssertEqual(summary.evidence_type, "cross_scaffold_admission_contract")
        XCTAssertEqual(summary.contract_id, contract.contract_id)
        XCTAssertEqual(summary.source_scaffold_domain, contract.source_scaffold_domain)
        XCTAssertEqual(summary.source_entity_id, contract.source_entity_id)
        XCTAssertEqual(summary.target_scaffold_domain, contract.target_scaffold_domain)
        XCTAssertEqual(summary.target_entity_id, contract.target_entity_id)
        XCTAssertTrue(summary.linked_public_keys.contains(contract.target_identity_public_key))
        XCTAssertTrue(summary.linked_public_keys.contains(contract.source_identity_public_key))
    }
}
