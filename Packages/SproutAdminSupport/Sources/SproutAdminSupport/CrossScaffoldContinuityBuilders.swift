import Foundation
import SproutCrypto
import SproutResolverAdapter

public enum CrossScaffoldContinuityProofBuilder {
    public static func buildSignedProof(
        sourceScaffoldDomain: String,
        adminIdentity: VaporVaultIdentityRecord,
        proofID: String,
        sourceEntityID: String,
        sourceIdentityPublicKey: String,
        sourceIdentityDomain: String,
        targetScaffoldDomain: String,
        purpose: String,
        goal: String,
        interests: [String],
        issuedAt: Date,
        expiresAt: Date
    ) throws -> CrossScaffoldEntityContinuityProof {
        let formatter = ISO8601DateFormatter()
        var proof = CrossScaffoldEntityContinuityProof(
            version: "1.0",
            proof_id: proofID,
            source_scaffold_domain: sourceScaffoldDomain,
            source_entity_id: sourceEntityID,
            source_identity_public_key: sourceIdentityPublicKey,
            source_identity_domain: sourceIdentityDomain,
            target_scaffold_domain: targetScaffoldDomain,
            purpose: purpose,
            goal: goal,
            interests: interests.sorted(),
            issued_at: formatter.string(from: issuedAt),
            expires_at: formatter.string(from: expiresAt),
            issued_by: adminIdentity.publicKeyBase64URL,
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )
        proof.signature = ResolverSignatureEnvelope(
            alg: "Ed25519",
            sig: try Ed25519.signBase64URL(
                data: try proof.canonicalPayloadData(),
                seedBase64URL: Base64URL.encode(adminIdentity.privateKey)
            )
        )
        return proof
    }
}

public enum EntityAdmissionContractBuilder {
    public static func buildSignedContract(
        targetScaffoldDomain: String,
        adminIdentity: VaporVaultIdentityRecord,
        contractID: String,
        targetEntityID: String,
        targetIdentityPublicKey: String,
        targetIdentityDomain: String,
        continuityProof: CrossScaffoldEntityContinuityProof,
        admissionRequest: EntityAdmissionRequest,
        issuedAt: Date,
        expiresAt: Date
    ) throws -> EntityAdmissionContract {
        guard try admissionRequest.matches(continuityProof: continuityProof) else {
            throw CrossScaffoldContinuityBuilderError.requestDoesNotMatchProof
        }

        let formatter = ISO8601DateFormatter()
        var contract = EntityAdmissionContract(
            version: "1.0",
            contract_id: contractID,
            admission_request_id: admissionRequest.request_id,
            target_scaffold_domain: targetScaffoldDomain,
            target_entity_id: targetEntityID,
            target_identity_public_key: targetIdentityPublicKey,
            target_identity_domain: targetIdentityDomain,
            continuity_proof_id: continuityProof.proof_id,
            continuity_proof_sha256_b64url: try continuityProof.payloadHashBase64URL(),
            source_scaffold_domain: continuityProof.source_scaffold_domain,
            source_entity_id: continuityProof.source_entity_id,
            source_identity_public_key: continuityProof.source_identity_public_key,
            purpose: continuityProof.purpose,
            goal: continuityProof.goal,
            interests: continuityProof.interests.sorted(),
            issued_at: formatter.string(from: issuedAt),
            expires_at: formatter.string(from: expiresAt),
            issued_by: adminIdentity.publicKeyBase64URL,
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )
        guard contract.matches(admissionRequest: admissionRequest) else {
            throw CrossScaffoldContinuityBuilderError.contractDoesNotMatchRequest
        }
        contract.signature = ResolverSignatureEnvelope(
            alg: "Ed25519",
            sig: try Ed25519.signBase64URL(
                data: try contract.canonicalPayloadData(),
                seedBase64URL: Base64URL.encode(adminIdentity.privateKey)
            )
        )
        return contract
    }
}

public enum CrossScaffoldContinuityBuilderError: Error, Equatable, Sendable {
    case requestDoesNotMatchProof
    case contractDoesNotMatchRequest
}
