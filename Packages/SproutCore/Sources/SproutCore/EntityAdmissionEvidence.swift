import Foundation
import SproutCrypto
import SproutResolverAdapter

public struct EntityAdmissionEvidence: Codable, Equatable, Sendable {
    public var contract: EntityAdmissionContract
    public var continuityProof: CrossScaffoldEntityContinuityProof?
    public var note: String?

    public init(
        contract: EntityAdmissionContract,
        continuityProof: CrossScaffoldEntityContinuityProof? = nil,
        note: String? = nil
    ) {
        self.contract = contract
        self.continuityProof = continuityProof
        self.note = note
    }

    public func verify(now: Date = Date()) throws -> Bool {
        guard !contract.isExpired(now: now) else {
            return false
        }
        guard try contract.verifySignature() else {
            return false
        }

        if let continuityProof {
            guard !continuityProof.isExpired(now: now) else {
                return false
            }
            guard try continuityProof.verifySignature() else {
                return false
            }
            guard try contract.matches(continuityProof: continuityProof) else {
                return false
            }
        }

        return true
    }

    public func contains(identityPublicKey: String, domain: String) -> Bool {
        contract.target_identity_public_key == identityPublicKey &&
            contract.target_identity_domain == domain
    }

    public func resolverSummary() throws -> EntityEvidenceSummary {
        let payloadHash = try contract.payloadHashBase64URL()
        return EntityEvidenceSummary(
            evidence_type: "cross_scaffold_admission_contract",
            contract_id: contract.contract_id,
            linked_public_keys: [contract.source_identity_public_key, contract.target_identity_public_key].sorted(),
            evidence_description: note ?? "target scaffold admission contract based on explicit cross-scaffold continuity",
            evidence_sha256_b64url: payloadHash,
            source_scaffold_domain: contract.source_scaffold_domain,
            source_entity_id: contract.source_entity_id,
            target_scaffold_domain: contract.target_scaffold_domain,
            target_entity_id: contract.target_entity_id
        )
    }
}
