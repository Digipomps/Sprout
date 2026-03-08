import XCTest
@testable import SproutEconomics

final class PricingCompilerTests: XCTestCase {
    func testCompileAllowsWhenDepositMeetsMinimum() {
        let contract = makeContract()
        let plan = CloudBridgePricingCompiler.compile(
            contract: contract,
            declaredDepositRAU: 500_000,
            requestedCapabilities: ["cap.join", "cap.discover"]
        )

        XCTAssertEqual(plan.outcome, .allow)
        XCTAssertEqual(plan.effective_capability_grants, ["cap.discover", "cap.join"])
    }

    func testCompileDegradesWhenUnderfundedAndPolicyAllowsIt() {
        var contract = makeContract()
        contract.underfunded_mode = .degrade
        contract.degraded_capability_grants = ["cap.discover"]

        let plan = CloudBridgePricingCompiler.compile(
            contract: contract,
            declaredDepositRAU: 10,
            requestedCapabilities: ["cap.join", "cap.discover"]
        )

        XCTAssertEqual(plan.outcome, .degrade)
        XCTAssertEqual(plan.effective_capability_grants, ["cap.discover"])
    }

    func testEstimateChargeAppliesHybridPricingAndRateCap() {
        var contract = makeContract()
        contract.max_rate_rau_per_minute = 10_000
        let usage = CloudBridgeSessionUsage(
            duration_milliseconds: 90_000,
            outbound_message_count: 5,
            inbound_message_count: 5,
            outbound_bytes: 2_048,
            inbound_bytes: 2_048,
            audit_event_count: 3
        )

        let charge = CloudBridgePricingCompiler.estimateCharge(contract: contract, usage: usage)

        XCTAssertEqual(charge.billed_minutes, 2)
        XCTAssertEqual(charge.billed_kilobytes, 4)
        XCTAssertEqual(charge.session_fee_rau, 6_000)
        XCTAssertEqual(charge.message_fee_rau, 100)
        XCTAssertEqual(charge.kilobyte_fee_rau, 80)
        XCTAssertEqual(charge.audit_fee_rau, 60)
        XCTAssertEqual(charge.max_billable_rau, 20_000)
        XCTAssertEqual(charge.capped_total_rau, 6_240)
    }

    func testAlwaysOnRequiresDOEscrow() {
        var contract = makeContract()
        contract.requires_always_on = true
        contract.do_duration_escrow_rau = 900_000

        let plan = CloudBridgePricingCompiler.compile(
            contract: contract,
            declaredDepositRAU: 100_000,
            requestedCapabilities: ["cap.join"]
        )

        XCTAssertEqual(plan.outcome, .deny)
        XCTAssertEqual(plan.required_deposit_rau, 1_400_000)
    }

    private func makeContract() -> CloudBridgePricingContract {
        CloudBridgePricingContract(
            contract_id: "cbc_0001",
            session_fee_per_minute_rau: 3_000,
            per_message_fee_rau: 10,
            per_kb_fee_rau: 20,
            audit_fee_per_event_rau: 20,
            min_deposit_rau: 500_000,
            max_rate_rau_per_minute: 100_000
        )
    }
}
