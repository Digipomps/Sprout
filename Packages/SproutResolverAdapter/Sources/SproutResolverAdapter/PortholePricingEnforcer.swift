import Foundation
import SproutEconomics

struct PortholePricingEnforcementResult {
    var effectiveCapabilityGrants: [String]
    var pricingPlan: CompiledCloudBridgePricingPlan?
    var denialReason: String?
}

enum PortholePricingEnforcer {
    static func evaluate(_ request: PortholeAccessRequest) -> PortholePricingEnforcementResult {
        guard let pricingContract = request.pricing_contract else {
            return PortholePricingEnforcementResult(
                effectiveCapabilityGrants: request.capability_grants.sorted(),
                pricingPlan: nil,
                denialReason: nil
            )
        }

        let compiled = CloudBridgePricingCompiler.compile(
            contract: pricingContract,
            declaredDepositRAU: max(request.declared_deposit_rau ?? 0, 0),
            requestedCapabilities: request.capability_grants.sorted()
        )

        switch compiled.outcome {
        case .allow, .degrade:
            return PortholePricingEnforcementResult(
                effectiveCapabilityGrants: compiled.effective_capability_grants.sorted(),
                pricingPlan: compiled,
                denialReason: nil
            )
        case .deny:
            return PortholePricingEnforcementResult(
                effectiveCapabilityGrants: [],
                pricingPlan: compiled,
                denialReason: compiled.reason ?? "pricing policy denied porthole access"
            )
        }
    }
}
