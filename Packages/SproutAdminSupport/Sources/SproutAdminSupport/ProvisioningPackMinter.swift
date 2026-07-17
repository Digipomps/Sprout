import Foundation
import SproutCrypto
import SproutCore
import SproutResolverAdapter

// MARK: - Minted output (mirrors HavenAgentD's pack + pairing JSON)

/// Mirror of HavenAgentD's pairing artifact JSON. Decoded + verified there by
/// `AgentPairingArtifactLoader`. `operatorApproval.signatureBase64` is STANDARD
/// base64 and the payload is canonicalized with sorted-keys (not JCS).
public struct MintedPairingArtifact: Codable, Equatable, Sendable {
    public struct OperatorApproval: Codable, Equatable, Sendable {
        public struct Payload: Codable, Equatable, Sendable {
            public var version: String
            public var pairingID: String
            public var scaffoldDomain: String
            public var purposeRef: String
            public var challenge: String
            public var attestationSHA256Base64URL: String
            public var operatorIdentityUUID: String
            public var operatorDisplayName: String
            public var operatorDid: String
            public var operatorPublicKeyBase64URL: String
            public var approvedAt: String
        }
        public var payload: Payload
        public var signatureBase64: String
        public var curveType: String
    }

    public var version: String
    public var pairingID: String
    public var recordedAt: String
    public var verificationStatus: String
    public var agentAttestation: EnrollmentAttestation
    public var operatorApproval: OperatorApproval
}

/// Mirror of HavenAgentD's `ProvisioningPack`. Decoded there by
/// `ProvisioningPack.load` / `ProvisioningPackImporter`.
public struct MintedProvisioningPack: Codable, Equatable, Sendable {
    public var version: String
    public var kind: String
    public var scaffoldDomain: String
    public var purposeRef: String?
    public var boundAgent: EnrollmentBoundAgent
    public var createdAt: String
    public var issuedBy: String?
    public var pairing: MintedPairingArtifact
    public var starterAuth: StarterAuthPayload
    public var entityLink: EntityLinkContract
}

// MARK: - Errors

public enum ProvisioningMintError: Error, Equatable, Sendable {
    case unsupportedSubmission(kind: String, version: String)
    case grantMismatch(String)
    case codeMismatch
    case attestationInvalid(String)
    case starterAuthInvalid(String)
    case entityLinkInvalid(String)
    case operatorIdentityMismatch(String)
}

// MARK: - Minter

/// Co-signs an agent's enrollment submission into a provisioning pack.
///
/// The operator can only mint what it has authority over: the operator half of
/// the entity-link and the pairing operator-approval. Starter-auth is agent-
/// self-signed and passed through after verification. Grant *lifecycle*
/// (expiry / uses / revoked) is the caller's responsibility — call
/// `grant.validateRedemption(...)` then `store.consume(grantId:)` BEFORE mint so
/// single-use is enforced; mint only checks artifact correctness + binding.
public struct ProvisioningPackMinter {
    public init() {}

    public func mint(
        submission: AgentEnrollmentSubmission,
        grant: EnrollmentGrant,
        operatorIdentity: VaporVaultIdentityRecord,
        operatorDid: String,
        now: Date = Date()
    ) throws -> MintedProvisioningPack {
        guard submission.kind == AgentEnrollmentSubmission.kind,
              submission.version == AgentEnrollmentSubmission.currentVersion else {
            throw ProvisioningMintError.unsupportedSubmission(kind: submission.kind, version: submission.version)
        }
        guard submission.grantId == grant.grantId else {
            throw ProvisioningMintError.grantMismatch("submission grantId does not match grant")
        }
        guard EnrollmentGrant.constantTimeEquals(
            EnrollmentGrant.codeHash(forPresented: submission.code), grant.codeHash) else {
            throw ProvisioningMintError.codeMismatch
        }

        let agentKey = submission.boundAgent.agentPublicKeyBase64URL
        let operatorKey = operatorIdentity.publicKeyBase64URL

        // --- attestation: agent-signed, names operator + challenge ---
        let att = submission.attestation
        let attCanonical = try att.canonicalPayloadData()
        guard Ed25519.verifyBase64URL(
            data: attCanonical,
            signatureBase64URL: att.signatureBase64URL,
            publicKeyBase64URL: att.payload.agentPublicKeyBase64URL
        ) else {
            throw ProvisioningMintError.attestationInvalid("agent attestation signature did not verify")
        }
        try requireAttestation(att, grant: grant, agentKey: agentKey, operatorKey: operatorKey, operatorDid: operatorDid, operatorUUID: operatorIdentity.uuid)

        // --- starter-auth: agent-self-signed, passed through after checks ---
        let starter = submission.starterAuth
        guard (try? starter.verifySignature()) == true else {
            throw ProvisioningMintError.starterAuthInvalid("signature did not verify")
        }
        guard starter.identity_public_key == agentKey else {
            throw ProvisioningMintError.starterAuthInvalid("not bound to this agent's key")
        }
        guard starter.domain == grant.scaffoldDomain else {
            throw ProvisioningMintError.starterAuthInvalid("domain mismatch")
        }
        guard starter.purpose_interest.purpose == grant.purpose else {
            throw ProvisioningMintError.starterAuthInvalid("purpose exceeds grant")
        }
        let starterExtra = Set(starter.purpose_interest.interests).subtracting(Set(grant.allowedInterests))
        guard starterExtra.isEmpty else {
            throw ProvisioningMintError.starterAuthInvalid("interests exceed grant: \(starterExtra.sorted())")
        }

        // --- entity-link: complete the agent's half with the operator half ---
        let completedLink = try completeEntityLink(
            submission.entityLink, grant: grant, agentKey: agentKey,
            operatorIdentity: operatorIdentity, operatorKey: operatorKey
        )

        // --- pairing operator approval ---
        let pairing = try buildPairing(
            attestation: att, grant: grant, operatorIdentity: operatorIdentity,
            operatorKey: operatorKey, operatorDid: operatorDid, now: now
        )

        return MintedProvisioningPack(
            version: "1.0",
            kind: "haven-agentd-provisioning-pack",
            scaffoldDomain: grant.scaffoldDomain,
            purposeRef: grant.purpose,
            boundAgent: submission.boundAgent,
            createdAt: EnrollmentGrant.iso8601(now),
            issuedBy: grant.issuedBy,
            pairing: pairing,
            starterAuth: starter,
            entityLink: completedLink
        )
    }

    // MARK: - Steps

    private func requireAttestation(
        _ att: EnrollmentAttestation, grant: EnrollmentGrant,
        agentKey: String, operatorKey: String, operatorDid: String, operatorUUID: String
    ) throws {
        let p = att.payload
        func check(_ ok: Bool, _ why: String) throws {
            if !ok { throw ProvisioningMintError.attestationInvalid(why) }
        }
        try check(p.agentPublicKeyBase64URL == agentKey, "agent key mismatch")
        try check(p.challenge == grant.challenge, "challenge mismatch")
        try check(p.scaffoldDomain == grant.scaffoldDomain, "scaffold domain mismatch")
        try check(p.purposeRef == grant.purpose, "purpose mismatch")
        try check(p.operatorPublicKeyBase64URL == operatorKey, "operator key mismatch")
        try check(p.operatorIdentityUUID == operatorUUID, "operator uuid mismatch")
        try check(p.operatorDid == operatorDid, "operator did mismatch")
    }

    private func completeEntityLink(
        _ link: EntityLinkContract, grant: EnrollmentGrant,
        agentKey: String, operatorIdentity: VaporVaultIdentityRecord, operatorKey: String
    ) throws -> EntityLinkContract {
        func fail(_ why: String) -> ProvisioningMintError { .entityLinkInvalid(why) }

        guard link.contract_id == grant.entityLinkContractId else { throw fail("contract_id mismatch") }
        guard link.scope == grant.entityLinkScope else { throw fail("scope mismatch") }
        guard link.revocation.mode == grant.revocationMode.rawValue else { throw fail("revocation mode mismatch") }
        guard link.domain_a == grant.scaffoldDomain, link.domain_b == grant.scaffoldDomain else {
            throw fail("domain mismatch")
        }
        let keys = Set([link.pubkey_a, link.pubkey_b])
        guard keys == Set([agentKey, operatorKey]) else { throw fail("linked keys must be exactly agent + operator") }

        // The agent must already have signed exactly its own half.
        guard link.signatures.count == 1, let agentSig = link.signatures.first,
              agentSig.by_pubkey == agentKey else {
            throw fail("expected exactly the agent's signature")
        }
        let canonical = try link.canonicalPayloadData()
        guard Ed25519.verifyBase64URL(data: canonical, signatureBase64URL: agentSig.sig, publicKeyBase64URL: agentKey) else {
            throw fail("agent signature did not verify")
        }

        // Append the operator signature over the same canonical bytes.
        let keyPair = try Ed25519KeyPair(seed: operatorIdentity.privateKey)
        let operatorSig = Base64URL.encode(try keyPair.sign(canonical))
        var completed = link
        completed.signatures.append(EntityLinkSignature(by_pubkey: operatorKey, alg: "Ed25519", sig: operatorSig))

        guard (try? completed.verifyMutualSignatures()) == true else {
            throw fail("completed contract failed mutual verification")
        }
        return completed
    }

    private func buildPairing(
        attestation: EnrollmentAttestation, grant: EnrollmentGrant,
        operatorIdentity: VaporVaultIdentityRecord, operatorKey: String,
        operatorDid: String, now: Date
    ) throws -> MintedPairingArtifact {
        let attestationHash = Hashing.sha256Base64URL(try attestation.canonicalPayloadData())

        let approvalPayload = MintedPairingArtifact.OperatorApproval.Payload(
            version: "1.0",
            pairingID: grant.pairingID,
            scaffoldDomain: grant.scaffoldDomain,
            purposeRef: grant.purpose,
            challenge: grant.challenge,
            attestationSHA256Base64URL: attestationHash,
            operatorIdentityUUID: operatorIdentity.uuid,
            operatorDisplayName: operatorIdentity.displayName,
            operatorDid: operatorDid,
            operatorPublicKeyBase64URL: operatorKey,
            approvedAt: EnrollmentGrant.iso8601(now)
        )

        // sorted-keys JSON of the payload, signed raw, encoded STANDARD base64.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let approvalCanonical = try encoder.encode(approvalPayload)
        let keyPair = try Ed25519KeyPair(seed: operatorIdentity.privateKey)
        let approvalSig = try keyPair.sign(approvalCanonical).base64EncodedString()

        return MintedPairingArtifact(
            version: "1.0",
            pairingID: grant.pairingID,
            recordedAt: EnrollmentGrant.iso8601(now),
            verificationStatus: "agent-attestation-verified",
            agentAttestation: attestation,
            operatorApproval: .init(payload: approvalPayload, signatureBase64: approvalSig, curveType: "ed25519")
        )
    }
}
