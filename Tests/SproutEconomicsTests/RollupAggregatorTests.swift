import Foundation
import XCTest
@testable import SproutEconomics

final class RollupAggregatorTests: XCTestCase {
    func testRollupAggregatesPerCellCounterpartyMinute() async throws {
        let contract = CloudBridgePricingContract(
            contract_id: "cbc_rollup",
            session_fee_per_minute_rau: 1_000,
            per_message_fee_rau: 10,
            per_kb_fee_rau: 100,
            audit_fee_per_event_rau: 50,
            min_deposit_rau: 0,
            max_rate_rau_per_minute: 100_000
        )
        let aggregator = CloudBridgeRollupAggregator(pricingContract: contract)
        let timestamp = ISO8601DateFormatter().date(from: "2026-03-08T14:00:10Z")!

        let firstFlush = await aggregator.record(
            CloudBridgeUsageDelta(
                wallet_id: "wallet_1",
                cell_id: "cell.alpha",
                counterparty_id: "bridge.example",
                timestamp: timestamp,
                message_count: 2,
                byte_count: 900,
                audit_event_count: 1,
                session_milliseconds: 20_000
            )
        )
        XCTAssertEqual(firstFlush.count, 0)

        let secondFlush = await aggregator.record(
            CloudBridgeUsageDelta(
                wallet_id: "wallet_1",
                cell_id: "cell.alpha",
                counterparty_id: "bridge.example",
                timestamp: timestamp.addingTimeInterval(15),
                message_count: 3,
                byte_count: 500,
                audit_event_count: 1,
                session_milliseconds: 15_000
            )
        )
        XCTAssertEqual(secondFlush.count, 0)

        let entries = await aggregator.close()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entry.message_count, 5)
        XCTAssertEqual(entry.byte_count, 1_400)
        XCTAssertEqual(entry.audit_event_count, 2)
        XCTAssertEqual(entry.kind, .rollup)
        XCTAssertEqual(entry.amount_rau, 1_350)
    }
}
