import Foundation
import XCTest
@testable import SproutAdminSupport
import SproutCrypto
import SproutResolverAdapter

final class ScaffoldTrustRootRenewalTests: XCTestCase {
    private let domain = "scaffold.example.test"
    private let now = ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z")!

    func testRenewExpiredDescriptorPreservesAllFieldsExceptRenewalMetadata() throws {
        let admin = try identity()
        let original = try descriptor(admin: admin)
        XCTAssertThrowsError(try validate(original)) {
            XCTAssertEqual($0 as? ScaffoldAdminTrustRootDescriptorValidationError, .expired)
        }
        let renewed = try renew(original, admin: admin)
        XCTAssertEqual(renewed.descriptor_id, "renewed")
        XCTAssertEqual(renewed.issued_at, "2026-09-26T12:00:00Z")
        XCTAssertEqual(renewed.expires_at, "2026-09-27T12:00:00Z")
        XCTAssertNotEqual(renewed.signature, original.signature)
        XCTAssertTrue(try renewed.verifySignature())
        XCTAssertNoThrow(try validate(renewed))
        var withoutRenewal = renewed
        withoutRenewal.descriptor_id = original.descriptor_id
        withoutRenewal.issued_at = original.issued_at
        withoutRenewal.expires_at = original.expires_at
        withoutRenewal.signature = original.signature
        XCTAssertEqual(withoutRenewal, original)
        XCTAssertEqual(renewed.resolver_public_keys.count, 2)
        XCTAssertEqual(renewed.bridge_owner_public_keys.count, 2)
        XCTAssertEqual(renewed.software_catalog_url, "https://catalog.example.test/releases?channel=stable")
        // Administrative renewal does not change normal rejection of the old descriptor.
        XCTAssertThrowsError(try validate(original))
    }

    func testRenewActiveDescriptorWithoutOptionalCatalog() throws {
        let admin = try identity()
        var original = try descriptor(admin: admin)
        original.software_catalog_url = nil
        original.expires_at = "2026-09-26T13:00:00Z"
        original = try sign(original, admin: admin)
        let decoded = try ScaffoldTrustRootDescriptorBuilder.decodeDescriptorForRenewal(
            from: JSONEncoder().encode(original)
        )
        let renewed = try renew(decoded, admin: admin)
        XCTAssertNil(renewed.software_catalog_url)
        XCTAssertNoThrow(try validate(renewed))
    }

    func testRejectForgedExpiredDescriptor() throws {
        let admin = try identity()
        var forged = try descriptor(admin: admin)
        forged.resolver_public_keys.append("attacker-key")
        XCTAssertThrowsError(try renew(forged, admin: admin)) {
            XCTAssertEqual($0 as? ScaffoldAdminTrustRootDescriptorValidationError, .signatureInvalid)
        }
    }

    func testRejectWrongSignerAndInconsistentPrivateKey() throws {
        let admin = try identity()
        let original = try descriptor(admin: admin)
        let wrongAdmin = try identity(seedByte: 2)
        XCTAssertThrowsError(try renew(original, admin: wrongAdmin)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootRenewalError, .signerMismatch)
        }
        var inconsistentAdmin = admin
        inconsistentAdmin.privateKey = wrongAdmin.privateKey
        XCTAssertThrowsError(try renew(original, admin: inconsistentAdmin)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootRenewalError, .signerMismatch)
        }
    }

    func testRejectWrongIdentityContext() throws {
        var admin = try identity()
        let original = try descriptor(admin: admin)
        admin.identityContext = "AnotherDomain"
        XCTAssertThrowsError(try renew(original, admin: admin)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootRenewalError, .wrongIdentityContext)
        }
    }

    func testRejectWrongExpectedDomain() throws {
        let admin = try identity()
        XCTAssertThrowsError(try ScaffoldTrustRootDescriptorBuilder.renewSignedDescriptor(
            descriptor: descriptor(admin: admin), expectedDomain: "other.example.test",
            adminIdentity: admin, descriptorID: "renewed", expiresAt: now.addingTimeInterval(86_400), now: now
        )) {
            XCTAssertEqual($0 as? ScaffoldAdminTrustRootDescriptorValidationError,
                           .wrongDomain(expected: "other.example.test", got: self.domain))
        }
    }

    func testRejectExpiredEqualReversedAndExcessiveNewValidity() throws {
        let admin = try identity()
        let original = try descriptor(admin: admin)
        for interval in [-1.0, 0, 0.5, 30 * 86_400 + 1, .infinity, .nan] {
            XCTAssertThrowsError(try renew(original, admin: admin, expiresAt: now.addingTimeInterval(interval))) {
                XCTAssertEqual($0 as? ScaffoldTrustRootRenewalError, .invalidValidity)
            }
        }
        XCTAssertNoThrow(try renew(original, admin: admin, expiresAt: now.addingTimeInterval(30 * 86_400)))
    }

    func testRejectRenewalThatDoesNotExtendExistingExpiry() throws {
        let admin = try identity()
        var original = try descriptor(admin: admin)
        original.expires_at = "2026-09-28T12:00:00Z"
        original = try sign(original, admin: admin)
        XCTAssertThrowsError(try renew(original, admin: admin)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootRenewalError, .invalidValidity)
        }
    }

    func testRejectMalformedReversedAndFutureHistoricalDatesEvenIfSigned() throws {
        let admin = try identity()
        for dates in [
            ("invalid", "2026-09-07T00:00:00Z"),
            ("2026-09-01T00:00:00Z", "invalid"),
            ("2026-09-07T00:00:00Z", "2026-09-07T00:00:00Z"),
            ("2026-09-08T00:00:00Z", "2026-09-07T00:00:00Z"),
            ("2026-09-27T00:00:00Z", "2026-09-28T00:00:00Z")
        ] {
            var original = try descriptor(admin: admin)
            original.issued_at = dates.0
            original.expires_at = dates.1
            original = try sign(original, admin: admin)
            XCTAssertThrowsError(try renew(original, admin: admin)) {
                XCTAssertEqual($0 as? ScaffoldTrustRootRenewalError, .invalidValidity)
            }
        }
    }

    func testRejectEmptyOrUnchangedDescriptorID() throws {
        let admin = try identity()
        let original = try descriptor(admin: admin)
        for id in ["", "  ", original.descriptor_id] {
            XCTAssertThrowsError(try ScaffoldTrustRootDescriptorBuilder.renewSignedDescriptor(
                descriptor: original, expectedDomain: domain, adminIdentity: admin,
                descriptorID: id, expiresAt: now.addingTimeInterval(86_400), now: now
            )) {
                XCTAssertEqual($0 as? ScaffoldTrustRootRenewalError, .invalidDescriptorID)
            }
        }
    }

    func testRejectInvalidURLsAndMissingApprovedKeysEvenIfSigned() throws {
        let admin = try identity()
        let original = try descriptor(admin: admin)
        var invalidURL = original
        invalidURL.software_catalog_url = "http://catalog.example.test"
        XCTAssertThrowsError(try renew(sign(invalidURL, admin: admin), admin: admin)) {
            XCTAssertEqual($0 as? ScaffoldAdminTrustRootDescriptorValidationError,
                           .invalidURL("http://catalog.example.test"))
        }
        var missingResolvers = original
        missingResolvers.resolver_public_keys = []
        XCTAssertThrowsError(try renew(sign(missingResolvers, admin: admin), admin: admin)) {
            XCTAssertEqual($0 as? ScaffoldAdminTrustRootDescriptorValidationError, .missingResolverPublicKeys)
        }
        var missingBridges = original
        missingBridges.bridge_owner_public_keys = []
        XCTAssertThrowsError(try renew(sign(missingBridges, admin: admin), admin: admin)) {
            XCTAssertEqual($0 as? ScaffoldAdminTrustRootDescriptorValidationError, .missingBridgeOwnerPublicKeys)
        }
    }

    func testRejectUnsupportedVersionAndSignatureAlgorithm() throws {
        let admin = try identity()
        var original = try descriptor(admin: admin)
        original.version = "2.0"
        original = try sign(original, admin: admin)
        XCTAssertThrowsError(try renew(original, admin: admin)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootRenewalError, .unsupportedVersion("2.0"))
        }
        original.version = "1.0"
        original.signature.alg = "unsupported"
        XCTAssertThrowsError(try renew(original, admin: admin)) {
            XCTAssertEqual($0 as? ScaffoldAdminTrustRootDescriptorValidationError,
                           .unsupportedSignatureAlgorithm("unsupported"))
        }
    }

    func testDecodeRejectsFieldsItCannotPreserve() throws {
        let original = try descriptor(admin: identity())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["future_policy"] = "must not be discarded"
        XCTAssertThrowsError(try ScaffoldTrustRootDescriptorBuilder.decodeDescriptorForRenewal(
            from: JSONSerialization.data(withJSONObject: object)
        )) {
            XCTAssertEqual($0 as? ScaffoldTrustRootRenewalError, .unsupportedFields(["future_policy"]))
        }
        object.removeValue(forKey: "future_policy")
        object["signature"] = ["alg": original.signature.alg, "sig": original.signature.sig, "future": "value"]
        XCTAssertThrowsError(try ScaffoldTrustRootDescriptorBuilder.decodeDescriptorForRenewal(
            from: JSONSerialization.data(withJSONObject: object)
        )) {
            XCTAssertEqual($0 as? ScaffoldTrustRootRenewalError, .unsupportedFields(["signature.future"]))
        }
    }

    private func identity(seedByte: UInt8 = 1) throws -> VaporVaultIdentityRecord {
        let seed = Data(repeating: seedByte, count: 32)
        return VaporVaultIdentityRecord(uuid: "synthetic-admin", displayName: "Synthetic admin",
            identityContext: "Scaffold", publicKey: try Ed25519KeyPair(seed: seed).publicKeyData, privateKey: seed)
    }

    private func descriptor(admin: VaporVaultIdentityRecord) throws -> ScaffoldAdminTrustRootDescriptor {
        try sign(ScaffoldAdminTrustRootDescriptor(
            version: "1.0", descriptor_id: "original", scaffold_domain: domain,
            scaffold_admin_public_key: admin.publicKeyBase64URL,
            resolver_public_keys: ["approved-resolver-2", "approved-resolver-1"],
            bridge_owner_public_keys: ["approved-bridge-2", "approved-bridge-1"],
            starter_bootstrap_url: "https://auth.example.test:443/custom/intent?x=1&y=2",
            bridge_discovery_url: "https://bridges.example.test/custom/query",
            resolver_base_url: "https://resolver.example.test/base/",
            software_catalog_url: "https://catalog.example.test/releases?channel=stable",
            issued_at: "2026-08-08T00:00:00Z", expires_at: "2026-09-07T00:00:00Z",
            signature: .init(alg: "Ed25519", sig: "")
        ), admin: admin)
    }

    private func sign(_ descriptor: ScaffoldAdminTrustRootDescriptor, admin: VaporVaultIdentityRecord) throws -> ScaffoldAdminTrustRootDescriptor {
        var result = descriptor
        result.signature = .init(alg: "Ed25519", sig: try Ed25519.signBase64URL(
            data: result.canonicalPayloadData(), seedBase64URL: Base64URL.encode(admin.privateKey)))
        return result
    }

    private func renew(_ descriptor: ScaffoldAdminTrustRootDescriptor, admin: VaporVaultIdentityRecord,
                       expiresAt: Date? = nil) throws -> ScaffoldAdminTrustRootDescriptor {
        try ScaffoldTrustRootDescriptorBuilder.renewSignedDescriptor(
            descriptor: descriptor, expectedDomain: domain, adminIdentity: admin, descriptorID: "renewed",
            expiresAt: expiresAt ?? now.addingTimeInterval(86_400), now: now)
    }

    private func validate(_ descriptor: ScaffoldAdminTrustRootDescriptor) throws {
        try ScaffoldAdminTrustRootDescriptorValidator().validate(descriptor: descriptor,
            context: .init(expectedDomain: domain, now: now))
    }
}
