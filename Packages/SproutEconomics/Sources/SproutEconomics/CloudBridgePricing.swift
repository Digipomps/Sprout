import Foundation

public enum UnderfundedMode: String, Codable, Equatable, Sendable {
    case deny
    case degrade
}

public struct CloudflareEdgePricingModel: Codable, Equatable, Sendable {
    public var worker_request_fee_rau: Int64
    public var worker_cpu_ms_fee_rau: Int64
    public var durable_object_request_fee_rau: Int64
    public var durable_object_duration_ms_fee_rau: Int64
    public var durable_object_storage_gib_month_fee_rau: Int64

    public init(
        worker_request_fee_rau: Int64 = 0,
        worker_cpu_ms_fee_rau: Int64 = 0,
        durable_object_request_fee_rau: Int64 = 0,
        durable_object_duration_ms_fee_rau: Int64 = 0,
        durable_object_storage_gib_month_fee_rau: Int64 = 0
    ) {
        self.worker_request_fee_rau = worker_request_fee_rau
        self.worker_cpu_ms_fee_rau = worker_cpu_ms_fee_rau
        self.durable_object_request_fee_rau = durable_object_request_fee_rau
        self.durable_object_duration_ms_fee_rau = durable_object_duration_ms_fee_rau
        self.durable_object_storage_gib_month_fee_rau = durable_object_storage_gib_month_fee_rau
    }
}

public struct EdgeExecutionUsage: Codable, Equatable, Sendable {
    public var worker_request_count: Int64
    public var worker_cpu_milliseconds: Int64
    public var durable_object_request_count: Int64
    public var durable_object_duration_milliseconds: Int64
    public var durable_object_storage_gib_months: Decimal

    public init(
        worker_request_count: Int64 = 0,
        worker_cpu_milliseconds: Int64 = 0,
        durable_object_request_count: Int64 = 0,
        durable_object_duration_milliseconds: Int64 = 0,
        durable_object_storage_gib_months: Decimal = 0
    ) {
        self.worker_request_count = worker_request_count
        self.worker_cpu_milliseconds = worker_cpu_milliseconds
        self.durable_object_request_count = durable_object_request_count
        self.durable_object_duration_milliseconds = durable_object_duration_milliseconds
        self.durable_object_storage_gib_months = durable_object_storage_gib_months
    }
}

public struct HybridFeeSchedule: Codable, Equatable, Sendable {
    public var session_fee_per_minute_rau: Int64
    public var per_message_fee_rau: Int64
    public var per_kb_fee_rau: Int64
    public var audit_fee_per_event_rau: Int64
    public var max_rate_rau_per_minute: Int64

    public init(
        session_fee_per_minute_rau: Int64,
        per_message_fee_rau: Int64,
        per_kb_fee_rau: Int64,
        audit_fee_per_event_rau: Int64,
        max_rate_rau_per_minute: Int64
    ) {
        self.session_fee_per_minute_rau = session_fee_per_minute_rau
        self.per_message_fee_rau = per_message_fee_rau
        self.per_kb_fee_rau = per_kb_fee_rau
        self.audit_fee_per_event_rau = audit_fee_per_event_rau
        self.max_rate_rau_per_minute = max_rate_rau_per_minute
    }
}

public struct CloudBridgePricingContract: Codable, Equatable, Sendable {
    public var contract_id: String
    public var session_fee_per_minute_rau: Int64
    public var per_message_fee_rau: Int64
    public var per_kb_fee_rau: Int64
    public var audit_fee_per_event_rau: Int64
    public var min_deposit_rau: Int64
    public var max_rate_rau_per_minute: Int64
    public var underfunded_mode: UnderfundedMode
    public var degraded_capability_grants: [String]
    public var requires_always_on: Bool
    public var do_duration_escrow_rau: Int64?
    public var edge_pricing: CloudflareEdgePricingModel?

    public init(
        contract_id: String,
        session_fee_per_minute_rau: Int64,
        per_message_fee_rau: Int64,
        per_kb_fee_rau: Int64,
        audit_fee_per_event_rau: Int64,
        min_deposit_rau: Int64,
        max_rate_rau_per_minute: Int64,
        underfunded_mode: UnderfundedMode = .deny,
        degraded_capability_grants: [String] = [],
        requires_always_on: Bool = false,
        do_duration_escrow_rau: Int64? = nil,
        edge_pricing: CloudflareEdgePricingModel? = nil
    ) {
        self.contract_id = contract_id
        self.session_fee_per_minute_rau = session_fee_per_minute_rau
        self.per_message_fee_rau = per_message_fee_rau
        self.per_kb_fee_rau = per_kb_fee_rau
        self.audit_fee_per_event_rau = audit_fee_per_event_rau
        self.min_deposit_rau = min_deposit_rau
        self.max_rate_rau_per_minute = max_rate_rau_per_minute
        self.underfunded_mode = underfunded_mode
        self.degraded_capability_grants = degraded_capability_grants.sorted()
        self.requires_always_on = requires_always_on
        self.do_duration_escrow_rau = do_duration_escrow_rau
        self.edge_pricing = edge_pricing
    }
}

public enum PricingCompilationOutcome: String, Codable, Equatable, Sendable {
    case allow
    case degrade
    case deny
}

public struct CompiledCloudBridgePricingPlan: Codable, Equatable, Sendable {
    public var contract_id: String
    public var outcome: PricingCompilationOutcome
    public var declared_deposit_rau: Int64
    public var required_deposit_rau: Int64
    public var effective_capability_grants: [String]
    public var fee_schedule: HybridFeeSchedule
    public var do_duration_escrow_rau: Int64?
    public var reason: String?

    public init(
        contract_id: String,
        outcome: PricingCompilationOutcome,
        declared_deposit_rau: Int64,
        required_deposit_rau: Int64,
        effective_capability_grants: [String],
        fee_schedule: HybridFeeSchedule,
        do_duration_escrow_rau: Int64?,
        reason: String?
    ) {
        self.contract_id = contract_id
        self.outcome = outcome
        self.declared_deposit_rau = declared_deposit_rau
        self.required_deposit_rau = required_deposit_rau
        self.effective_capability_grants = effective_capability_grants.sorted()
        self.fee_schedule = fee_schedule
        self.do_duration_escrow_rau = do_duration_escrow_rau
        self.reason = reason
    }
}

public struct CloudBridgeSessionUsage: Codable, Equatable, Sendable {
    public var duration_milliseconds: Int64
    public var outbound_message_count: Int64
    public var inbound_message_count: Int64
    public var outbound_bytes: Int64
    public var inbound_bytes: Int64
    public var audit_event_count: Int64
    public var edge_usage: EdgeExecutionUsage?

    public init(
        duration_milliseconds: Int64,
        outbound_message_count: Int64,
        inbound_message_count: Int64,
        outbound_bytes: Int64,
        inbound_bytes: Int64,
        audit_event_count: Int64,
        edge_usage: EdgeExecutionUsage? = nil
    ) {
        self.duration_milliseconds = duration_milliseconds
        self.outbound_message_count = outbound_message_count
        self.inbound_message_count = inbound_message_count
        self.outbound_bytes = outbound_bytes
        self.inbound_bytes = inbound_bytes
        self.audit_event_count = audit_event_count
        self.edge_usage = edge_usage
    }

    public var total_message_count: Int64 {
        outbound_message_count + inbound_message_count
    }

    public var total_byte_count: Int64 {
        outbound_bytes + inbound_bytes
    }
}

public struct CloudBridgeChargeBreakdown: Codable, Equatable, Sendable {
    public var billed_minutes: Int64
    public var billed_kilobytes: Int64
    public var session_fee_rau: Int64
    public var message_fee_rau: Int64
    public var kilobyte_fee_rau: Int64
    public var audit_fee_rau: Int64
    public var edge_fee_rau: Int64
    public var uncapped_total_rau: Int64
    public var capped_total_rau: Int64
    public var max_billable_rau: Int64

    public init(
        billed_minutes: Int64,
        billed_kilobytes: Int64,
        session_fee_rau: Int64,
        message_fee_rau: Int64,
        kilobyte_fee_rau: Int64,
        audit_fee_rau: Int64,
        edge_fee_rau: Int64,
        uncapped_total_rau: Int64,
        capped_total_rau: Int64,
        max_billable_rau: Int64
    ) {
        self.billed_minutes = billed_minutes
        self.billed_kilobytes = billed_kilobytes
        self.session_fee_rau = session_fee_rau
        self.message_fee_rau = message_fee_rau
        self.kilobyte_fee_rau = kilobyte_fee_rau
        self.audit_fee_rau = audit_fee_rau
        self.edge_fee_rau = edge_fee_rau
        self.uncapped_total_rau = uncapped_total_rau
        self.capped_total_rau = capped_total_rau
        self.max_billable_rau = max_billable_rau
    }
}

public enum CloudBridgePricingCompiler {
    public static func compile(
        contract: CloudBridgePricingContract,
        declaredDepositRAU: Int64,
        requestedCapabilities: [String]
    ) -> CompiledCloudBridgePricingPlan {
        let requiredDeposit = contract.min_deposit_rau + (contract.requires_always_on ? max(contract.do_duration_escrow_rau ?? 0, 0) : 0)
        let schedule = HybridFeeSchedule(
            session_fee_per_minute_rau: contract.session_fee_per_minute_rau,
            per_message_fee_rau: contract.per_message_fee_rau,
            per_kb_fee_rau: contract.per_kb_fee_rau,
            audit_fee_per_event_rau: contract.audit_fee_per_event_rau,
            max_rate_rau_per_minute: contract.max_rate_rau_per_minute
        )

        guard declaredDepositRAU >= requiredDeposit else {
            if contract.underfunded_mode == .degrade {
                let degraded = requestedCapabilities.filter { contract.degraded_capability_grants.contains($0) }
                if !degraded.isEmpty {
                    return CompiledCloudBridgePricingPlan(
                        contract_id: contract.contract_id,
                        outcome: .degrade,
                        declared_deposit_rau: declaredDepositRAU,
                        required_deposit_rau: requiredDeposit,
                        effective_capability_grants: degraded,
                        fee_schedule: schedule,
                        do_duration_escrow_rau: contract.requires_always_on ? contract.do_duration_escrow_rau : nil,
                        reason: "declared deposit is below minimum; degraded capability set applied"
                    )
                }
            }

            return CompiledCloudBridgePricingPlan(
                contract_id: contract.contract_id,
                outcome: .deny,
                declared_deposit_rau: declaredDepositRAU,
                required_deposit_rau: requiredDeposit,
                effective_capability_grants: [],
                fee_schedule: schedule,
                do_duration_escrow_rau: contract.requires_always_on ? contract.do_duration_escrow_rau : nil,
                reason: "declared deposit is below required minimum"
            )
        }

        return CompiledCloudBridgePricingPlan(
            contract_id: contract.contract_id,
            outcome: .allow,
            declared_deposit_rau: declaredDepositRAU,
            required_deposit_rau: requiredDeposit,
            effective_capability_grants: requestedCapabilities.sorted(),
            fee_schedule: schedule,
            do_duration_escrow_rau: contract.requires_always_on ? contract.do_duration_escrow_rau : nil,
            reason: nil
        )
    }

    public static func estimateCharge(
        contract: CloudBridgePricingContract,
        usage: CloudBridgeSessionUsage
    ) -> CloudBridgeChargeBreakdown {
        let billedMinutes = billedMinuteCount(durationMilliseconds: usage.duration_milliseconds, totalMessages: usage.total_message_count, totalBytes: usage.total_byte_count, auditEvents: usage.audit_event_count)
        let billedKB = billedKilobytes(usage.total_byte_count)
        let sessionFee = billedMinutes * contract.session_fee_per_minute_rau
        let messageFee = usage.total_message_count * contract.per_message_fee_rau
        let kilobyteFee = billedKB * contract.per_kb_fee_rau
        let auditFee = usage.audit_event_count * contract.audit_fee_per_event_rau
        let edgeFee = edgeCharge(contract: contract, usage: usage.edge_usage)
        let uncapped = sessionFee + messageFee + kilobyteFee + auditFee + edgeFee
        let maxBillable = max(contract.max_rate_rau_per_minute, 0) * billedMinutes
        let capped = maxBillable > 0 ? min(uncapped, maxBillable) : uncapped

        return CloudBridgeChargeBreakdown(
            billed_minutes: billedMinutes,
            billed_kilobytes: billedKB,
            session_fee_rau: sessionFee,
            message_fee_rau: messageFee,
            kilobyte_fee_rau: kilobyteFee,
            audit_fee_rau: auditFee,
            edge_fee_rau: edgeFee,
            uncapped_total_rau: uncapped,
            capped_total_rau: capped,
            max_billable_rau: maxBillable
        )
    }

    public static func doDurationEscrowRequired(contract: CloudBridgePricingContract) -> Int64 {
        contract.requires_always_on ? max(contract.do_duration_escrow_rau ?? 0, 0) : 0
    }

    private static func billedMinuteCount(durationMilliseconds: Int64, totalMessages: Int64, totalBytes: Int64, auditEvents: Int64) -> Int64 {
        guard durationMilliseconds > 0 || totalMessages > 0 || totalBytes > 0 || auditEvents > 0 else {
            return 0
        }
        return max(1, (max(durationMilliseconds, 1) + 59_999) / 60_000)
    }

    private static func billedKilobytes(_ byteCount: Int64) -> Int64 {
        guard byteCount > 0 else { return 0 }
        return (byteCount + 1_023) / 1_024
    }

    private static func edgeCharge(contract: CloudBridgePricingContract, usage: EdgeExecutionUsage?) -> Int64 {
        guard let usage, let edgePricing = contract.edge_pricing else {
            return 0
        }

        let storageFeeDecimal = Decimal(edgePricing.durable_object_storage_gib_month_fee_rau) * usage.durable_object_storage_gib_months
        let storageFee = NSDecimalNumber(decimal: storageFeeDecimal).rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: true,
            raiseOnUnderflow: true,
            raiseOnDivideByZero: true
        )).int64Value

        return (usage.worker_request_count * edgePricing.worker_request_fee_rau)
            + (usage.worker_cpu_milliseconds * edgePricing.worker_cpu_ms_fee_rau)
            + (usage.durable_object_request_count * edgePricing.durable_object_request_fee_rau)
            + (usage.durable_object_duration_milliseconds * edgePricing.durable_object_duration_ms_fee_rau)
            + storageFee
    }
}
