import Foundation
import XCTest
@testable import SproutEconomics
@testable import SproutResolverAdapter

final class ResolverPricingEnforcementTests: XCTestCase {
    func testMockResolverDeniesWhenDepositIsBelowMinimum() async throws {
        let resolver = MockResolverAdapter(
            scenario: MockResolverScenario(allowedDomains: ["example.haven.local"]),
            now: { ISO8601DateFormatter().date(from: "2026-03-08T14:00:00Z")! }
        )

        let request = PortholeAccessRequest(
            scaffold_domain: "example.haven.local",
            entity_id: "entity_1",
            identity_public_key: "pub_1",
            scaffold_admin_public_key: "admin_1",
            bridge_descriptor_id: "bd_1",
            bridge_endpoint: "wss://bridge.example.haven.local/cell",
            client_kind: .cli,
            porthole_protocol: .cli,
            purpose: "bootstrap.join_scaffold",
            goal: "Join scaffold and register identity",
            interests: ["haven.core.bootstrap"],
            capability_grants: ["cap.join"],
            entity_evidence_contract_id: nil,
            declared_deposit_rau: 10,
            pricing_contract: CloudBridgePricingContract(
                contract_id: "cbc_test",
                session_fee_per_minute_rau: 100,
                per_message_fee_rau: 1,
                per_kb_fee_rau: 1,
                audit_fee_per_event_rau: 1,
                min_deposit_rau: 100_000,
                max_rate_rau_per_minute: 10_000
            )
        )

        let decision = try await resolver.issuePortholeAccessContract(request)
        XCTAssertFalse(decision.allowed)
        XCTAssertNil(decision.contract)
        XCTAssertTrue(decision.reason?.contains("minimum") == true)
    }

    func testMockResolverDegradesCapabilitiesWhenUnderfundedPolicyAllowsIt() async throws {
        let resolver = MockResolverAdapter(
            scenario: MockResolverScenario(allowedDomains: ["example.haven.local"]),
            now: { ISO8601DateFormatter().date(from: "2026-03-08T14:00:00Z")! }
        )

        let request = PortholeAccessRequest(
            scaffold_domain: "example.haven.local",
            entity_id: "entity_1",
            identity_public_key: "pub_1",
            scaffold_admin_public_key: "admin_1",
            bridge_descriptor_id: "bd_1",
            bridge_endpoint: "wss://bridge.example.haven.local/cell",
            client_kind: .cli,
            porthole_protocol: .cli,
            purpose: "bootstrap.join_scaffold",
            goal: "Join scaffold and register identity",
            interests: ["haven.core.bootstrap"],
            capability_grants: ["cap.join", "cap.discover"],
            entity_evidence_contract_id: nil,
            declared_deposit_rau: 10,
            pricing_contract: CloudBridgePricingContract(
                contract_id: "cbc_test",
                session_fee_per_minute_rau: 100,
                per_message_fee_rau: 1,
                per_kb_fee_rau: 1,
                audit_fee_per_event_rau: 1,
                min_deposit_rau: 100_000,
                max_rate_rau_per_minute: 10_000,
                underfunded_mode: .degrade,
                degraded_capability_grants: ["cap.discover"]
            )
        )

        let decision = try await resolver.issuePortholeAccessContract(request)
        let contract = try XCTUnwrap(decision.contract)
        XCTAssertTrue(decision.allowed)
        XCTAssertEqual(contract.capability_grants, ["cap.discover"])
        XCTAssertEqual(contract.pricing_plan?.outcome, .degrade)
    }
}
