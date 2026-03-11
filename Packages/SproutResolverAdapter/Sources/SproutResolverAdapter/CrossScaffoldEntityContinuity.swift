import Foundation
import SproutCrypto

public struct CrossScaffoldEntityContinuityProof: Codable, Equatable, Sendable {
    public var version: String
    public var proof_id: String
    public var source_scaffold_domain: String
    public var source_entity_id: String
    public var source_identity_public_key: String
    public var source_identity_domain: String
    public var target_scaffold_domain: String
    public var purpose: String
    public var goal: String
    public var interests: [String]
    public var issued_at: String
    public var expires_at: String
    public var issued_by: String
    public var signature: ResolverSignatureEnvelope

    public init(
        version: String,
        proof_id: String,
        source_scaffold_domain: String,
        source_entity_id: String,
        source_identity_public_key: String,
        source_identity_domain: String,
        target_scaffold_domain: String,
        purpose: String,
        goal: String,
        interests: [String],
        issued_at: String,
        expires_at: String,
        issued_by: String,
        signature: ResolverSignatureEnvelope
    ) {
        self.version = version
        self.proof_id = proof_id
        self.source_scaffold_domain = source_scaffold_domain
        self.source_entity_id = source_entity_id
        self.source_identity_public_key = source_identity_public_key
        self.source_identity_domain = source_identity_domain
        self.target_scaffold_domain = target_scaffold_domain
        self.purpose = purpose
        self.goal = goal
        self.interests = interests
        self.issued_at = issued_at
        self.expires_at = expires_at
        self.issued_by = issued_by
        self.signature = signature
    }

    public func canonicalPayloadData() throws -> Data {
        let encoded = try JSONEncoder.sorted.encode(self)
        return try JCSCanonicalizer.canonicalizeRemovingTopLevelKeys(encoded, keys: ["signature"])
    }

    public func payloadHashBase64URL() throws -> String {
        try Hashing.sha256Base64URL(canonicalPayloadData())
    }

    public func verifySignature() throws -> Bool {
        guard signature.alg == "Ed25519" else {
            return false
        }
        return Ed25519.verifyBase64URL(
            data: try canonicalPayloadData(),
            signatureBase64URL: signature.sig,
            publicKeyBase64URL: issued_by
        )
    }

    public func isExpired(now: Date = Date()) -> Bool {
        let formatter = ISO8601DateFormatter()
        guard let expiry = formatter.date(from: expires_at) else {
            return true
        }
        return now >= expiry
    }
}

public struct EntityAdmissionRequest: Codable, Equatable, Sendable {
    public var version: String
    public var request_id: String
    public var target_scaffold_domain: String
    public var target_identity_public_key: String
    public var target_identity_domain: String
    public var continuity_proof_id: String
    public var continuity_proof_sha256_b64url: String
    public var source_scaffold_domain: String
    public var source_entity_id: String
    public var source_identity_public_key: String
    public var purpose: String
    public var goal: String
    public var interests: [String]
    public var created_at: String
    public var expires_at: String
    public var signature: ResolverSignatureEnvelope

    public init(
        version: String,
        request_id: String,
        target_scaffold_domain: String,
        target_identity_public_key: String,
        target_identity_domain: String,
        continuity_proof_id: String,
        continuity_proof_sha256_b64url: String,
        source_scaffold_domain: String,
        source_entity_id: String,
        source_identity_public_key: String,
        purpose: String,
        goal: String,
        interests: [String],
        created_at: String,
        expires_at: String,
        signature: ResolverSignatureEnvelope
    ) {
        self.version = version
        self.request_id = request_id
        self.target_scaffold_domain = target_scaffold_domain
        self.target_identity_public_key = target_identity_public_key
        self.target_identity_domain = target_identity_domain
        self.continuity_proof_id = continuity_proof_id
        self.continuity_proof_sha256_b64url = continuity_proof_sha256_b64url
        self.source_scaffold_domain = source_scaffold_domain
        self.source_entity_id = source_entity_id
        self.source_identity_public_key = source_identity_public_key
        self.purpose = purpose
        self.goal = goal
        self.interests = interests
        self.created_at = created_at
        self.expires_at = expires_at
        self.signature = signature
    }

    public func canonicalPayloadData() throws -> Data {
        let encoded = try JSONEncoder.sorted.encode(self)
        return try JCSCanonicalizer.canonicalizeRemovingTopLevelKeys(encoded, keys: ["signature"])
    }

    public func verifySignature() throws -> Bool {
        guard signature.alg == "Ed25519" else {
            return false
        }
        return Ed25519.verifyBase64URL(
            data: try canonicalPayloadData(),
            signatureBase64URL: signature.sig,
            publicKeyBase64URL: target_identity_public_key
        )
    }

    public func isExpired(now: Date = Date()) -> Bool {
        let formatter = ISO8601DateFormatter()
        guard let expiry = formatter.date(from: expires_at) else {
            return true
        }
        return now >= expiry
    }

    public func matches(continuityProof: CrossScaffoldEntityContinuityProof) throws -> Bool {
        let proofHash = try continuityProof.payloadHashBase64URL()
        return continuity_proof_id == continuityProof.proof_id &&
            continuity_proof_sha256_b64url == proofHash &&
            source_scaffold_domain == continuityProof.source_scaffold_domain &&
            source_entity_id == continuityProof.source_entity_id &&
            source_identity_public_key == continuityProof.source_identity_public_key &&
            target_scaffold_domain == continuityProof.target_scaffold_domain &&
            purpose == continuityProof.purpose &&
            goal == continuityProof.goal &&
            interests.sorted() == continuityProof.interests.sorted()
    }
}

public struct EntityAdmissionContract: Codable, Equatable, Sendable {
    public var version: String
    public var contract_id: String
    public var admission_request_id: String?
    public var target_scaffold_domain: String
    public var target_entity_id: String
    public var target_identity_public_key: String
    public var target_identity_domain: String
    public var continuity_proof_id: String
    public var continuity_proof_sha256_b64url: String
    public var source_scaffold_domain: String
    public var source_entity_id: String
    public var source_identity_public_key: String
    public var purpose: String
    public var goal: String
    public var interests: [String]
    public var issued_at: String
    public var expires_at: String
    public var issued_by: String
    public var signature: ResolverSignatureEnvelope

    public init(
        version: String,
        contract_id: String,
        admission_request_id: String? = nil,
        target_scaffold_domain: String,
        target_entity_id: String,
        target_identity_public_key: String,
        target_identity_domain: String,
        continuity_proof_id: String,
        continuity_proof_sha256_b64url: String,
        source_scaffold_domain: String,
        source_entity_id: String,
        source_identity_public_key: String,
        purpose: String,
        goal: String,
        interests: [String],
        issued_at: String,
        expires_at: String,
        issued_by: String,
        signature: ResolverSignatureEnvelope
    ) {
        self.version = version
        self.contract_id = contract_id
        self.admission_request_id = admission_request_id
        self.target_scaffold_domain = target_scaffold_domain
        self.target_entity_id = target_entity_id
        self.target_identity_public_key = target_identity_public_key
        self.target_identity_domain = target_identity_domain
        self.continuity_proof_id = continuity_proof_id
        self.continuity_proof_sha256_b64url = continuity_proof_sha256_b64url
        self.source_scaffold_domain = source_scaffold_domain
        self.source_entity_id = source_entity_id
        self.source_identity_public_key = source_identity_public_key
        self.purpose = purpose
        self.goal = goal
        self.interests = interests
        self.issued_at = issued_at
        self.expires_at = expires_at
        self.issued_by = issued_by
        self.signature = signature
    }

    public func canonicalPayloadData() throws -> Data {
        let encoded = try JSONEncoder.sorted.encode(self)
        return try JCSCanonicalizer.canonicalizeRemovingTopLevelKeys(encoded, keys: ["signature"])
    }

    public func payloadHashBase64URL() throws -> String {
        try Hashing.sha256Base64URL(canonicalPayloadData())
    }

    public func verifySignature() throws -> Bool {
        guard signature.alg == "Ed25519" else {
            return false
        }
        return Ed25519.verifyBase64URL(
            data: try canonicalPayloadData(),
            signatureBase64URL: signature.sig,
            publicKeyBase64URL: issued_by
        )
    }

    public func isExpired(now: Date = Date()) -> Bool {
        let formatter = ISO8601DateFormatter()
        guard let expiry = formatter.date(from: expires_at) else {
            return true
        }
        return now >= expiry
    }

    public func matches(continuityProof: CrossScaffoldEntityContinuityProof) throws -> Bool {
        let proofHash = try continuityProof.payloadHashBase64URL()
        return continuity_proof_id == continuityProof.proof_id &&
            continuity_proof_sha256_b64url == proofHash &&
            source_scaffold_domain == continuityProof.source_scaffold_domain &&
            source_entity_id == continuityProof.source_entity_id &&
            source_identity_public_key == continuityProof.source_identity_public_key &&
            target_scaffold_domain == continuityProof.target_scaffold_domain &&
            purpose == continuityProof.purpose &&
            goal == continuityProof.goal &&
            interests.sorted() == continuityProof.interests.sorted()
    }

    public func matches(admissionRequest: EntityAdmissionRequest) -> Bool {
        target_scaffold_domain == admissionRequest.target_scaffold_domain &&
            target_identity_public_key == admissionRequest.target_identity_public_key &&
            target_identity_domain == admissionRequest.target_identity_domain &&
            continuity_proof_id == admissionRequest.continuity_proof_id &&
            continuity_proof_sha256_b64url == admissionRequest.continuity_proof_sha256_b64url &&
            source_scaffold_domain == admissionRequest.source_scaffold_domain &&
            source_entity_id == admissionRequest.source_entity_id &&
            source_identity_public_key == admissionRequest.source_identity_public_key &&
            purpose == admissionRequest.purpose &&
            goal == admissionRequest.goal &&
            interests.sorted() == admissionRequest.interests.sorted()
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        if #available(macOS 10.13, iOS 11.0, *) {
            encoder.outputFormatting = [.sortedKeys]
        }
        return encoder
    }
}
