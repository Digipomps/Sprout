import XCTest
@testable import SproutEconomics

final class StripeOverlayTests: XCTestCase {
    func testSmallerTopUpsCarryHigherFeePressure() {
        let results = StripeTopUpSimulator.simulate(topUpNOK: [20, 300], dailySpendOre: 500)
        let small = try! XCTUnwrap(results.first)
        let large = try! XCTUnwrap(results.last)

        XCTAssertEqual(small.churn_pressure, "high")
        XCTAssertEqual(large.churn_pressure, "low")
        XCTAssertGreaterThan(NSDecimalNumber(decimal: small.fee_share_percent).doubleValue,
                             NSDecimalNumber(decimal: large.fee_share_percent).doubleValue)
    }
}
