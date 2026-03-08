import Foundation
import XCTest
@testable import SproutEconomics

private final class UUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        if values.isEmpty {
            return UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        }
        return values.removeFirst()
    }
}

final class EconomicsGoldenOutputTests: XCTestCase {
    private var rootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testRollupOutputMatchesGoldenFile() async throws {
        let deltas = try JSONDecoder.economics.decode(
            [CloudBridgeUsageDelta].self,
            from: Data(contentsOf: rootURL.appendingPathComponent("TestVectors/cloud_bridge_usage_deltas.example.json"))
        )
        let contract = try JSONDecoder.economics.decode(
            CloudBridgePricingContract.self,
            from: Data(contentsOf: rootURL.appendingPathComponent("TestVectors/cloud_bridge_pricing_contract.example.json"))
        )

        let ids = UUIDSequence([
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        ])
        let aggregator = CloudBridgeRollupAggregator(
            pricingContract: contract,
            entryIDProvider: { ids.next() }
        )

        for delta in deltas {
            _ = await aggregator.record(delta)
        }

        let entries = await aggregator.close()
        let encoded = try JSONEncoder.economicsPretty.encode(entries)
        let expected = try Data(contentsOf: rootURL.appendingPathComponent("TestVectors/cloud_bridge_rollup_entries.expected.json"))
        XCTAssertEqual(encoded, expected)
    }

    func testSessionRateSuggestionMatchesGoldenFile() throws {
        let records = try JSONDecoder.economics.decode(
            [CloudBridgeSessionRecord].self,
            from: Data(contentsOf: rootURL.appendingPathComponent("TestVectors/cloud_bridge_session_records.example.json"))
        )
        let calibration = try JSONDecoder.economics.decode(
            SessionRateCalibration.self,
            from: Data(contentsOf: rootURL.appendingPathComponent("TestVectors/cloud_bridge_session_rate_calibration.example.json"))
        )

        let suggestion = SessionRateEstimator.suggest(records: records, calibration: calibration)
        let encoded = try JSONEncoder.economicsPretty.encode(suggestion)
        let expected = try Data(contentsOf: rootURL.appendingPathComponent("TestVectors/cloud_bridge_session_rate_suggestion.expected.json"))

        XCTAssertEqual(encoded, expected)
    }
}
