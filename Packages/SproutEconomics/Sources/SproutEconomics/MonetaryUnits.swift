import Foundation

public struct RAUAmount: Codable, Hashable, Comparable, Sendable {
    public static let rauPerIMU: Int64 = 1_000
    public static let imuPerOre: Int64 = 10_000
    public static let rauPerOre: Int64 = rauPerIMU * imuPerOre
    public static let orePerNOK: Int64 = 100

    public let rawValue: Int64

    public init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: RAUAmount, rhs: RAUAmount) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static func + (lhs: RAUAmount, rhs: RAUAmount) -> RAUAmount {
        RAUAmount(lhs.rawValue + rhs.rawValue)
    }

    public static func - (lhs: RAUAmount, rhs: RAUAmount) -> RAUAmount {
        RAUAmount(lhs.rawValue - rhs.rawValue)
    }

    public static func * (lhs: RAUAmount, rhs: Int64) -> RAUAmount {
        RAUAmount(lhs.rawValue * rhs)
    }

    public static func fromIMU(_ imu: Int64) -> RAUAmount {
        RAUAmount(imu * rauPerIMU)
    }

    public static func fromOre(_ ore: Int64) -> RAUAmount {
        RAUAmount(ore * rauPerOre)
    }

    public static func fromNOK(_ nok: Int64) -> RAUAmount {
        fromOre(nok * orePerNOK)
    }

    public static func fromOreDecimal(_ ore: Decimal, rounding: NSDecimalNumber.RoundingMode = .plain) -> RAUAmount {
        let scaled = ore * Decimal(rauPerOre)
        let decimal = NSDecimalNumber(decimal: scaled)
        let handler = NSDecimalNumberHandler(
            roundingMode: rounding,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: true,
            raiseOnUnderflow: true,
            raiseOnDivideByZero: true
        )
        return RAUAmount(decimal.rounding(accordingToBehavior: handler).int64Value)
    }

    public var imuView: Decimal {
        Decimal(rawValue) / Decimal(Self.rauPerIMU)
    }

    public var oreView: Decimal {
        Decimal(rawValue) / Decimal(Self.rauPerOre)
    }

    public var nokView: Decimal {
        oreView / Decimal(Self.orePerNOK)
    }

    public var isNegative: Bool {
        rawValue < 0
    }

    public var description: String {
        let imu = NSDecimalNumber(decimal: imuView).stringValue
        let ore = NSDecimalNumber(decimal: oreView).stringValue
        let nok = NSDecimalNumber(decimal: nokView).stringValue
        return "\(rawValue) RAU (~\(imu) IMU, ~\(ore) ore, ~\(nok) NOK)"
    }
}

public struct WalletBalance: Codable, Equatable, Sendable {
    public var available_rau: Int64
    public var held_rau: Int64

    public init(available_rau: Int64 = 0, held_rau: Int64 = 0) {
        self.available_rau = available_rau
        self.held_rau = held_rau
    }

    public var available: RAUAmount { RAUAmount(available_rau) }
    public var held: RAUAmount { RAUAmount(held_rau) }
    public var total: RAUAmount { RAUAmount(available_rau + held_rau) }
}
