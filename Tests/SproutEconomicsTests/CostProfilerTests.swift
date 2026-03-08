import Foundation
import XCTest
@testable import SproutEconomics

private final class SnapshotSource: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [ProcessResourceSnapshot]

    init(_ snapshots: [ProcessResourceSnapshot]) {
        self.snapshots = snapshots
    }

    func next() throws -> ProcessResourceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !snapshots.isEmpty else {
            throw ProfilerError.snapshotUnavailable("no snapshot")
        }
        return snapshots.removeFirst()
    }
}

final class CostProfilerTests: XCTestCase {
    func testProfilerProducesSessionRecordAndSuggestion() async throws {
        let source = SnapshotSource([
            ProcessResourceSnapshot(
                captured_at: Date(timeIntervalSince1970: 0),
                thread_count: 10,
                resident_memory_bytes: 100_000_000,
                heap_bytes: 50_000_000,
                user_cpu_microseconds: 1_000,
                system_cpu_microseconds: 500
            ),
            ProcessResourceSnapshot(
                captured_at: Date(timeIntervalSince1970: 65),
                thread_count: 12,
                resident_memory_bytes: 130_000_000,
                heap_bytes: 60_000_000,
                user_cpu_microseconds: 60_000,
                system_cpu_microseconds: 20_000
            )
        ])

        let profiler = CloudBridgeCostProfiler(snapshotProvider: {
            try source.next()
        })
        let sessionID = try await profiler.startSession(endpoint: URL(string: "wss://bridge.example/cell")!, counterpartyID: "bridge.example")
        try await profiler.recordOutboundMessage(sessionID: sessionID, bytes: 120)
        try await profiler.recordInboundMessage(sessionID: sessionID, bytes: 80)
        try await profiler.recordAuditEvent(sessionID: sessionID)
        let record = try await profiler.finishSession(sessionID: sessionID)

        XCTAssertEqual(record.thread_delta, 2)
        XCTAssertEqual(record.rss_delta_bytes, 30_000_000)
        XCTAssertEqual(record.heap_delta_bytes, 10_000_000)
        XCTAssertEqual(record.total_messages, 2)
        XCTAssertEqual(record.audit_event_count, 1)

        let suggestion = await profiler.suggestSessionMinuteRate(
            calibration: SessionRateCalibration(
                rau_per_thread_minute: 1_000,
                rau_per_gib_minute: 10_000,
                rau_per_cpu_second: 100,
                rau_per_message: 10,
                rau_per_audit_event: 50,
                target_margin_bps: 2_000
            )
        )

        XCTAssertEqual(suggestion.observed_session_count, 1)
        XCTAssertGreaterThan(suggestion.suggested_session_fee_per_minute_rau, 0)
    }
}
