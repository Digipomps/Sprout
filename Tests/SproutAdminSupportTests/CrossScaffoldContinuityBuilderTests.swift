import XCTest
@testable import SproutAdminSupport
import SproutCrypto
import SproutResolverAdapter

final class CrossScaffoldContinuityBuilderTests: XCTestCase {
    func testBuildersCreateMatchingProofAndContract() throws {
        let seed = try Base64URL.decode("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let publicKey = try Ed25519KeyPair(seed: seed).publicKeyData
        let adminIdentity = VaporVaultIdentityRecord(
            uuid: "admin-1",
            displayName: "Admin",
            identityContext: "Scaffold",
            publicKey: publicKey,
            privateKey: seed
        )
        let proof = try CrossScaffoldContinuityProofBuilder.buildSignedProof(
            sourceScaffoldDomain: "source.example.haven.local",
            adminIdentity: adminIdentity,
            proofID: "ccp_fixture_0001",
            sourceEntityID: "entity_source_primary",
            sourceIdentityPublicKey: "source_identity_key_fixture",
            sourceIdentityDomain: "source.example.haven.local",
            targetScaffoldDomain: "target.example.haven.local",
            purpose: "bootstrap.join_scaffold",
            goal: "Continue the same person into target scaffold",
            interests: ["haven.core.bootstrap", "haven.core.identity"],
            issuedAt: ISO8601DateFormatter().date(from: "2026-02-26T08:00:00Z")!,
            expiresAt: ISO8601DateFormatter().date(from: "2026-02-26T08:10:00Z")!
        )

        XCTAssertTrue(try proof.verifySignature())

        var request = EntityAdmissionRequest(
            version: "1.0",
            request_id: "ear_fixture_0001",
            target_scaffold_domain: proof.target_scaffold_domain,
            target_identity_public_key: "target_identity_key_fixture",
            target_identity_domain: proof.target_scaffold_domain,
            continuity_proof_id: proof.proof_id,
            continuity_proof_sha256_b64url: try proof.payloadHashBase64URL(),
            source_scaffold_domain: proof.source_scaffold_domain,
            source_entity_id: proof.source_entity_id,
            source_identity_public_key: proof.source_identity_public_key,
            purpose: proof.purpose,
            goal: proof.goal,
            interests: proof.interests,
            created_at: "2026-02-26T08:01:00Z",
            expires_at: "2026-02-26T08:06:00Z",
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )
        request.signature = ResolverSignatureEnvelope(alg: "Ed25519", sig: "test-signature")

        let contract = try EntityAdmissionContractBuilder.buildSignedContract(
            targetScaffoldDomain: proof.target_scaffold_domain,
            adminIdentity: adminIdentity,
            contractID: "eac_fixture_0001",
            targetEntityID: "entity_target_primary",
            targetIdentityPublicKey: request.target_identity_public_key,
            targetIdentityDomain: request.target_identity_domain,
            continuityProof: proof,
            admissionRequest: request,
            issuedAt: ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")!,
            expiresAt: ISO8601DateFormatter().date(from: "2026-02-26T08:07:00Z")!
        )

        XCTAssertTrue(contract.matches(admissionRequest: request))
        XCTAssertTrue(try contract.matches(continuityProof: proof))
        XCTAssertTrue(try contract.verifySignature())
    }
}
