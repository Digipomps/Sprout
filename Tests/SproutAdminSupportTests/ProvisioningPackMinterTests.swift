import XCTest
import SproutCrypto
import SproutCore
import SproutResolverAdapter
@testable import SproutAdminSupport

/// Proves the minted pack verifies under the SAME procedures HavenAgentD's
/// verifiers use — the two distinct canonicalization regimes are the whole
/// risk here:
///   - pairing operatorApproval: sorted-keys(payload) + STANDARD base64 + Curve25519
///   - entity-link & starter-auth: JCS canonical + base64url + Ed25519
final class ProvisioningPackMinterTests: XCTestCase {

    private struct Fixture {
        let grant: EnrollmentGrant
        let submission: AgentEnrollmentSubmission
        let operatorRecord: VaporVaultIdentityRecord
        let operatorDid: String
        let operatorKey: String
        let agentKey: String
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Build everything exactly as the agent would after consuming a ticket.
    private func makeFixture(
        interests: [String] = ["alpha"],
        challengeOverride: String? = nil,
        codeOverride: String? = nil
    ) throws -> Fixture {
        let now = Date()

        // Operator identity (as it would come from the vault).
        let opSeed = Ed25519.generateSeed()
        let opKeyPair = try Ed25519KeyPair(seed: opSeed)
        let operatorRecord = VaporVaultIdentityRecord(
            uuid: "op-uuid",
            displayName: "Victoria Operator",
            identityContext: "op-ctx",
            publicKey: opKeyPair.publicKeyData,
            privateKey: opSeed
        )
        let operatorKey = operatorRecord.publicKeyBase64URL
        let operatorDid = "did:key:operator"

        // Agent identity.
        let agentSeed = Ed25519.generateSeed()
        let agentKeyPair = try Ed25519KeyPair(seed: agentSeed)
        let agentKey = Base64URL.encode(agentKeyPair.publicKeyData)

        let code = codeOverride ?? EnrollmentGrant.generateCode()
        let grant = EnrollmentGrant.issue(
            code: code,
            scaffoldDomain: "staging.haven.digipomps.org",
            purpose: "bootstrap.join_scaffold",
            allowedInterests: ["alpha", "beta"],
            entityLinkScope: "agent-operator-link",
            operatorIdentityContext: "op-ctx",
            starterAuthTTLSeconds: 3600,
            codeTTLSeconds: 600,
            now: now
        )
        let challenge = challengeOverride ?? grant.challenge

        // Pairing attestation: sorted-keys(payload) signed base64url.
        let attPayload = EnrollmentAttestation.Payload(
            version: "1.0",
            instanceName: "victoria-mac",
            agentIdentityUUID: "agent-uuid",
            agentDisplayName: "Victoria Agent",
            agentDid: "did:key:agent",
            agentPublicKeyBase64URL: agentKey,
            operatorIdentityUUID: operatorRecord.uuid,
            operatorDid: operatorDid,
            operatorPublicKeyBase64URL: operatorKey,
            purposeRef: grant.purpose,
            scaffoldDomain: grant.scaffoldDomain,
            challenge: challenge,
            issuedAt: iso(now)
        )
        let sortedKeys = JSONEncoder()
        sortedKeys.outputFormatting = [.sortedKeys]
        let attCanonical = try sortedKeys.encode(attPayload)
        let attestation = EnrollmentAttestation(
            payload: attPayload,
            signatureAlgorithm: "Ed25519",
            signatureBase64URL: Base64URL.encode(try agentKeyPair.sign(attCanonical))
        )

        // Starter-auth: JCS canonical signed base64url, self-signed by the agent.
        var starter = StarterAuthPayload(
            version: "1.0",
            domain: grant.scaffoldDomain,
            identity_public_key: agentKey,
            created_at: iso(now),
            expires_at: iso(now.addingTimeInterval(3600)),
            nonce: EnrollmentGrant.randomToken(byteCount: 16),
            purpose_interest: StarterPurposeInterest(purpose: grant.purpose, interests: interests),
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )
        let starterSig = Base64URL.encode(try agentKeyPair.sign(try starter.canonicalPayloadData()))
        starter.signature = ResolverSignatureEnvelope(alg: "Ed25519", sig: starterSig)

        // Entity-link: agent authors the body + signs its half.
        var link = EntityLinkContract(
            contract_id: grant.entityLinkContractId,
            domain_a: grant.scaffoldDomain,
            pubkey_a: agentKey,
            domain_b: grant.scaffoldDomain,
            pubkey_b: operatorKey,
            scope: grant.entityLinkScope,
            created_at: iso(now),
            revocation: EntityLinkRevocation(mode: grant.revocationMode.rawValue),
            signatures: []
        )
        let linkSig = Base64URL.encode(try agentKeyPair.sign(try link.canonicalPayloadData()))
        link.signatures = [EntityLinkSignature(by_pubkey: agentKey, alg: "Ed25519", sig: linkSig)]

        let submission = AgentEnrollmentSubmission(
            grantId: grant.grantId,
            code: code,
            boundAgent: EnrollmentBoundAgent(agentIdentityUUID: "agent-uuid", agentPublicKeyBase64URL: agentKey),
            attestation: attestation,
            starterAuth: starter,
            entityLink: link
        )

        return Fixture(
            grant: grant, submission: submission, operatorRecord: operatorRecord,
            operatorDid: operatorDid, operatorKey: operatorKey, agentKey: agentKey
        )
    }

    func testMintedPackVerifiesUnderAgentProcedures() throws {
        let f = try makeFixture()
        let pack = try ProvisioningPackMinter().mint(
            submission: f.submission, grant: f.grant,
            operatorIdentity: f.operatorRecord, operatorDid: f.operatorDid
        )

        // Entity-link is now mutually signed.
        XCTAssertEqual(pack.entityLink.signatures.count, 2)
        XCTAssertTrue(try pack.entityLink.verifyMutualSignatures())

        // Starter-auth self-signature still valid (untouched passthrough).
        XCTAssertTrue(try pack.starterAuth.verifySignature())

        // Pairing operator approval: verify EXACTLY as HavenAgentD does.
        let sortedKeys = JSONEncoder()
        sortedKeys.outputFormatting = [.sortedKeys]
        let approvalCanonical = try sortedKeys.encode(pack.pairing.operatorApproval.payload)
        let approvalSig = try XCTUnwrap(Data(base64Encoded: pack.pairing.operatorApproval.signatureBase64))
        XCTAssertTrue(Ed25519.verify(
            data: approvalCanonical,
            signature: approvalSig,
            publicKey: try Base64URL.decode(f.operatorKey)
        ))

        // Pairing agent attestation: sorted-keys + base64url.
        let attCanonical = try sortedKeys.encode(pack.pairing.agentAttestation.payload)
        XCTAssertTrue(Ed25519.verifyBase64URL(
            data: attCanonical,
            signatureBase64URL: pack.pairing.agentAttestation.signatureBase64URL,
            publicKeyBase64URL: f.agentKey
        ))

        // Operator approval binds to the attestation hash.
        XCTAssertEqual(
            pack.pairing.operatorApproval.payload.attestationSHA256Base64URL,
            Hashing.sha256Base64URL(attCanonical)
        )

        // Envelope.
        XCTAssertEqual(pack.kind, "haven-agentd-provisioning-pack")
        XCTAssertEqual(pack.scaffoldDomain, f.grant.scaffoldDomain)
        XCTAssertEqual(pack.boundAgent.agentPublicKeyBase64URL, f.agentKey)
        XCTAssertEqual(pack.pairing.verificationStatus, "agent-attestation-verified")
    }

    func testRejectsWrongCode() throws {
        let f = try makeFixture()
        var sub = f.submission
        sub.code = "WRONG-CODE-XXXX"
        XCTAssertThrowsError(try ProvisioningPackMinter().mint(
            submission: sub, grant: f.grant, operatorIdentity: f.operatorRecord, operatorDid: f.operatorDid
        )) { XCTAssertEqual($0 as? ProvisioningMintError, .codeMismatch) }
    }

    func testRejectsInterestsBeyondGrant() throws {
        let f = try makeFixture(interests: ["alpha", "gamma"]) // gamma not in [alpha, beta]
        XCTAssertThrowsError(try ProvisioningPackMinter().mint(
            submission: f.submission, grant: f.grant, operatorIdentity: f.operatorRecord, operatorDid: f.operatorDid
        )) {
            guard case ProvisioningMintError.starterAuthInvalid = $0 else {
                return XCTFail("expected starterAuthInvalid, got \($0)")
            }
        }
    }

    func testRejectsTamperedChallenge() throws {
        let f = try makeFixture(challengeOverride: "tampered-challenge")
        XCTAssertThrowsError(try ProvisioningPackMinter().mint(
            submission: f.submission, grant: f.grant, operatorIdentity: f.operatorRecord, operatorDid: f.operatorDid
        )) {
            guard case ProvisioningMintError.attestationInvalid = $0 else {
                return XCTFail("expected attestationInvalid, got \($0)")
            }
        }
    }
}
