import SproutCore
import XCTest

final class SproutDoctorTests: XCTestCase {
    func testLocalReportDoesNotClaimIdentityOrChannelAccess() throws {
        let result = try SproutDoctor.inspect()
        XCTAssertEqual(result.cryptography, "passed")
        XCTAssertEqual(result.network, "not_contacted")
        XCTAssertEqual(result.identityStorage, "not_read_or_created")
        XCTAssertEqual(result.channelReadiness, "not_verified")
        XCTAssertTrue(["macos", "linux", "other"].contains(result.platform))
    }
}
