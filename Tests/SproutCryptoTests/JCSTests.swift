import XCTest
@testable import SproutCrypto

final class JCSTests: XCTestCase {
    func testObjectKeysAreLexicallySorted() throws {
        let input = Data("{\"b\":1,\"a\":2}".utf8)
        let canonical = try JCSCanonicalizer.canonicalize(input)
        XCTAssertEqual(String(decoding: canonical, as: UTF8.self), "{\"a\":2,\"b\":1}")
    }

    func testRejectsFloatingPointNumbersInP0() throws {
        let input = Data("{\"a\":1.5}".utf8)
        XCTAssertThrowsError(try JCSCanonicalizer.canonicalize(input)) { error in
            guard case .unsupportedNumber("1.5") = error as? JCSCanonicalizationError else {
                return XCTFail("expected unsupportedNumber")
            }
        }
    }

    func testRemovesTopLevelSignature() throws {
        let input = Data("{\"b\":1,\"signature\":{\"alg\":\"Ed25519\",\"sig\":\"x\"},\"a\":2}".utf8)
        let canonical = try JCSCanonicalizer.canonicalizeRemovingTopLevelKeys(input, keys: ["signature"])
        XCTAssertEqual(String(decoding: canonical, as: UTF8.self), "{\"a\":2,\"b\":1}")
    }
}
