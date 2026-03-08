import Foundation
import SproutCrypto
import SproutEconomics

public struct StarterPurposeInterest: Codable, Equatable, Sendable {
    public var purpose: String
    public var interests: [String]

    public init(purpose: String, interests: [String]) {
        self.purpose = purpose
        self.interests = interests
    }
}

public struct ResolverSignatureEnvelope: Codable, Equatable, Sendable {
    public var alg: String
    public var sig: String

    public init(alg: String, sig: String) {
        self.alg = alg
        self.sig = sig
    }
}

public struct StarterAuthPayload: Codable, Equatable, Sendable {
    public var version: String
    public var domain: String
    public var identity_public_key: String
    public var created_at: String
    public var expires_at: String
    public var nonce: String
    public var purpose_interest: StarterPurposeInterest
    public var signature: ResolverSignatureEnvelope

    public init(
        version: String,
        domain: String,
        identity_public_key: String,
        created_at: String,
        expires_at: String,
        nonce: String,
        purpose_interest: StarterPurposeInterest,
        signature: ResolverSignatureEnvelope
    ) {
        self.version = version
        self.domain = domain
        self.identity_public_key = identity_public_key
        self.created_at = created_at
        self.expires_at = expires_at
        self.nonce = nonce
        self.purpose_interest = purpose_interest
        self.signature = signature
    }

    public func canonicalPayloadData() throws -> Data {
        let encoded = try JSONEncoder().encode(self)
        return try JCSCanonicalizer.canonicalizeRemovingTopLevelKeys(encoded, keys: ["signature"])
    }

    public func verifySignature() throws -> Bool {
        guard signature.alg == "Ed25519" else { return false }
        let payload = try canonicalPayloadData()
        return Ed25519.verifyBase64URL(
            data: payload,
            signatureBase64URL: signature.sig,
            publicKeyBase64URL: identity_public_key
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

public struct ResolverRegistrationResult: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var registration_id: String?
    public var reason: String?

    public init(accepted: Bool, registration_id: String?, reason: String?) {
        self.accepted = accepted
        self.registration_id = registration_id
        self.reason = reason
    }
}

public struct CapabilityRequest: Codable, Equatable, Sendable {
    public var identity_public_key: String
    public var domain: String
    public var purpose: String
    public var required_capabilities: [String]

    public init(identity_public_key: String, domain: String, purpose: String, required_capabilities: [String]) {
        self.identity_public_key = identity_public_key
        self.domain = domain
        self.purpose = purpose
        self.required_capabilities = required_capabilities
    }
}

public struct CapabilityDecision: Codable, Equatable, Sendable {
    public var granted: [String]
    public var denied: [String]

    public init(granted: [String], denied: [String]) {
        self.granted = granted
        self.denied = denied
    }

    public var isAllowed: Bool {
        denied.isEmpty
    }
}

public struct MembershipDecision: Codable, Equatable, Sendable {
    public var allowed: Bool
    public var reason: String?

    public init(allowed: Bool, reason: String? = nil) {
        self.allowed = allowed
        self.reason = reason
    }
}

public struct ScaffoldAdminIdentity: Codable, Equatable, Sendable {
    public var scaffold_domain: String
    public var admin_public_key: String
    public var source_descriptor_id: String
    public var trust_origin: String

    public init(
        scaffold_domain: String,
        admin_public_key: String,
        source_descriptor_id: String,
        trust_origin: String
    ) {
        self.scaffold_domain = scaffold_domain
        self.admin_public_key = admin_public_key
        self.source_descriptor_id = source_descriptor_id
        self.trust_origin = trust_origin
    }
}

public struct EntityEvidenceSummary: Codable, Equatable, Sendable {
    public var evidence_type: String
    public var contract_id: String?
    public var linked_public_keys: [String]
    public var evidence_description: String
    public var evidence_sha256_b64url: String?

    public init(
        evidence_type: String,
        contract_id: String?,
        linked_public_keys: [String],
        evidence_description: String,
        evidence_sha256_b64url: String?
    ) {
        self.evidence_type = evidence_type
        self.contract_id = contract_id
        self.linked_public_keys = linked_public_keys
        self.evidence_description = evidence_description
        self.evidence_sha256_b64url = evidence_sha256_b64url
    }
}

public enum EntityResolutionStatus: String, Codable, Equatable, Sendable {
    case resolved
    case unresolved
}

public struct EntityResolutionRequest: Codable, Equatable, Sendable {
    public var identity_public_key: String
    public var domain: String
    public var scaffold_admin_public_key: String
    public var purpose: String
    public var goal: String
    public var interests: [String]
    public var evidence: EntityEvidenceSummary?

    public init(
        identity_public_key: String,
        domain: String,
        scaffold_admin_public_key: String,
        purpose: String,
        goal: String,
        interests: [String],
        evidence: EntityEvidenceSummary?
    ) {
        self.identity_public_key = identity_public_key
        self.domain = domain
        self.scaffold_admin_public_key = scaffold_admin_public_key
        self.purpose = purpose
        self.goal = goal
        self.interests = interests
        self.evidence = evidence
    }
}

public struct EntityAnchorIdentityMember: Codable, Equatable, Sendable {
    public var identity_public_key: String
    public var domain: String
    public var added_at: String
    public var source_contract_id: String?

    public init(identity_public_key: String, domain: String, added_at: String, source_contract_id: String? = nil) {
        self.identity_public_key = identity_public_key
        self.domain = domain
        self.added_at = added_at
        self.source_contract_id = source_contract_id
    }
}

public struct EntityAnchorEntityRecord: Codable, Equatable, Sendable {
    public var entity_id: String
    public var identities: [EntityAnchorIdentityMember]
    public var accepted_entity_link_contract_ids: [String]

    public init(
        entity_id: String,
        identities: [EntityAnchorIdentityMember],
        accepted_entity_link_contract_ids: [String] = []
    ) {
        self.entity_id = entity_id
        self.identities = identities
        self.accepted_entity_link_contract_ids = accepted_entity_link_contract_ids
    }

    public func containsIdentity(_ identityPublicKey: String, domain: String) -> Bool {
        identities.contains { $0.identity_public_key == identityPublicKey && $0.domain == domain }
    }

    public func acceptsEvidence(_ evidence: EntityEvidenceSummary, subjectIdentityPublicKey: String) -> Bool {
        guard let contractID = evidence.contract_id else {
            return false
        }
        guard accepted_entity_link_contract_ids.contains(contractID) else {
            return false
        }
        guard evidence.linked_public_keys.contains(subjectIdentityPublicKey) else {
            return false
        }

        let anchoredKeys = Set(identities.map(\.identity_public_key))
        let otherLinkedKeys = Set(evidence.linked_public_keys).subtracting([subjectIdentityPublicKey])
        return !anchoredKeys.intersection(otherLinkedKeys).isEmpty
    }
}

public struct EntityAnchorSnapshot: Codable, Equatable, Sendable {
    public var snapshot_id: String
    public var scaffold_domain: String
    public var admin_public_key: String
    public var issued_at: String
    public var expires_at: String
    public var entities: [EntityAnchorEntityRecord]
    public var signature: ResolverSignatureEnvelope

    public init(
        snapshot_id: String,
        scaffold_domain: String,
        admin_public_key: String,
        issued_at: String,
        expires_at: String,
        entities: [EntityAnchorEntityRecord],
        signature: ResolverSignatureEnvelope
    ) {
        self.snapshot_id = snapshot_id
        self.scaffold_domain = scaffold_domain
        self.admin_public_key = admin_public_key
        self.issued_at = issued_at
        self.expires_at = expires_at
        self.entities = entities
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
            publicKeyBase64URL: admin_public_key
        )
    }

    public func isExpired(now: Date = Date()) -> Bool {
        let formatter = ISO8601DateFormatter()
        guard let expiry = formatter.date(from: expires_at) else {
            return true
        }
        return now >= expiry
    }

    public func payloadHashBase64URL() throws -> String {
        Hashing.sha256Base64URL(try canonicalPayloadData())
    }

    public func entityRecord(containingIdentity identityPublicKey: String, domain: String) -> EntityAnchorEntityRecord? {
        entities.first { $0.containsIdentity(identityPublicKey, domain: domain) }
    }

    public func entityRecordAcceptingEvidence(
        _ evidence: EntityEvidenceSummary,
        subjectIdentityPublicKey: String
    ) -> EntityAnchorEntityRecord? {
        entities.first { $0.acceptsEvidence(evidence, subjectIdentityPublicKey: subjectIdentityPublicKey) }
    }
}

public struct EntityInclusionProof: Codable, Equatable, Sendable {
    public var proof_id: String
    public var scaffold_domain: String
    public var entity_id: String
    public var subject_identity_public_key: String
    public var subject_domain: String
    public var anchor_snapshot_id: String
    public var anchor_snapshot_sha256_b64url: String
    public var anchor_admin_public_key: String
    public var evidence_contract_id: String?
    public var issued_at: String
    public var expires_at: String
    public var issued_by: String
    public var signature: ResolverSignatureEnvelope

    public init(
        proof_id: String,
        scaffold_domain: String,
        entity_id: String,
        subject_identity_public_key: String,
        subject_domain: String,
        anchor_snapshot_id: String,
        anchor_snapshot_sha256_b64url: String,
        anchor_admin_public_key: String,
        evidence_contract_id: String? = nil,
        issued_at: String,
        expires_at: String,
        issued_by: String,
        signature: ResolverSignatureEnvelope
    ) {
        self.proof_id = proof_id
        self.scaffold_domain = scaffold_domain
        self.entity_id = entity_id
        self.subject_identity_public_key = subject_identity_public_key
        self.subject_domain = subject_domain
        self.anchor_snapshot_id = anchor_snapshot_id
        self.anchor_snapshot_sha256_b64url = anchor_snapshot_sha256_b64url
        self.anchor_admin_public_key = anchor_admin_public_key
        self.evidence_contract_id = evidence_contract_id
        self.issued_at = issued_at
        self.expires_at = expires_at
        self.issued_by = issued_by
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

public struct EntityResolutionDecision: Codable, Equatable, Sendable {
    public var status: EntityResolutionStatus
    public var entity_id: String?
    public var inclusion_proof: EntityInclusionProof?
    public var resolved_by: String?
    public var resolved_at: String?
    public var evidence_contract_id: String?
    public var reason: String?

    public init(
        status: EntityResolutionStatus,
        entity_id: String?,
        inclusion_proof: EntityInclusionProof? = nil,
        resolved_by: String? = nil,
        resolved_at: String? = nil,
        evidence_contract_id: String? = nil,
        reason: String? = nil
    ) {
        self.status = status
        self.entity_id = entity_id
        self.inclusion_proof = inclusion_proof
        self.resolved_by = resolved_by
        self.resolved_at = resolved_at
        self.evidence_contract_id = evidence_contract_id
        self.reason = reason
    }

    public var isResolved: Bool {
        status == .resolved && entity_id?.isEmpty == false
    }

    public var hasInclusionProof: Bool {
        inclusion_proof != nil
    }
}

public enum PortholeClientKind: String, Codable, Equatable, Sendable {
    case web
    case cli
    case native
}

public enum PortholeProtocolKind: String, Codable, Equatable, Sendable {
    case web
    case cli
    case cellprotocol
}

public extension PortholeClientKind {
    var defaultProtocol: PortholeProtocolKind {
        switch self {
        case .web:
            return .web
        case .cli:
            return .cli
        case .native:
            return .cellprotocol
        }
    }
}

public struct PortholeAccessRequest: Codable, Equatable, Sendable {
    public var scaffold_domain: String
    public var entity_id: String?
    public var identity_public_key: String
    public var scaffold_admin_public_key: String
    public var bridge_descriptor_id: String
    public var bridge_endpoint: String
    public var client_kind: PortholeClientKind
    public var porthole_protocol: PortholeProtocolKind
    public var purpose: String
    public var goal: String
    public var interests: [String]
    public var capability_grants: [String]
    public var entity_evidence_contract_id: String?
    public var declared_deposit_rau: Int64?
    public var pricing_contract: CloudBridgePricingContract?

    public init(
        scaffold_domain: String,
        entity_id: String?,
        identity_public_key: String,
        scaffold_admin_public_key: String,
        bridge_descriptor_id: String,
        bridge_endpoint: String,
        client_kind: PortholeClientKind,
        porthole_protocol: PortholeProtocolKind,
        purpose: String,
        goal: String,
        interests: [String],
        capability_grants: [String],
        entity_evidence_contract_id: String?,
        declared_deposit_rau: Int64? = nil,
        pricing_contract: CloudBridgePricingContract? = nil
    ) {
        self.scaffold_domain = scaffold_domain
        self.entity_id = entity_id
        self.identity_public_key = identity_public_key
        self.scaffold_admin_public_key = scaffold_admin_public_key
        self.bridge_descriptor_id = bridge_descriptor_id
        self.bridge_endpoint = bridge_endpoint
        self.client_kind = client_kind
        self.porthole_protocol = porthole_protocol
        self.purpose = purpose
        self.goal = goal
        self.interests = interests
        self.capability_grants = capability_grants
        self.entity_evidence_contract_id = entity_evidence_contract_id
        self.declared_deposit_rau = declared_deposit_rau
        self.pricing_contract = pricing_contract
    }
}

public struct PortholeAccessContract: Codable, Equatable, Sendable {
    public var contract_id: String
    public var scaffold_domain: String
    public var entity_id: String
    public var identity_public_key: String
    public var scaffold_admin_public_key: String
    public var bridge_descriptor_id: String
    public var bridge_endpoint: String
    public var client_kind: PortholeClientKind
    public var porthole_protocol: PortholeProtocolKind
    public var capability_grants: [String]
    public var purpose: String
    public var goal: String
    public var interests: [String]
    public var issued_at: String
    public var expires_at: String
    public var issued_by: String
    public var entity_evidence_contract_id: String?
    public var declared_deposit_rau: Int64?
    public var pricing_plan: CompiledCloudBridgePricingPlan?
    public var signature: ResolverSignatureEnvelope

    public init(
        contract_id: String,
        scaffold_domain: String,
        entity_id: String,
        identity_public_key: String,
        scaffold_admin_public_key: String,
        bridge_descriptor_id: String,
        bridge_endpoint: String,
        client_kind: PortholeClientKind,
        porthole_protocol: PortholeProtocolKind,
        capability_grants: [String],
        purpose: String,
        goal: String,
        interests: [String],
        issued_at: String,
        expires_at: String,
        issued_by: String,
        entity_evidence_contract_id: String?,
        declared_deposit_rau: Int64? = nil,
        pricing_plan: CompiledCloudBridgePricingPlan? = nil,
        signature: ResolverSignatureEnvelope
    ) {
        self.contract_id = contract_id
        self.scaffold_domain = scaffold_domain
        self.entity_id = entity_id
        self.identity_public_key = identity_public_key
        self.scaffold_admin_public_key = scaffold_admin_public_key
        self.bridge_descriptor_id = bridge_descriptor_id
        self.bridge_endpoint = bridge_endpoint
        self.client_kind = client_kind
        self.porthole_protocol = porthole_protocol
        self.capability_grants = capability_grants
        self.purpose = purpose
        self.goal = goal
        self.interests = interests
        self.issued_at = issued_at
        self.expires_at = expires_at
        self.issued_by = issued_by
        self.entity_evidence_contract_id = entity_evidence_contract_id
        self.declared_deposit_rau = declared_deposit_rau
        self.pricing_plan = pricing_plan
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
        let payload = try canonicalPayloadData()
        return Ed25519.verifyBase64URL(
            data: payload,
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

public struct PortholeAccessDecision: Codable, Equatable, Sendable {
    public var allowed: Bool
    public var contract: PortholeAccessContract?
    public var reason: String?

    public init(allowed: Bool, contract: PortholeAccessContract?, reason: String? = nil) {
        self.allowed = allowed
        self.contract = contract
        self.reason = reason
    }
}

public protocol SproutResolverAdapter: Sendable {
    func registerStarterAuth(payload: StarterAuthPayload) async throws -> ResolverRegistrationResult
    func requestCapabilities(_ request: CapabilityRequest) async throws -> CapabilityDecision
    func resolveEntity(_ request: EntityResolutionRequest) async throws -> EntityResolutionDecision
    func performMembershipChecks(identityPublicKey: String, domain: String) async throws -> MembershipDecision
    func issuePortholeAccessContract(_ request: PortholeAccessRequest) async throws -> PortholeAccessDecision
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
