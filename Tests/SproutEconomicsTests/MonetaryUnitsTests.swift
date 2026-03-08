import XCTest
@testable import SproutEconomics

final class MonetaryUnitsTests: XCTestCase {
    func testRAUIsSourceOfTruthAcrossViews() {
        let amount = RAUAmount.fromOre(1)
        XCTAssertEqual(amount.rawValue, 10_000_000)
        XCTAssertEqual(NSDecimalNumber(decimal: amount.imuView).stringValue, "10000")
        XCTAssertEqual(NSDecimalNumber(decimal: amount.oreView).stringValue, "1")
        XCTAssertEqual(NSDecimalNumber(decimal: amount.nokView).stringValue, "0.01")
    }
}
