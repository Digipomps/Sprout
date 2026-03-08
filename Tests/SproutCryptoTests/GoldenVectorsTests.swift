import XCTest
@testable import SproutCrypto

final class GoldenVectorsTests: XCTestCase {
    private var rootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testStarterAuthVectorHashAndSignature() throws {
        let data = try Data(contentsOf: rootURL.appendingPathComponent("TestVectors/starter_auth_payload.signed.json"))
        let canonical = try JCSCanonicalizer.canonicalizeRemovingTopLevelKeys(data, keys: ["signature"])

        XCTAssertEqual(Hashing.sha256Base64URL(canonical), "TpNXqpe74lagW4lUcLGjLDWyewUnUGZ2pnToKRF-rT0")

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let signature = (json["signature"] as! [String: Any])["sig"] as! String
        let pub = json["identity_public_key"] as! String

        XCTAssertEqual(signature, "weK57_5rtlom2ZaS_yECjayq_LA3yiUoglRPKmxfD6fCtFZOzN38thTqIPzEPr9V20TtIWnsxiwbm9cZCYRLCw")
        XCTAssertTrue(Ed25519.verifyBase64URL(data: canonical, signatureBase64URL: signature, publicKeyBase64URL: pub))
    }

    func testBridgeDescriptorVectorHashAndSignature() throws {
        let data = try Data(contentsOf: rootURL.appendingPathComponent("TestVectors/bridge_descriptor.signed.json"))
        let canonical = try JCSCanonicalizer.canonicalizeRemovingTopLevelKeys(data, keys: ["signature"])

        XCTAssertEqual(Hashing.sha256Base64URL(canonical), "MgEo9TZgii_ESyw4CndoaShwjB5ppxZE3ZLmLBCVULo")

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let signature = (json["signature"] as! [String: Any])["sig"] as! String
        let pub = json["owner_pubkey"] as! String

        XCTAssertEqual(signature, "AVJkuvlnZ-PIRtuxjvKu5OggmLOoHWvVQhBM2hgG5Ofxn4kjzwLenwHJVpoM7xADXT8hw_EH8XSfIeRfFj3qCA")
        XCTAssertTrue(Ed25519.verifyBase64URL(data: canonical, signatureBase64URL: signature, publicKeyBase64URL: pub))
    }

    func testEntityLinkVectorHashAndMutualSignatures() throws {
        let data = try Data(contentsOf: rootURL.appendingPathComponent("TestVectors/entity_link_contract.mutual.json"))
        let canonical = try JCSCanonicalizer.canonicalizeRemovingTopLevelKeys(data, keys: ["signatures"])

        XCTAssertEqual(Hashing.sha256Base64URL(canonical), "yC9U1RRO1rZEhy9SRjGw_EgD2zqCSGbgu-rveEi1MC8")

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let signatures = json["signatures"] as! [[String: Any]]

        let sigA = signatures[0]["sig"] as! String
        let sigB = signatures[1]["sig"] as! String
        let pubA = signatures[0]["by_pubkey"] as! String
        let pubB = signatures[1]["by_pubkey"] as! String

        XCTAssertEqual(sigA, "OjD5jbjRMfrYpQXhxVPm21KvLnQ3ui_99hVoYlCV-R6ZY6JahRaVWOUB5nVklR0DZPiO-xBf0cqxxEPkF2SqDg")
        XCTAssertEqual(sigB, "n5DdljKIDBxaYV-j3jGHsm1a-YxycZTmmcxHKMc_UpVFLVBzLCw9Ae4n4rD8rqLOfdYe1ztHr_ivnioLDBF1AQ")

        XCTAssertTrue(Ed25519.verifyBase64URL(data: canonical, signatureBase64URL: sigA, publicKeyBase64URL: pubA))
        XCTAssertTrue(Ed25519.verifyBase64URL(data: canonical, signatureBase64URL: sigB, publicKeyBase64URL: pubB))
    }
}
