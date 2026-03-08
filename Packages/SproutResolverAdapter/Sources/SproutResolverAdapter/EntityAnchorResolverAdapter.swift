import Foundation
import SproutCrypto

public enum EntityAnchorResolverError: Error, Equatable, Sendable {
    case invalidAnchorSignature
    case expiredAnchorSnapshot
    case wrongAnchorDomain(expected: String, actual: String)
    case deniedDomain(String)
}

public struct EntityAnchorResolverScenario: Sendable {
    public var allowedDomains: Set<String>
    public var deniedCapabilities: Set<String>
    public var membershipDeniedDomains: Set<String>
    public var allowedPortholeClientKinds: Set<PortholeClientKind>
    public var allowedPortholeProtocols: Set<PortholeProtocolKind>
    public var requireValidSignature: Bool
    public var requireFreshPayload: Bool
    public var requireEntityEvidenceForLinkedMembership: Bool
    public var resolverSigningSeedBase64URL: String

    public init(
        allowedDomains: Set<String>,
        deniedCapabilities: Set<String> = [],
        membershipDeniedDomains: Set<String> = [],
        allowedPortholeClientKinds: Set<PortholeClientKind> = Set([.web, .cli, .native]),
        allowedPortholeProtocols: Set<PortholeProtocolKind> = Set([.web, .cli, .cellprotocol]),
        requireValidSignature: Bool = true,
        requireFreshPayload: Bool = true,
        requireEntityEvidenceForLinkedMembership: Bool = true,
        resolverSigningSeedBase64URL: String = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    ) {
        self.allowedDomains = allowedDomains
        self.deniedCapabilities = deniedCapabilities
        self.membershipDeniedDomains = membershipDeniedDomains
        self.allowedPortholeClientKinds = allowedPortholeClientKinds
        self.allowedPortholeProtocols = allowedPortholeProtocols
        self.requireValidSignature = requireValidSignature
        self.requireFreshPayload = requireFreshPayload
        self.requireEntityEvidenceForLinkedMembership = requireEntityEvidenceForLinkedMembership
        self.resolverSigningSeedBase64URL = resolverSigningSeedBase64URL
    }
}

public actor EntityAnchorResolverAdapter: SproutResolverAdapter {
    private let anchorSnapshot: EntityAnchorSnapshot
    private let scenario: EntityAnchorResolverScenario
    private let now: @Sendable () -> Date
    private let issuerPublicKeyBase64URL: String

    public init(
        anchorSnapshot: EntityAnchorSnapshot,
        scenario: EntityAnchorResolverScenario,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.anchorSnapshot = anchorSnapshot
        self.scenario = scenario
        self.now = now
        self.issuerPublicKeyBase64URL = (try? Ed25519.publicKeyBase64URL(fromSeedBase64URL: scenario.resolverSigningSeedBase64URL)) ?? ""
    }

    public func registerStarterAuth(payload: StarterAuthPayload) async throws -> ResolverRegistrationResult {
        try validateDomain(payload.domain)

        if scenario.requireFreshPayload && payload.isExpired(now: now()) {
            throw EntityAnchorResolverError.expiredAnchorSnapshot
        }

        if scenario.requireValidSignature {
            let isValid = try payload.verifySignature()
            if !isValid {
                throw EntityAnchorResolverError.invalidAnchorSignature
            }
        }

        return ResolverRegistrationResult(
            accepted: true,
            registration_id: "reg_\(payload.domain)_\(payload.identity_public_key.prefix(12))",
            reason: nil
        )
    }

    public func requestCapabilities(_ request: CapabilityRequest) async throws -> CapabilityDecision {
        try validateDomain(request.domain)

        let denied = request.required_capabilities.filter { scenario.deniedCapabilities.contains($0) }
        let granted = request.required_capabilities.filter { !scenario.deniedCapabilities.contains($0) }
        return CapabilityDecision(granted: granted, denied: denied)
    }

    public func resolveEntity(_ request: EntityResolutionRequest) async throws -> EntityResolutionDecision {
        try validateAnchor(for: request.domain)
        guard anchorSnapshot.admin_public_key == request.scaffold_admin_public_key else {
            return EntityResolutionDecision(
                status: .unresolved,
                entity_id: nil,
                inclusion_proof: nil,
                resolved_by: issuerPublicKeyBase64URL,
                resolved_at: iso8601String(now()),
                evidence_contract_id: request.evidence?.contract_id,
                reason: "entity anchor admin key does not match scaffold admin identity"
            )
        }

        if let record = anchorSnapshot.entityRecord(containingIdentity: request.identity_public_key, domain: request.domain) {
            let proof = try issueInclusionProof(
                entityID: record.entity_id,
                subjectIdentityPublicKey: request.identity_public_key,
                subjectDomain: request.domain,
                evidenceContractID: request.evidence?.contract_id
            )
            return EntityResolutionDecision(
                status: .resolved,
                entity_id: record.entity_id,
                inclusion_proof: proof,
                resolved_by: issuerPublicKeyBase64URL,
                resolved_at: iso8601String(now()),
                evidence_contract_id: request.evidence?.contract_id
            )
        }

        guard let evidence = request.evidence else {
            return EntityResolutionDecision(
                status: .unresolved,
                entity_id: nil,
                inclusion_proof: nil,
                resolved_by: issuerPublicKeyBase64URL,
                resolved_at: iso8601String(now()),
                evidence_contract_id: nil,
                reason: "identity is not present in entity anchor and no inclusion evidence was supplied"
            )
        }

        guard !scenario.requireEntityEvidenceForLinkedMembership || evidence.contract_id != nil else {
            return EntityResolutionDecision(
                status: .unresolved,
                entity_id: nil,
                inclusion_proof: nil,
                resolved_by: issuerPublicKeyBase64URL,
                resolved_at: iso8601String(now()),
                evidence_contract_id: evidence.contract_id,
                reason: "linked membership requires an accepted entity-link contract id"
            )
        }

        if let record = anchorSnapshot.entityRecordAcceptingEvidence(
            evidence,
            subjectIdentityPublicKey: request.identity_public_key
        ) {
            let proof = try issueInclusionProof(
                entityID: record.entity_id,
                subjectIdentityPublicKey: request.identity_public_key,
                subjectDomain: request.domain,
                evidenceContractID: evidence.contract_id
            )
            return EntityResolutionDecision(
                status: .resolved,
                entity_id: record.entity_id,
                inclusion_proof: proof,
                resolved_by: issuerPublicKeyBase64URL,
                resolved_at: iso8601String(now()),
                evidence_contract_id: evidence.contract_id
            )
        }

        return EntityResolutionDecision(
            status: .unresolved,
            entity_id: nil,
            inclusion_proof: nil,
            resolved_by: issuerPublicKeyBase64URL,
            resolved_at: iso8601String(now()),
            evidence_contract_id: evidence.contract_id,
            reason: "entity anchor did not accept the supplied inclusion evidence for this identity"
        )
    }

    public func performMembershipChecks(identityPublicKey: String, domain: String) async throws -> MembershipDecision {
        _ = identityPublicKey
        try validateDomain(domain)

        if scenario.membershipDeniedDomains.contains(domain) {
            return MembershipDecision(allowed: false, reason: "membership denied by resolver policy")
        }

        return MembershipDecision(allowed: true)
    }

    public func issuePortholeAccessContract(_ request: PortholeAccessRequest) async throws -> PortholeAccessDecision {
        try validateDomain(request.scaffold_domain)

        guard scenario.allowedPortholeClientKinds.contains(request.client_kind) else {
            return PortholeAccessDecision(
                allowed: false,
                contract: nil,
                reason: "client kind \(request.client_kind.rawValue) is not allowed by policy"
            )
        }

        guard scenario.allowedPortholeProtocols.contains(request.porthole_protocol) else {
            return PortholeAccessDecision(
                allowed: false,
                contract: nil,
                reason: "porthole protocol \(request.porthole_protocol.rawValue) is not allowed by policy"
            )
        }

        guard let entityID = request.entity_id, !entityID.isEmpty else {
            return PortholeAccessDecision(
                allowed: false,
                contract: nil,
                reason: "entity must be explicitly resolved before issuing porthole access"
            )
        }

        guard
            !request.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !request.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !request.interests.isEmpty
        else {
            return PortholeAccessDecision(
                allowed: false,
                contract: nil,
                reason: "purpose, goal and interests must be explicit"
            )
        }

        let pricingEnforcement = PortholePricingEnforcer.evaluate(request)
        if let denialReason = pricingEnforcement.denialReason {
            return PortholeAccessDecision(
                allowed: false,
                contract: nil,
                reason: denialReason
            )
        }

        let issuedAt = now()
        let issuedAtString = iso8601String(issuedAt)
        let expiresAtString = iso8601String(issuedAt.addingTimeInterval(300))
        let contractID = "pac_\(Hashing.sha256Base64URL(Data(contractSeed(request).utf8)).prefix(16))"

        var contract = PortholeAccessContract(
            contract_id: contractID,
            scaffold_domain: request.scaffold_domain,
            entity_id: entityID,
            identity_public_key: request.identity_public_key,
            scaffold_admin_public_key: request.scaffold_admin_public_key,
            bridge_descriptor_id: request.bridge_descriptor_id,
            bridge_endpoint: request.bridge_endpoint,
            client_kind: request.client_kind,
            porthole_protocol: request.porthole_protocol,
            capability_grants: pricingEnforcement.effectiveCapabilityGrants.sorted(),
            purpose: request.purpose,
            goal: request.goal,
            interests: request.interests.sorted(),
            issued_at: issuedAtString,
            expires_at: expiresAtString,
            issued_by: issuerPublicKeyBase64URL,
            entity_evidence_contract_id: request.entity_evidence_contract_id,
            declared_deposit_rau: request.declared_deposit_rau,
            pricing_plan: pricingEnforcement.pricingPlan,
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )

        let signature = try Ed25519.signBase64URL(
            data: try contract.canonicalPayloadData(),
            seedBase64URL: scenario.resolverSigningSeedBase64URL
        )
        contract.signature = ResolverSignatureEnvelope(alg: "Ed25519", sig: signature)
        return PortholeAccessDecision(allowed: true, contract: contract)
    }

    private func issueInclusionProof(
        entityID: String,
        subjectIdentityPublicKey: String,
        subjectDomain: String,
        evidenceContractID: String?
    ) throws -> EntityInclusionProof {
        let issuedAt = now()
        let issuedAtString = iso8601String(issuedAt)
        let expiresAtString = iso8601String(issuedAt.addingTimeInterval(300))
        let proofSeed = [
            anchorSnapshot.snapshot_id,
            entityID,
            subjectIdentityPublicKey,
            evidenceContractID ?? "none"
        ].joined(separator: "|")
        let proofID = "eip_\(Hashing.sha256Base64URL(Data(proofSeed.utf8)).prefix(16))"

        var proof = EntityInclusionProof(
            proof_id: proofID,
            scaffold_domain: anchorSnapshot.scaffold_domain,
            entity_id: entityID,
            subject_identity_public_key: subjectIdentityPublicKey,
            subject_domain: subjectDomain,
            anchor_snapshot_id: anchorSnapshot.snapshot_id,
            anchor_snapshot_sha256_b64url: try anchorSnapshot.payloadHashBase64URL(),
            anchor_admin_public_key: anchorSnapshot.admin_public_key,
            evidence_contract_id: evidenceContractID,
            issued_at: issuedAtString,
            expires_at: expiresAtString,
            issued_by: issuerPublicKeyBase64URL,
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )
        let signature = try Ed25519.signBase64URL(
            data: try proof.canonicalPayloadData(),
            seedBase64URL: scenario.resolverSigningSeedBase64URL
        )
        proof.signature = ResolverSignatureEnvelope(alg: "Ed25519", sig: signature)
        return proof
    }

    private func validateAnchor(for expectedDomain: String) throws {
        try validateDomain(expectedDomain)
        guard anchorSnapshot.scaffold_domain == expectedDomain else {
            throw EntityAnchorResolverError.wrongAnchorDomain(
                expected: expectedDomain,
                actual: anchorSnapshot.scaffold_domain
            )
        }
        guard !anchorSnapshot.isExpired(now: now()) else {
            throw EntityAnchorResolverError.expiredAnchorSnapshot
        }
        guard try anchorSnapshot.verifySignature() else {
            throw EntityAnchorResolverError.invalidAnchorSignature
        }
    }

    private func validateDomain(_ domain: String) throws {
        if !scenario.allowedDomains.isEmpty && !scenario.allowedDomains.contains(domain) {
            throw EntityAnchorResolverError.deniedDomain(domain)
        }
    }

    private func contractSeed(_ request: PortholeAccessRequest) -> String {
        [
            request.scaffold_domain,
            request.entity_id ?? "unresolved",
            request.identity_public_key,
            request.scaffold_admin_public_key,
            request.bridge_descriptor_id,
            request.porthole_protocol.rawValue,
            request.client_kind.rawValue,
            request.purpose
        ].joined(separator: "|")
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
