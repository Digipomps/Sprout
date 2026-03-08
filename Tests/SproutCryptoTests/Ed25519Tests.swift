import XCTest
@testable import SproutCrypto

final class Ed25519Tests: XCTestCase {
    func testPublicKeyDerivationFromSeed() throws {
        let seed = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        let derived = try Ed25519.publicKeyBase64URL(fromSeedBase64URL: seed)
        XCTAssertEqual(derived, "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg")
        XCTAssertEqual(try Base64URL.decode(derived).count, 32)
        XCTAssertFalse(derived.contains("="))
    }

    func testSignAndVerify() throws {
        let seed = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        let payload = Data("sprout-test-payload".utf8)
        let signature = try Ed25519.signBase64URL(data: payload, seedBase64URL: seed)
        let publicKey = try Ed25519.publicKeyBase64URL(fromSeedBase64URL: seed)
        XCTAssertTrue(Ed25519.verifyBase64URL(data: payload, signatureBase64URL: signature, publicKeyBase64URL: publicKey))
    }

    func testVerifyFailsForWrongKey() throws {
        let seed = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        let payload = Data("sprout-test-payload".utf8)
        let signature = try Ed25519.signBase64URL(data: payload, seedBase64URL: seed)
        let wrongKey = "QwRr_kCSs-lJlOraFdzCDYqqB7ZY_TlU644O-4vcpd4"
        XCTAssertFalse(Ed25519.verifyBase64URL(data: payload, signatureBase64URL: signature, publicKeyBase64URL: wrongKey))
    }
}
