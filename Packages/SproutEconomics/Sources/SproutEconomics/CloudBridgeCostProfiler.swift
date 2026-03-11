import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import SproutTransport

public struct ProcessResourceSnapshot: Codable, Equatable, Sendable {
    public var captured_at: Date
    public var thread_count: Int
    public var resident_memory_bytes: UInt64
    public var heap_bytes: UInt64?
    public var user_cpu_microseconds: UInt64
    public var system_cpu_microseconds: UInt64

    public init(
        captured_at: Date,
        thread_count: Int,
        resident_memory_bytes: UInt64,
        heap_bytes: UInt64?,
        user_cpu_microseconds: UInt64,
        system_cpu_microseconds: UInt64
    ) {
        self.captured_at = captured_at
        self.thread_count = thread_count
        self.resident_memory_bytes = resident_memory_bytes
        self.heap_bytes = heap_bytes
        self.user_cpu_microseconds = user_cpu_microseconds
        self.system_cpu_microseconds = system_cpu_microseconds
    }
}

public enum ProcessResourceSampler {
    public static func capture(now: Date = Date()) throws -> ProcessResourceSnapshot {
        let cpu = cpuUsage()
        #if canImport(Darwin)
        let memory = try darwinMemoryUsage()
        let threads = try darwinThreadCount()
        let heap = darwinHeapBytes()
        return ProcessResourceSnapshot(
            captured_at: now,
            thread_count: threads,
            resident_memory_bytes: memory,
            heap_bytes: heap,
            user_cpu_microseconds: cpu.user,
            system_cpu_microseconds: cpu.system
        )
        #else
        let status = try linuxStatusMetrics()
        return ProcessResourceSnapshot(
            captured_at: now,
            thread_count: status.threads,
            resident_memory_bytes: status.rssBytes,
            heap_bytes: status.heapBytes,
            user_cpu_microseconds: cpu.user,
            system_cpu_microseconds: cpu.system
        )
        #endif
    }

    private static func cpuUsage() -> (user: UInt64, system: UInt64) {
        var usage = rusage()
        #if canImport(Darwin)
        getrusage(RUSAGE_SELF, &usage)
        #elseif canImport(Glibc)
        getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage)
        #endif
        let user = UInt64(usage.ru_utime.tv_sec) * 1_000_000 + UInt64(usage.ru_utime.tv_usec)
        let system = UInt64(usage.ru_stime.tv_sec) * 1_000_000 + UInt64(usage.ru_stime.tv_usec)
        return (user, system)
    }

    #if canImport(Darwin)
    private static func darwinMemoryUsage() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw ProfilerError.snapshotUnavailable("mach_task_basic_info unavailable")
        }
        return UInt64(info.resident_size)
    }

    private static func darwinThreadCount() throws -> Int {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS else {
            throw ProfilerError.snapshotUnavailable("task_threads unavailable")
        }
        if let threadList {
            let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threadList), size)
        }
        return Int(threadCount)
    }

    private static func darwinHeapBytes() -> UInt64? {
        guard let zone = malloc_default_zone() else {
            return nil
        }
        var stats = malloc_statistics_t()
        malloc_zone_statistics(zone, &stats)
        return UInt64(stats.size_in_use)
    }
    #else
    private static func linuxStatusMetrics() throws -> (rssBytes: UInt64, heapBytes: UInt64?, threads: Int) {
        let status = try String(contentsOfFile: "/proc/self/status", encoding: .utf8)
        var rssBytes: UInt64 = 0
        var heapBytes: UInt64?
        var threads = 0

        for line in status.split(separator: "\n") {
            if line.hasPrefix("VmRSS:") {
                rssBytes = parseKilobyteLine(line) * 1_024
            } else if line.hasPrefix("VmData:") {
                heapBytes = parseKilobyteLine(line) * 1_024
            } else if line.hasPrefix("Threads:") {
                threads = Int(line.split(whereSeparator: \.isWhitespace).last ?? "0") ?? 0
            }
        }

        return (rssBytes, heapBytes, threads)
    }

    private static func parseKilobyteLine<S: StringProtocol>(_ line: S) -> UInt64 {
        UInt64(line.split(whereSeparator: \.isWhitespace).dropFirst().first ?? "0") ?? 0
    }
    #endif
}

public enum ProfilerError: Error, Equatable, Sendable {
    case sessionNotFound(UUID)
    case snapshotUnavailable(String)
}

public struct CloudBridgeSessionRecord: Codable, Equatable, Sendable {
    public var session_id: UUID
    public var endpoint: String
    public var counterparty_id: String
    public var started_at: Date
    public var ended_at: Date
    public var duration_milliseconds: Int64
    public var outbound_message_count: Int64
    public var inbound_message_count: Int64
    public var outbound_bytes: Int64
    public var inbound_bytes: Int64
    public var audit_event_count: Int64
    public var thread_delta: Int
    public var rss_delta_bytes: Int64
    public var heap_delta_bytes: Int64?
    public var user_cpu_microseconds_delta: UInt64
    public var system_cpu_microseconds_delta: UInt64

    public init(
        session_id: UUID,
        endpoint: String,
        counterparty_id: String,
        started_at: Date,
        ended_at: Date,
        duration_milliseconds: Int64,
        outbound_message_count: Int64,
        inbound_message_count: Int64,
        outbound_bytes: Int64,
        inbound_bytes: Int64,
        audit_event_count: Int64,
        thread_delta: Int,
        rss_delta_bytes: Int64,
        heap_delta_bytes: Int64?,
        user_cpu_microseconds_delta: UInt64,
        system_cpu_microseconds_delta: UInt64
    ) {
        self.session_id = session_id
        self.endpoint = endpoint
        self.counterparty_id = counterparty_id
        self.started_at = started_at
        self.ended_at = ended_at
        self.duration_milliseconds = duration_milliseconds
        self.outbound_message_count = outbound_message_count
        self.inbound_message_count = inbound_message_count
        self.outbound_bytes = outbound_bytes
        self.inbound_bytes = inbound_bytes
        self.audit_event_count = audit_event_count
        self.thread_delta = thread_delta
        self.rss_delta_bytes = rss_delta_bytes
        self.heap_delta_bytes = heap_delta_bytes
        self.user_cpu_microseconds_delta = user_cpu_microseconds_delta
        self.system_cpu_microseconds_delta = system_cpu_microseconds_delta
    }

    public var total_messages: Int64 { outbound_message_count + inbound_message_count }
    public var total_bytes: Int64 { outbound_bytes + inbound_bytes }
}

public struct SessionRateCalibration: Codable, Equatable, Sendable {
    public var rau_per_thread_minute: Int64
    public var rau_per_gib_minute: Int64
    public var rau_per_cpu_second: Int64
    public var rau_per_message: Int64
    public var rau_per_audit_event: Int64
    public var target_margin_bps: Int64

    public init(
        rau_per_thread_minute: Int64,
        rau_per_gib_minute: Int64,
        rau_per_cpu_second: Int64,
        rau_per_message: Int64,
        rau_per_audit_event: Int64,
        target_margin_bps: Int64 = 2_500
    ) {
        self.rau_per_thread_minute = rau_per_thread_minute
        self.rau_per_gib_minute = rau_per_gib_minute
        self.rau_per_cpu_second = rau_per_cpu_second
        self.rau_per_message = rau_per_message
        self.rau_per_audit_event = rau_per_audit_event
        self.target_margin_bps = target_margin_bps
    }
}

public struct SessionMinuteRateSuggestion: Codable, Equatable, Sendable {
    public var observed_session_count: Int
    public var total_duration_milliseconds: Int64
    public var total_estimated_cost_rau: Int64
    public var average_estimated_cost_rau: Int64
    public var suggested_session_fee_per_minute_rau: Int64

    public init(
        observed_session_count: Int,
        total_duration_milliseconds: Int64,
        total_estimated_cost_rau: Int64,
        average_estimated_cost_rau: Int64,
        suggested_session_fee_per_minute_rau: Int64
    ) {
        self.observed_session_count = observed_session_count
        self.total_duration_milliseconds = total_duration_milliseconds
        self.total_estimated_cost_rau = total_estimated_cost_rau
        self.average_estimated_cost_rau = average_estimated_cost_rau
        self.suggested_session_fee_per_minute_rau = suggested_session_fee_per_minute_rau
    }
}

public enum SessionRateEstimator {
    public static func suggest(
        records: [CloudBridgeSessionRecord],
        calibration: SessionRateCalibration
    ) -> SessionMinuteRateSuggestion {
        let totalDuration = records.reduce(Int64(0)) { $0 + max($1.duration_milliseconds, 1) }
        let totalCost = records.reduce(Int64(0)) { partial, record in
            partial + estimatedCost(record: record, calibration: calibration)
        }
        let averageCost = records.isEmpty ? 0 : totalCost / Int64(records.count)
        let suggested: Int64
        if totalDuration == 0 || records.isEmpty {
            suggested = 0
        } else {
            let minutes = Decimal(totalDuration) / Decimal(60_000)
            let baseRate = Decimal(totalCost) / max(minutes, Decimal(1))
            let marginMultiplier = Decimal(10_000 + calibration.target_margin_bps) / Decimal(10_000)
            suggested = NSDecimalNumber(decimal: baseRate * marginMultiplier)
                .rounding(accordingToBehavior: NSDecimalNumberHandler(
                    roundingMode: .up,
                    scale: 0,
                    raiseOnExactness: false,
                    raiseOnOverflow: true,
                    raiseOnUnderflow: true,
                    raiseOnDivideByZero: true
                )).int64Value
        }

        return SessionMinuteRateSuggestion(
            observed_session_count: records.count,
            total_duration_milliseconds: totalDuration,
            total_estimated_cost_rau: totalCost,
            average_estimated_cost_rau: averageCost,
            suggested_session_fee_per_minute_rau: suggested
        )
    }

    public static func estimatedCost(
        record: CloudBridgeSessionRecord,
        calibration: SessionRateCalibration
    ) -> Int64 {
        let durationMinutes = Decimal(max(record.duration_milliseconds, 1)) / Decimal(60_000)
        let rssGiB = Decimal(max(record.rss_delta_bytes, 0)) / Decimal(1_073_741_824)
        let threadDelta = max(record.thread_delta, 0)
        let cpuSeconds = Decimal(record.user_cpu_microseconds_delta + record.system_cpu_microseconds_delta) / Decimal(1_000_000)

        let decimalCost = (Decimal(threadDelta) * durationMinutes * Decimal(calibration.rau_per_thread_minute))
            + (rssGiB * durationMinutes * Decimal(calibration.rau_per_gib_minute))
            + (cpuSeconds * Decimal(calibration.rau_per_cpu_second))
            + (Decimal(record.total_messages) * Decimal(calibration.rau_per_message))
            + (Decimal(record.audit_event_count) * Decimal(calibration.rau_per_audit_event))

        return NSDecimalNumber(decimal: decimalCost).rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .up,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: true,
            raiseOnUnderflow: true,
            raiseOnDivideByZero: true
        )).int64Value
    }
}

public actor CloudBridgeCostProfiler {
    private struct ActiveSession {
        var endpoint: String
        var counterpartyID: String
        var startedAt: Date
        var startSnapshot: ProcessResourceSnapshot
        var outboundMessageCount: Int64 = 0
        var inboundMessageCount: Int64 = 0
        var outboundBytes: Int64 = 0
        var inboundBytes: Int64 = 0
        var auditEventCount: Int64 = 0
    }

    private let snapshotProvider: @Sendable () throws -> ProcessResourceSnapshot
    private var activeSessions: [UUID: ActiveSession] = [:]
    private var completedSessions: [CloudBridgeSessionRecord] = []

    public init(snapshotProvider: @escaping @Sendable () throws -> ProcessResourceSnapshot = { try ProcessResourceSampler.capture() }) {
        self.snapshotProvider = snapshotProvider
    }

    @discardableResult
    public func startSession(endpoint: URL, counterpartyID: String) throws -> UUID {
        let sessionID = UUID()
        activeSessions[sessionID] = ActiveSession(
            endpoint: endpoint.absoluteString,
            counterpartyID: counterpartyID,
            startedAt: Date(),
            startSnapshot: try snapshotProvider()
        )
        return sessionID
    }

    public func recordOutboundMessage(sessionID: UUID, bytes: Int64) throws {
        guard var session = activeSessions[sessionID] else { throw ProfilerError.sessionNotFound(sessionID) }
        session.outboundMessageCount += 1
        session.outboundBytes += max(bytes, 0)
        activeSessions[sessionID] = session
    }

    public func recordInboundMessage(sessionID: UUID, bytes: Int64) throws {
        guard var session = activeSessions[sessionID] else { throw ProfilerError.sessionNotFound(sessionID) }
        session.inboundMessageCount += 1
        session.inboundBytes += max(bytes, 0)
        activeSessions[sessionID] = session
    }

    public func recordAuditEvent(sessionID: UUID) throws {
        guard var session = activeSessions[sessionID] else { throw ProfilerError.sessionNotFound(sessionID) }
        session.auditEventCount += 1
        activeSessions[sessionID] = session
    }

    @discardableResult
    public func finishSession(sessionID: UUID) throws -> CloudBridgeSessionRecord {
        guard let session = activeSessions.removeValue(forKey: sessionID) else {
            throw ProfilerError.sessionNotFound(sessionID)
        }

        let endSnapshot = try snapshotProvider()
        let endedAt = Date()
        let record = CloudBridgeSessionRecord(
            session_id: sessionID,
            endpoint: session.endpoint,
            counterparty_id: session.counterpartyID,
            started_at: session.startedAt,
            ended_at: endedAt,
            duration_milliseconds: Int64(max(0, endedAt.timeIntervalSince(session.startedAt) * 1_000)),
            outbound_message_count: session.outboundMessageCount,
            inbound_message_count: session.inboundMessageCount,
            outbound_bytes: session.outboundBytes,
            inbound_bytes: session.inboundBytes,
            audit_event_count: session.auditEventCount,
            thread_delta: endSnapshot.thread_count - session.startSnapshot.thread_count,
            rss_delta_bytes: Int64(endSnapshot.resident_memory_bytes) - Int64(session.startSnapshot.resident_memory_bytes),
            heap_delta_bytes: heapDelta(end: endSnapshot.heap_bytes, start: session.startSnapshot.heap_bytes),
            user_cpu_microseconds_delta: endSnapshot.user_cpu_microseconds - session.startSnapshot.user_cpu_microseconds,
            system_cpu_microseconds_delta: endSnapshot.system_cpu_microseconds - session.startSnapshot.system_cpu_microseconds
        )
        completedSessions.append(record)
        return record
    }

    public func completedRecords() -> [CloudBridgeSessionRecord] {
        completedSessions.sorted { $0.started_at < $1.started_at }
    }

    public func suggestSessionMinuteRate(calibration: SessionRateCalibration) -> SessionMinuteRateSuggestion {
        SessionRateEstimator.suggest(records: completedSessions, calibration: calibration)
    }

    private func heapDelta(end: UInt64?, start: UInt64?) -> Int64? {
        guard let end, let start else { return nil }
        return Int64(end) - Int64(start)
    }
}

public actor ProfiledChannel: Channel {
    private let base: any Channel
    private let profiler: CloudBridgeCostProfiler
    public let sessionID: UUID
    private var finished = false

    public init(base: any Channel, profiler: CloudBridgeCostProfiler, sessionID: UUID) {
        self.base = base
        self.profiler = profiler
        self.sessionID = sessionID
    }

    public func send(_ bytes: Data) async throws {
        try await base.send(bytes)
        try await profiler.recordOutboundMessage(sessionID: sessionID, bytes: Int64(bytes.count))
    }

    public func receive() async throws -> Data {
        let data = try await base.receive()
        try await profiler.recordInboundMessage(sessionID: sessionID, bytes: Int64(data.count))
        return data
    }

    public func recordAuditEvent() async throws {
        try await profiler.recordAuditEvent(sessionID: sessionID)
    }

    public func close() async {
        await base.close()
        if !finished {
            _ = try? await profiler.finishSession(sessionID: sessionID)
            finished = true
        }
    }
}

public struct ProfiledTransportClient: TransportClient {
    public var kind: TransportKind { base.kind }

    private let base: any TransportClient
    private let profiler: CloudBridgeCostProfiler
    private let counterpartyResolver: @Sendable (URL) -> String

    public init(
        base: any TransportClient,
        profiler: CloudBridgeCostProfiler,
        counterpartyResolver: @escaping @Sendable (URL) -> String = { $0.host ?? "unknown" }
    ) {
        self.base = base
        self.profiler = profiler
        self.counterpartyResolver = counterpartyResolver
    }

    public func connect(endpoint: URL) async throws -> any Channel {
        let sessionID = try await profiler.startSession(endpoint: endpoint, counterpartyID: counterpartyResolver(endpoint))
        let channel = try await base.connect(endpoint: endpoint)
        return ProfiledChannel(base: channel, profiler: profiler, sessionID: sessionID)
    }
}
