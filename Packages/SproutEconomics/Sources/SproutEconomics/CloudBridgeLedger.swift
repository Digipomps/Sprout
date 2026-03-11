import Foundation

public enum LedgerEntryKind: String, Codable, Equatable, Sendable {
    case deposit
    case debit
    case credit
    case hold
    case release
    case rollup
}

public struct CloudBridgeLedgerEntry: Codable, Equatable, Sendable {
    public var entry_id: UUID
    public var wallet_id: String
    public var cell_id: String
    public var counterparty_id: String
    public var minute_bucket: String?
    public var kind: LedgerEntryKind
    public var amount_rau: Int64
    public var message_count: Int64
    public var byte_count: Int64
    public var audit_event_count: Int64
    public var session_milliseconds: Int64
    public var description: String
    public var created_at: String

    public init(
        entry_id: UUID = UUID(),
        wallet_id: String,
        cell_id: String,
        counterparty_id: String,
        minute_bucket: String? = nil,
        kind: LedgerEntryKind,
        amount_rau: Int64,
        message_count: Int64 = 0,
        byte_count: Int64 = 0,
        audit_event_count: Int64 = 0,
        session_milliseconds: Int64 = 0,
        description: String,
        created_at: String
    ) {
        self.entry_id = entry_id
        self.wallet_id = wallet_id
        self.cell_id = cell_id
        self.counterparty_id = counterparty_id
        self.minute_bucket = minute_bucket
        self.kind = kind
        self.amount_rau = amount_rau
        self.message_count = message_count
        self.byte_count = byte_count
        self.audit_event_count = audit_event_count
        self.session_milliseconds = session_milliseconds
        self.description = description
        self.created_at = created_at
    }
}

public actor CloudBridgeLedger {
    private var entries: [CloudBridgeLedgerEntry] = []

    public init() {}

    public func append(_ entry: CloudBridgeLedgerEntry) {
        entries.append(entry)
    }

    public func append(contentsOf newEntries: [CloudBridgeLedgerEntry]) {
        entries.append(contentsOf: newEntries)
    }

    public func allEntries() -> [CloudBridgeLedgerEntry] {
        entries.sorted { $0.created_at < $1.created_at }
    }

    public func balance(walletID: String) -> WalletBalance {
        let walletEntries = entries.filter { $0.wallet_id == walletID }
        var available: Int64 = 0
        var held: Int64 = 0

        for entry in walletEntries {
            switch entry.kind {
            case .deposit, .credit, .release:
                available += entry.amount_rau
            case .debit, .rollup:
                available -= entry.amount_rau
            case .hold:
                available -= entry.amount_rau
                held += entry.amount_rau
            }
        }

        return WalletBalance(available_rau: available, held_rau: held)
    }
}

public struct CloudBridgeUsageDelta: Codable, Equatable, Sendable {
    public var wallet_id: String
    public var cell_id: String
    public var counterparty_id: String
    public var timestamp: Date
    public var message_count: Int64
    public var byte_count: Int64
    public var audit_event_count: Int64
    public var session_milliseconds: Int64

    public init(
        wallet_id: String,
        cell_id: String,
        counterparty_id: String,
        timestamp: Date,
        message_count: Int64,
        byte_count: Int64,
        audit_event_count: Int64,
        session_milliseconds: Int64
    ) {
        self.wallet_id = wallet_id
        self.cell_id = cell_id
        self.counterparty_id = counterparty_id
        self.timestamp = timestamp
        self.message_count = message_count
        self.byte_count = byte_count
        self.audit_event_count = audit_event_count
        self.session_milliseconds = session_milliseconds
    }
}

public struct RollupFlushPolicy: Codable, Equatable, Sendable {
    public var message_threshold: Int64
    public var byte_threshold: Int64
    public var audit_threshold: Int64

    public init(
        message_threshold: Int64 = 250,
        byte_threshold: Int64 = 256 * 1_024,
        audit_threshold: Int64 = 128
    ) {
        self.message_threshold = message_threshold
        self.byte_threshold = byte_threshold
        self.audit_threshold = audit_threshold
    }
}

public actor CloudBridgeRollupAggregator {
    private struct RollupKey: Hashable {
        var walletID: String
        var cellID: String
        var counterpartyID: String
        var minuteBucket: String
    }

    private struct Accumulator {
        var walletID: String
        var cellID: String
        var counterpartyID: String
        var minuteBucket: String
        var messageCount: Int64 = 0
        var byteCount: Int64 = 0
        var auditEventCount: Int64 = 0
        var sessionMilliseconds: Int64 = 0
        var lastTimestamp: Date
    }

    private var accumulators: [RollupKey: Accumulator] = [:]
    private let pricingContract: CloudBridgePricingContract?
    private let flushPolicy: RollupFlushPolicy
    private let entryIDProvider: @Sendable () -> UUID
    private let formatter = ISO8601DateFormatter()

    public init(
        pricingContract: CloudBridgePricingContract? = nil,
        flushPolicy: RollupFlushPolicy = .init(),
        entryIDProvider: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.pricingContract = pricingContract
        self.flushPolicy = flushPolicy
        self.entryIDProvider = entryIDProvider
    }

    public func record(_ delta: CloudBridgeUsageDelta) -> [CloudBridgeLedgerEntry] {
        let bucket = Self.minuteBucketString(for: delta.timestamp)
        let key = RollupKey(walletID: delta.wallet_id, cellID: delta.cell_id, counterpartyID: delta.counterparty_id, minuteBucket: bucket)
        var accumulator = accumulators[key] ?? Accumulator(
            walletID: delta.wallet_id,
            cellID: delta.cell_id,
            counterpartyID: delta.counterparty_id,
            minuteBucket: bucket,
            lastTimestamp: delta.timestamp
        )

        accumulator.messageCount += delta.message_count
        accumulator.byteCount += delta.byte_count
        accumulator.auditEventCount += delta.audit_event_count
        accumulator.sessionMilliseconds += delta.session_milliseconds
        accumulator.lastTimestamp = delta.timestamp
        accumulators[key] = accumulator

        if shouldFlush(accumulator: accumulator) {
            accumulators.removeValue(forKey: key)
            return [makeLedgerEntry(from: accumulator)]
        }

        return []
    }

    public func close() -> [CloudBridgeLedgerEntry] {
        let orderedAccumulators = accumulators.values.sorted {
            if $0.minuteBucket != $1.minuteBucket {
                return $0.minuteBucket < $1.minuteBucket
            }
            if $0.cellID != $1.cellID {
                return $0.cellID < $1.cellID
            }
            if $0.counterpartyID != $1.counterpartyID {
                return $0.counterpartyID < $1.counterpartyID
            }
            return $0.walletID < $1.walletID
        }
        let entries = orderedAccumulators.map(makeLedgerEntry(from:))
        accumulators.removeAll()
        return entries.sorted { $0.created_at < $1.created_at }
    }

    private func shouldFlush(accumulator: Accumulator) -> Bool {
        accumulator.messageCount >= flushPolicy.message_threshold
            || accumulator.byteCount >= flushPolicy.byte_threshold
            || accumulator.auditEventCount >= flushPolicy.audit_threshold
    }

    private func makeLedgerEntry(from accumulator: Accumulator) -> CloudBridgeLedgerEntry {
        let usage = CloudBridgeSessionUsage(
            duration_milliseconds: accumulator.sessionMilliseconds,
            outbound_message_count: accumulator.messageCount,
            inbound_message_count: 0,
            outbound_bytes: accumulator.byteCount,
            inbound_bytes: 0,
            audit_event_count: accumulator.auditEventCount
        )

        let amount = pricingContract.map {
            CloudBridgePricingCompiler.estimateCharge(contract: $0, usage: usage).capped_total_rau
        } ?? 0

        return CloudBridgeLedgerEntry(
            entry_id: entryIDProvider(),
            wallet_id: accumulator.walletID,
            cell_id: accumulator.cellID,
            counterparty_id: accumulator.counterpartyID,
            minute_bucket: accumulator.minuteBucket,
            kind: .rollup,
            amount_rau: amount,
            message_count: accumulator.messageCount,
            byte_count: accumulator.byteCount,
            audit_event_count: accumulator.auditEventCount,
            session_milliseconds: accumulator.sessionMilliseconds,
            description: "rollup for \(accumulator.cellID) -> \(accumulator.counterpartyID) @ \(accumulator.minuteBucket)",
            created_at: formatter.string(from: accumulator.lastTimestamp)
        )
    }

    private static func minuteBucketString(for date: Date) -> String {
        let timestamp = Int64(date.timeIntervalSince1970)
        let bucket = timestamp - (timestamp % 60)
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(bucket)))
    }
}
