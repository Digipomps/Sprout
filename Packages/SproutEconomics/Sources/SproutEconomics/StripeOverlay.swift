import Foundation

public struct StripeDomesticCardOverlay: Codable, Equatable, Sendable {
    public var percentage_bps: Int64
    public var fixed_fee_ore: Int64

    public init(percentage_bps: Int64 = 240, fixed_fee_ore: Int64 = 200) {
        self.percentage_bps = percentage_bps
        self.fixed_fee_ore = fixed_fee_ore
    }

    public static let `default` = StripeDomesticCardOverlay()
}

public struct StripeTopUpScenarioResult: Codable, Equatable, Sendable {
    public var top_up_nok: Int64
    public var gross_top_up_ore: Int64
    public var stripe_fee_ore: Decimal
    public var fee_share_percent: Decimal
    public var net_deposit_ore: Decimal
    public var net_deposit_rau: Int64
    public var implied_refill_days: Decimal
    public var churn_pressure: String
    public var payment_latency_seconds: Int64

    public init(
        top_up_nok: Int64,
        gross_top_up_ore: Int64,
        stripe_fee_ore: Decimal,
        fee_share_percent: Decimal,
        net_deposit_ore: Decimal,
        net_deposit_rau: Int64,
        implied_refill_days: Decimal,
        churn_pressure: String,
        payment_latency_seconds: Int64
    ) {
        self.top_up_nok = top_up_nok
        self.gross_top_up_ore = gross_top_up_ore
        self.stripe_fee_ore = stripe_fee_ore
        self.fee_share_percent = fee_share_percent
        self.net_deposit_ore = net_deposit_ore
        self.net_deposit_rau = net_deposit_rau
        self.implied_refill_days = implied_refill_days
        self.churn_pressure = churn_pressure
        self.payment_latency_seconds = payment_latency_seconds
    }
}

public enum StripeTopUpSimulator {
    public static func simulate(
        topUpNOK: [Int64],
        dailySpendOre: Int64 = 500,
        paymentLatencySeconds: Int64 = 4,
        overlay: StripeDomesticCardOverlay = .default
    ) -> [StripeTopUpScenarioResult] {
        topUpNOK.sorted().map { nok in
            let grossOre = nok * 100
            let variableFee = Decimal(grossOre) * Decimal(overlay.percentage_bps) / Decimal(10_000)
            let totalFee = variableFee + Decimal(overlay.fixed_fee_ore)
            let netOre = max(Decimal(0), Decimal(grossOre) - totalFee)
            let feeShare = grossOre > 0 ? (totalFee / Decimal(grossOre)) * 100 : 0
            let refillDays = dailySpendOre > 0 ? netOre / Decimal(dailySpendOre) : 0

            return StripeTopUpScenarioResult(
                top_up_nok: nok,
                gross_top_up_ore: grossOre,
                stripe_fee_ore: totalFee,
                fee_share_percent: feeShare,
                net_deposit_ore: netOre,
                net_deposit_rau: RAUAmount.fromOreDecimal(netOre).rawValue,
                implied_refill_days: refillDays,
                churn_pressure: churnPressure(feeSharePercent: feeShare, topUpNOK: nok),
                payment_latency_seconds: paymentLatencySeconds
            )
        }
    }

    private static func churnPressure(feeSharePercent: Decimal, topUpNOK: Int64) -> String {
        if topUpNOK <= 20 || feeSharePercent >= 10 {
            return "high"
        }
        if topUpNOK <= 50 || feeSharePercent >= 5 {
            return "medium"
        }
        return "low"
    }
}
