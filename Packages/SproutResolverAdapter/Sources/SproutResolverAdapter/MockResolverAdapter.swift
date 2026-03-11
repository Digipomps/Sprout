import Foundation
import SproutCrypto

public enum MockResolverError: Error, Equatable, Sendable {
    case invalidSignature
    case expiredPayload
    case deniedDomain(String)
    case deniedMembership(String)
}

public struct MockResolverScenario: Sendable {
    public var allowedDomains: Set<String>
    public var deniedCapabilities: Set<String>
    public var membershipDeniedDomains: Set<String>
    public var entityBindings: [String: String]
    public var requireEntityEvidence: Bool
    public var allowedPortholeClientKinds: Set<PortholeClientKind>
    public var allowedPortholeProtocols: Set<PortholeProtocolKind>
    public var requireValidSignature: Bool
    public var requireFreshPayload: Bool
    public var resolverSigningSeedBase64URL: String

    public init(
        allowedDomains: Set<String>,
        deniedCapabilities: Set<String> = [],
        membershipDeniedDomains: Set<String> = [],
        entityBindings: [String: String] = [:],
        requireEntityEvidence: Bool = false,
        allowedPortholeClientKinds: Set<PortholeClientKind> = Set([.web, .cli, .native]),
        allowedPortholeProtocols: Set<PortholeProtocolKind> = Set([.web, .cli, .cellprotocol]),
        requireValidSignature: Bool = true,
        requireFreshPayload: Bool = true,
        resolverSigningSeedBase64URL: String = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    ) {
        self.allowedDomains = allowedDomains
        self.deniedCapabilities = deniedCapabilities
        self.membershipDeniedDomains = membershipDeniedDomains
        self.entityBindings = entityBindings
        self.requireEntityEvidence = requireEntityEvidence
        self.allowedPortholeClientKinds = allowedPortholeClientKinds
        self.allowedPortholeProtocols = allowedPortholeProtocols
        self.requireValidSignature = requireValidSignature
        self.requireFreshPayload = requireFreshPayload
        self.resolverSigningSeedBase64URL = resolverSigningSeedBase64URL
    }

    public static var permissive: MockResolverScenario {
        MockResolverScenario(allowedDomains: [])
    }
}

public actor MockResolverAdapter: SproutResolverAdapter {
    private let scenario: MockResolverScenario
    private let now: @Sendable () -> Date
    private let issuerPublicKeyBase64URL: String

    public init(
        scenario: MockResolverScenario,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.scenario = scenario
        self.now = now
        self.issuerPublicKeyBase64URL = (try? Ed25519.publicKeyBase64URL(fromSeedBase64URL: scenario.resolverSigningSeedBase64URL)) ?? ""
    }

    public func registerStarterAuth(payload: StarterAuthPayload) async throws -> ResolverRegistrationResult {
        if !scenario.allowedDomains.isEmpty && !scenario.allowedDomains.contains(payload.domain) {
            throw MockResolverError.deniedDomain(payload.domain)
        }

        if scenario.requireFreshPayload && payload.isExpired(now: now()) {
            throw MockResolverError.expiredPayload
        }

        if scenario.requireValidSignature {
            let isValid = try payload.verifySignature()
            if !isValid {
                throw MockResolverError.invalidSignature
            }
        }

        return ResolverRegistrationResult(
            accepted: true,
            registration_id: "reg_\(payload.domain)_\(payload.identity_public_key.prefix(12))",
            reason: nil
        )
    }

    public func requestCapabilities(_ request: CapabilityRequest) async throws -> CapabilityDecision {
        if !scenario.allowedDomains.isEmpty && !scenario.allowedDomains.contains(request.domain) {
            throw MockResolverError.deniedDomain(request.domain)
        }

        let denied = request.required_capabilities.filter { scenario.deniedCapabilities.contains($0) }
        let granted = request.required_capabilities.filter { !scenario.deniedCapabilities.contains($0) }
        return CapabilityDecision(granted: granted, denied: denied)
    }

    public func resolveEntity(_ request: EntityResolutionRequest) async throws -> EntityResolutionDecision {
        if !scenario.allowedDomains.isEmpty && !scenario.allowedDomains.contains(request.domain) {
            throw MockResolverError.deniedDomain(request.domain)
        }

        if scenario.requireEntityEvidence {
            guard let evidence = request.evidence else {
                return unresolvedDecision(
                    contractID: nil,
                    reason: "resolver policy requires explicit entity-link evidence"
                )
            }
            guard evidence.linked_public_keys.contains(request.identity_public_key) else {
                return unresolvedDecision(
                    contractID: evidence.contract_id,
                    reason: "entity-link evidence does not bind requested identity"
                )
            }
        }

        if let evidence = request.evidence,
           evidence.evidence_type == "cross_scaffold_admission_contract" {
            guard evidence.target_scaffold_domain == request.domain else {
                return unresolvedDecision(
                    contractID: evidence.contract_id,
                    reason: "admission contract target scaffold does not match requested scaffold"
                )
            }
            guard let entityID = evidence.target_entity_id, !entityID.isEmpty else {
                return unresolvedDecision(
                    contractID: evidence.contract_id,
                    reason: "admission contract did not name a target entity"
                )
            }
            guard evidence.linked_public_keys.contains(request.identity_public_key) else {
                return unresolvedDecision(
                    contractID: evidence.contract_id,
                    reason: "admission contract does not bind requested identity"
                )
            }
            return try resolvedDecision(
                entityID: entityID,
                request: request,
                contractID: evidence.contract_id
            )
        }

        if let entityID = scenario.entityBindings[request.identity_public_key] {
            return try resolvedDecision(
                entityID: entityID,
                request: request,
                contractID: request.evidence?.contract_id
            )
        }

        if let evidence = request.evidence {
            let relatedEntityIDs = evidence.linked_public_keys.compactMap { scenario.entityBindings[$0] }
            let distinctEntityIDs = Set(relatedEntityIDs)
            if distinctEntityIDs.count == 1, let entityID = distinctEntityIDs.first {
                if evidence.linked_public_keys.contains(request.identity_public_key) {
                    return try resolvedDecision(
                        entityID: entityID,
                        request: request,
                        contractID: evidence.contract_id
                    )
                }
            } else if distinctEntityIDs.count > 1 {
                return unresolvedDecision(
                    contractID: evidence.contract_id,
                    reason: "entity-link evidence spans identities bound to different entities"
                )
            }
        }

        return unresolvedDecision(
            contractID: request.evidence?.contract_id,
            reason: "no explicit entity binding found for identity"
        )
    }

    public func performMembershipChecks(identityPublicKey: String, domain: String) async throws -> MembershipDecision {
        _ = identityPublicKey

        if !scenario.allowedDomains.isEmpty && !scenario.allowedDomains.contains(domain) {
            throw MockResolverError.deniedDomain(domain)
        }

        if scenario.membershipDeniedDomains.contains(domain) {
            return MembershipDecision(allowed: false, reason: "membership denied by mock policy")
        }

        return MembershipDecision(allowed: true)
    }

    public func issuePortholeAccessContract(_ request: PortholeAccessRequest) async throws -> PortholeAccessDecision {
        if !scenario.allowedDomains.isEmpty && !scenario.allowedDomains.contains(request.scaffold_domain) {
            throw MockResolverError.deniedDomain(request.scaffold_domain)
        }

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

    private func resolvedDecision(
        entityID: String,
        request: EntityResolutionRequest,
        contractID: String?
    ) throws -> EntityResolutionDecision {
        let proof = try issueInclusionProof(
            entityID: entityID,
            request: request,
            contractID: contractID
        )
        return EntityResolutionDecision(
            status: .resolved,
            entity_id: entityID,
            inclusion_proof: proof,
            resolved_by: issuerPublicKeyBase64URL,
            resolved_at: iso8601String(now()),
            evidence_contract_id: contractID,
            reason: nil
        )
    }

    private func unresolvedDecision(contractID: String?, reason: String) -> EntityResolutionDecision {
        EntityResolutionDecision(
            status: .unresolved,
            entity_id: nil,
            inclusion_proof: nil,
            resolved_by: issuerPublicKeyBase64URL,
            resolved_at: iso8601String(now()),
            evidence_contract_id: contractID,
            reason: reason
        )
    }

    private func issueInclusionProof(
        entityID: String,
        request: EntityResolutionRequest,
        contractID: String?
    ) throws -> EntityInclusionProof {
        let issuedAt = now()
        let issuedAtString = iso8601String(issuedAt)
        let expiresAtString = iso8601String(issuedAt.addingTimeInterval(300))
        let proofSeed = [
            request.domain,
            entityID,
            request.identity_public_key,
            contractID ?? "none"
        ].joined(separator: "|")
        let proofID = "eip_\(Hashing.sha256Base64URL(Data(proofSeed.utf8)).prefix(16))"

        var proof = EntityInclusionProof(
            proof_id: proofID,
            scaffold_domain: request.domain,
            entity_id: entityID,
            subject_identity_public_key: request.identity_public_key,
            subject_domain: request.domain,
            anchor_snapshot_id: "mock-anchor-\(request.domain)",
            anchor_snapshot_sha256_b64url: Hashing.sha256Base64URL(Data("mock-anchor|\(request.domain)|\(entityID)".utf8)),
            anchor_admin_public_key: request.scaffold_admin_public_key,
            evidence_contract_id: contractID,
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
