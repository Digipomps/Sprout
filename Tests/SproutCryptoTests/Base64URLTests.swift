import XCTest
@testable import SproutCrypto

final class Base64URLTests: XCTestCase {
    func testRoundTripWithoutPadding() throws {
        let data = Data("sprout".utf8)
        let encoded = Base64URL.encode(data)
        XCTAssertFalse(encoded.contains("="))

        let decoded = try Base64URL.decode(encoded)
        XCTAssertEqual(decoded, data)
    }

    func testRejectPadding() {
        XCTAssertThrowsError(try Base64URL.decode("AQ==")) { error in
            XCTAssertEqual(error as? Base64URLError, .paddedInputNotAllowed)
        }
    }

    func testRejectInvalidCharacter() {
        XCTAssertThrowsError(try Base64URL.decode("abc*")) { error in
            guard case .invalidCharacter("*") = error as? Base64URLError else {
                return XCTFail("expected invalid character")
            }
        }
    }

    func testRejectInvalidLength() {
        XCTAssertThrowsError(try Base64URL.decode("a")) { error in
            XCTAssertEqual(error as? Base64URLError, .invalidLength)
        }
    }
}
