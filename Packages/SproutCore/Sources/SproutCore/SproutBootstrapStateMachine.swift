import Foundation
import SproutBridge
import SproutEconomics
import SproutStorage
import SproutResolverAdapter

public actor SproutBootstrapStateMachine {
    private let dependencies: SproutBootstrapDependencies
    private let bridgeManager: BridgeManager
    private let auditLog: AuditLogStore?
    private let now: @Sendable () -> Date

    private var state: SproutBootstrapState = .idle
    private var events: [BootstrapTransitionEvent] = []

    public init(
        dependencies: SproutBootstrapDependencies,
        bridgeManager: BridgeManager = .init(),
        auditLog: AuditLogStore? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.dependencies = dependencies
        self.bridgeManager = bridgeManager
        self.auditLog = auditLog
        self.now = now
    }

    public func run(initialContext: BootstrapExecutionContext) async -> BootstrapRunResult {
        var context = initialContext
        do {
            try ensureInitialContext(context)

            try await transition(to: .loadContext, detail: "load context")

            try await transition(to: .acquireIdentity, detail: "acquire identity")
            context.identity = try await dependencies.identityProvider(context)
            guard let identity = context.identity else {
                throw BootstrapError.missingIdentity
            }
            guard identity.domain == context.domain else {
                throw BootstrapError.wrongDomain(expected: context.domain, got: identity.domain)
            }

            try await transition(to: .collectPurposeInterest, detail: "collect purpose and interests")
            guard let purposeGoal = context.purposeGoal else {
                throw BootstrapError.missingPurposeGoal
            }
            guard purposeGoal.isExplicitlySet else {
                throw BootstrapError.missingPurposeInterest
            }

            try await transition(to: .probeEnvironment, detail: "probe environment")
            context.environmentReport = try await dependencies.environmentProbe(context)

            try await transition(to: .discoverBridges, detail: "discover bridge descriptors")
            try ensureExplicitPurposeGoal(context)
            context.discoveredBridges = try await dependencies.bridgeDiscovery(context)
            guard !context.discoveredBridges.isEmpty else {
                throw BootstrapError.missingBridgeRoute
            }

            let descriptorContext = BridgeDescriptorValidationContext(
                expectedDomain: context.domain,
                requiredPurpose: purposeGoal.purpose,
                now: now()
            )
            context.selectedBridge = try bridgeManager.chooseFirstUsable(
                descriptors: context.discoveredBridges,
                context: descriptorContext
            )
            guard let selectedBridge = context.selectedBridge else {
                throw BootstrapError.missingBridgeRoute
            }

            context.scaffoldAdminIdentity = try await dependencies.scaffoldAdminIdentityProvider(selectedBridge, context)
            guard let scaffoldAdminIdentity = context.scaffoldAdminIdentity else {
                throw BootstrapError.missingScaffoldAdminIdentity
            }
            guard
                scaffoldAdminIdentity.scaffold_domain == context.domain,
                !scaffoldAdminIdentity.admin_public_key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw BootstrapError.missingScaffoldAdminIdentity
            }
            try validateScaffoldTrust(
                selectedBridge: selectedBridge,
                scaffoldAdminIdentity: scaffoldAdminIdentity,
                trustRootDescriptor: context.scaffoldTrustRootDescriptor,
                domain: context.domain,
                now: now()
            )

            try await transition(to: .establishBridge, detail: "establish bridge transport")
            try ensureExplicitPurposeGoal(context)
            try await dependencies.bridgeConnector(selectedBridge, context)

            try await transition(to: .registerWithResolver, detail: "register starter auth with resolver")
            guard let starterAuthPayload = context.starterAuthPayload else {
                throw BootstrapError.invalidContext("starterAuthPayload missing")
            }
            guard starterAuthPayload.domain == context.domain else {
                throw BootstrapError.wrongDomain(expected: context.domain, got: starterAuthPayload.domain)
            }
            guard !starterAuthPayload.isExpired(now: now()) else {
                throw BootstrapError.expiredStarterAuthPayload
            }
            guard try starterAuthPayload.verifySignature() else {
                throw BootstrapError.invalidStarterAuthSignature
            }

            let registration = try await dependencies.resolver.registerStarterAuth(payload: starterAuthPayload)
            guard registration.accepted else {
                throw BootstrapError.resolverRejected(registration.reason ?? "registration rejected")
            }
            context.registrationResult = registration

            try await transition(to: .resolveEntity, detail: "resolve entity and verify entity-link evidence")
            try ensureExplicitPurposeGoal(context)
            context.entityLinkEvidence = try await dependencies.entityEvidenceProvider(context)
            context.entityAdmissionEvidence = try await dependencies.entityAdmissionEvidenceProvider(context)
            if context.entityLinkEvidence != nil, context.entityAdmissionEvidence != nil {
                throw BootstrapError.invalidContext("provide either entity-link evidence or entity admission evidence, not both")
            }
            if let evidence = context.entityLinkEvidence {
                guard evidence.contains(identityPublicKey: identity.identity_public_key) else {
                    throw BootstrapError.invalidEntityLinkEvidence("entity-link evidence does not include acquired identity")
                }
                guard try evidence.verify() else {
                    throw BootstrapError.invalidEntityLinkEvidence("entity-link mutual signatures did not verify")
                }
            }
            if let admissionEvidence = context.entityAdmissionEvidence {
                guard admissionEvidence.contains(identityPublicKey: identity.identity_public_key, domain: identity.domain) else {
                    throw BootstrapError.invalidEntityAdmissionEvidence("admission evidence does not include acquired identity and domain")
                }
                guard try admissionEvidence.verify(now: now()) else {
                    throw BootstrapError.invalidEntityAdmissionEvidence("admission contract or continuity proof did not verify")
                }
            }
            let evidenceSummary = try context.entityAdmissionEvidence?.resolverSummary() ?? context.entityLinkEvidence?.resolverSummary()
            let evidenceContractID = context.entityAdmissionEvidence?.contract.contract_id ?? context.entityLinkEvidence?.contract.contract_id
            let entityResolutionRequest = EntityResolutionRequest(
                identity_public_key: identity.identity_public_key,
                domain: context.domain,
                scaffold_admin_public_key: scaffoldAdminIdentity.admin_public_key,
                purpose: purposeGoal.purpose,
                goal: purposeGoal.goal,
                interests: purposeGoal.interests,
                evidence: evidenceSummary
            )
            context.entityResolution = try await dependencies.resolver.resolveEntity(entityResolutionRequest)
            try validateEntityResolution(
                context.entityResolution,
                identity: identity,
                scaffoldAdminIdentity: scaffoldAdminIdentity,
                domain: context.domain,
                evidenceContractID: evidenceContractID,
                now: now()
            )

            try await transition(to: .membershipChecks, detail: "perform membership checks and capability grants")
            let capabilityRequest = CapabilityRequest(
                identity_public_key: identity.identity_public_key,
                domain: context.domain,
                purpose: purposeGoal.purpose,
                required_capabilities: Array(
                    Set(selectedBridge.capability_requirements)
                        .union(context.requestedCapabilities)
                ).sorted(),
                entity_id: context.entityResolution?.entity_id,
                entity_inclusion_proof: context.entityResolution?.inclusion_proof
            )
            let capabilities = try await dependencies.resolver.requestCapabilities(capabilityRequest)
            context.capabilityDecision = capabilities
            if !capabilities.isAllowed {
                throw BootstrapError.capabilityDenied(capabilities.denied)
            }

            let membership = try await dependencies.resolver.performMembershipChecks(
                identityPublicKey: identity.identity_public_key,
                domain: context.domain
            )
            context.membershipDecision = membership
            if !membership.allowed {
                throw BootstrapError.membershipDenied(membership.reason ?? "membership denied")
            }

            try await transition(to: .issuePortholeAccess, detail: "issue resolver-enforced porthole access contract")
            guard let resolution = context.entityResolution else {
                throw BootstrapError.entityUnresolved("entity resolution missing")
            }
            guard resolution.isResolved, let entityID = resolution.entity_id else {
                throw BootstrapError.entityUnresolved(resolution.reason ?? "resolver did not return entity binding")
            }

            let accessRequest = PortholeAccessRequest(
                scaffold_domain: context.domain,
                entity_id: entityID,
                identity_public_key: identity.identity_public_key,
                scaffold_admin_public_key: scaffoldAdminIdentity.admin_public_key,
                bridge_descriptor_id: selectedBridge.descriptor_id,
                bridge_endpoint: selectedBridge.bridge_endpoint,
                client_kind: context.requestedPortholeKind,
                porthole_protocol: context.requestedPortholeKind.defaultProtocol,
                purpose: purposeGoal.purpose,
                goal: purposeGoal.goal,
                interests: purposeGoal.interests,
                capability_grants: capabilities.granted,
                entity_evidence_contract_id: evidenceContractID,
                entity_inclusion_proof: resolution.inclusion_proof,
                declared_deposit_rau: context.economics?.declared_deposit_rau,
                pricing_contract: context.economics?.pricing_contract
            )
            let portholeDecision = try await dependencies.resolver.issuePortholeAccessContract(accessRequest)
            guard portholeDecision.allowed else {
                throw BootstrapError.portholeAccessDenied(portholeDecision.reason ?? "resolver denied porthole access")
            }
            guard let contract = portholeDecision.contract else {
                throw BootstrapError.invalidPortholeAccessContract("resolver allowed porthole access but returned no contract")
            }
            try validatePortholeAccessContract(
                contract,
                against: accessRequest,
                grantedCapabilities: capabilities.granted,
                expectedResolverPublicKey: resolution.inclusion_proof?.issued_by,
                now: now()
            )
            context.portholeAccessContract = contract

            try await transition(to: .persistBootstrap, detail: "persist bootstrap state")
            do {
                try await dependencies.persistence(context)
            } catch {
                throw BootstrapError.persistenceFailure(String(describing: error))
            }

            try await transition(to: .done, detail: "bootstrap done")
            return BootstrapRunResult(
                finalState: .done,
                context: context,
                events: events,
                error: nil
            )
        } catch let error as BootstrapError {
            do {
                try await transition(to: .error, detail: "\(error)")
            } catch {
                // Preserve original bootstrap error.
            }
            return BootstrapRunResult(
                finalState: .error,
                context: context,
                events: events,
                error: error
            )
        } catch {
            do {
                try await transition(to: .error, detail: "\(error)")
            } catch {
                // Preserve original bootstrap error.
            }
            return BootstrapRunResult(
                finalState: .error,
                context: context,
                events: events,
                error: .underlying(String(describing: error))
            )
        }
    }

    public func currentState() -> SproutBootstrapState {
        state
    }

    public func replay(events: [BootstrapTransitionEvent]) throws -> SproutBootstrapState {
        var current: SproutBootstrapState = .idle
        for event in events {
            let allowed = Self.allowedTransitions[current] ?? []
            guard allowed.contains(event.to) else {
                throw BootstrapError.invalidStateTransition("\(current.rawValue) -> \(event.to.rawValue)")
            }
            current = event.to
        }
        return current
    }

    private func ensureInitialContext(_ context: BootstrapExecutionContext) throws {
        if context.domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BootstrapError.invalidContext("domain is required")
        }
    }

    private func ensureExplicitPurposeGoal(_ context: BootstrapExecutionContext) throws {
        guard let purposeGoal = context.purposeGoal, purposeGoal.isExplicitlySet else {
            throw BootstrapError.networkCallWithoutPurposeGoal
        }
    }

    private func validatePortholeAccessContract(
        _ contract: PortholeAccessContract,
        against request: PortholeAccessRequest,
        grantedCapabilities: [String],
        expectedResolverPublicKey: String?,
        now: Date
    ) throws {
        guard !contract.isExpired(now: now) else {
            throw BootstrapError.invalidPortholeAccessContract("returned contract is already expired")
        }
        guard try contract.verifySignature() else {
            throw BootstrapError.invalidPortholeAccessContract("returned contract signature is invalid")
        }
        guard contract.scaffold_domain == request.scaffold_domain else {
            throw BootstrapError.invalidPortholeAccessContract("contract scaffold_domain does not match request")
        }
        guard contract.entity_id == request.entity_id else {
            throw BootstrapError.invalidPortholeAccessContract("contract entity_id does not match resolved entity")
        }
        guard contract.identity_public_key == request.identity_public_key else {
            throw BootstrapError.invalidPortholeAccessContract("contract identity_public_key does not match request")
        }
        guard contract.scaffold_admin_public_key == request.scaffold_admin_public_key else {
            throw BootstrapError.invalidPortholeAccessContract("contract scaffold admin key does not match requested scaffold admin identity")
        }
        guard contract.bridge_descriptor_id == request.bridge_descriptor_id else {
            throw BootstrapError.invalidPortholeAccessContract("contract bridge_descriptor_id does not match selected bridge")
        }
        guard contract.bridge_endpoint == request.bridge_endpoint else {
            throw BootstrapError.invalidPortholeAccessContract("contract bridge_endpoint does not match selected bridge")
        }
        guard contract.client_kind == request.client_kind else {
            throw BootstrapError.invalidPortholeAccessContract("contract client_kind does not match request")
        }
        guard contract.porthole_protocol == request.porthole_protocol else {
            throw BootstrapError.invalidPortholeAccessContract("contract porthole_protocol does not match request")
        }
        guard contract.purpose == request.purpose, contract.goal == request.goal else {
            throw BootstrapError.invalidPortholeAccessContract("contract purpose/goal does not match request")
        }
        guard contract.interests.sorted() == request.interests.sorted() else {
            throw BootstrapError.invalidPortholeAccessContract("contract interests do not match request")
        }
        guard contract.entity_evidence_contract_id == request.entity_evidence_contract_id else {
            throw BootstrapError.invalidPortholeAccessContract("contract evidence reference does not match request")
        }
        guard contract.declared_deposit_rau == request.declared_deposit_rau else {
            throw BootstrapError.invalidPortholeAccessContract("contract declared deposit does not match request")
        }
        if let expectedResolverPublicKey, contract.issued_by != expectedResolverPublicKey {
            throw BootstrapError.invalidPortholeAccessContract("contract issuer does not match entity inclusion proof issuer")
        }

        if let requestPricingContract = request.pricing_contract {
            guard let pricingPlan = contract.pricing_plan else {
                throw BootstrapError.invalidPortholeAccessContract("contract pricing plan missing for priced request")
            }
            guard pricingPlan.contract_id == requestPricingContract.contract_id else {
                throw BootstrapError.invalidPortholeAccessContract("contract pricing plan does not reference requested pricing contract")
            }
            guard pricingPlan.declared_deposit_rau == max(request.declared_deposit_rau ?? 0, 0) else {
                throw BootstrapError.invalidPortholeAccessContract("contract pricing plan deposit does not match request")
            }
        } else if contract.pricing_plan != nil {
            throw BootstrapError.invalidPortholeAccessContract("unexpected pricing plan returned for unpriced request")
        }

        let grantedSet = Set(grantedCapabilities)
        let contractSet = Set(contract.capability_grants)
        guard contractSet.isSubset(of: grantedSet) else {
            throw BootstrapError.invalidPortholeAccessContract("contract capability grants exceed resolver capability decision")
        }
    }

    private func validateEntityResolution(
        _ decision: EntityResolutionDecision?,
        identity: BootstrapIdentity,
        scaffoldAdminIdentity: ScaffoldAdminIdentity,
        domain: String,
        evidenceContractID: String?,
        now: Date
    ) throws {
        guard let decision else {
            throw BootstrapError.entityUnresolved("entity resolution missing")
        }

        guard decision.status == .resolved else {
            throw BootstrapError.entityUnresolved(decision.reason ?? "resolver returned unresolved entity")
        }

        guard let entityID = decision.entity_id, !entityID.isEmpty else {
            throw BootstrapError.invalidEntityInclusionProof("resolver returned resolved status without entity_id")
        }

        guard let proof = decision.inclusion_proof else {
            throw BootstrapError.invalidEntityInclusionProof("resolver returned resolved status without inclusion proof")
        }
        if let resolvedBy = decision.resolved_by, resolvedBy != proof.issued_by {
            throw BootstrapError.invalidEntityInclusionProof("resolver decision issuer does not match inclusion proof issuer")
        }

        guard !proof.isExpired(now: now) else {
            throw BootstrapError.invalidEntityInclusionProof("entity inclusion proof is expired")
        }
        guard try proof.verifySignature() else {
            throw BootstrapError.invalidEntityInclusionProof("entity inclusion proof signature is invalid")
        }
        guard proof.entity_id == entityID else {
            throw BootstrapError.invalidEntityInclusionProof("entity inclusion proof entity_id does not match resolution")
        }
        guard proof.scaffold_domain == domain else {
            throw BootstrapError.invalidEntityInclusionProof("entity inclusion proof scaffold_domain does not match request")
        }
        guard proof.subject_identity_public_key == identity.identity_public_key else {
            throw BootstrapError.invalidEntityInclusionProof("entity inclusion proof subject identity does not match acquired identity")
        }
        guard proof.subject_domain == identity.domain else {
            throw BootstrapError.invalidEntityInclusionProof("entity inclusion proof subject domain does not match acquired identity")
        }
        guard proof.anchor_admin_public_key == scaffoldAdminIdentity.admin_public_key else {
            throw BootstrapError.invalidEntityInclusionProof("entity inclusion proof anchor admin key does not match scaffold admin identity")
        }
        guard proof.evidence_contract_id == evidenceContractID else {
            throw BootstrapError.invalidEntityInclusionProof("entity inclusion proof evidence contract id does not match request context")
        }
    }

    private func validateScaffoldTrust(
        selectedBridge: BridgeDescriptor,
        scaffoldAdminIdentity: ScaffoldAdminIdentity,
        trustRootDescriptor: ScaffoldAdminTrustRootDescriptor?,
        domain: String,
        now: Date
    ) throws {
        if let trustRootDescriptor {
            try ScaffoldAdminTrustRootDescriptorValidator().validate(
                descriptor: trustRootDescriptor,
                context: ScaffoldAdminTrustRootDescriptorValidationContext(expectedDomain: domain, now: now)
            )
            guard scaffoldAdminIdentity.admin_public_key == trustRootDescriptor.scaffold_admin_public_key else {
                throw BootstrapError.missingScaffoldAdminIdentity
            }
            guard trustRootDescriptor.trustsBridgeOwner(selectedBridge.owner_pubkey) else {
                throw BootstrapError.missingScaffoldAdminIdentity
            }
            return
        }

        guard scaffoldAdminIdentity.admin_public_key == selectedBridge.owner_pubkey else {
            throw BootstrapError.missingScaffoldAdminIdentity
        }
    }

    private func transition(to next: SproutBootstrapState, detail: String) async throws {
        let allowed = Self.allowedTransitions[state] ?? []
        guard allowed.contains(next) else {
            throw BootstrapError.invalidStateTransition("\(state.rawValue) -> \(next.rawValue)")
        }

        let event = BootstrapTransitionEvent(
            index: events.count,
            timestamp: now(),
            from: state,
            to: next,
            detail: detail
        )
        events.append(event)

        if let auditLog {
            let payload = Data("\(event.from.rawValue)->\(event.to.rawValue):\(detail)".utf8)
            try? await auditLog.append(
                eventType: "bootstrap.transition",
                state: next.rawValue,
                payload: payload,
                details: detail
            )
        }

        state = next
    }

    private static let allowedTransitions: [SproutBootstrapState: Set<SproutBootstrapState>] = [
        .idle: [.loadContext],
        .loadContext: [.acquireIdentity, .error],
        .acquireIdentity: [.collectPurposeInterest, .error],
        .collectPurposeInterest: [.probeEnvironment, .error],
        .probeEnvironment: [.discoverBridges, .error],
        .discoverBridges: [.establishBridge, .error],
        .establishBridge: [.registerWithResolver, .error],
        .registerWithResolver: [.resolveEntity, .error],
        .resolveEntity: [.membershipChecks, .error],
        .membershipChecks: [.issuePortholeAccess, .error],
        .issuePortholeAccess: [.persistBootstrap, .error],
        .persistBootstrap: [.done, .error],
        .done: [],
        .error: []
    ]
}
