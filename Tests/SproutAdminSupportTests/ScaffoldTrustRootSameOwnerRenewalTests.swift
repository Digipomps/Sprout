import Foundation
import XCTest
import SproutAdminSupport
import SproutCrypto
import SproutResolverAdapter

final class ScaffoldTrustRootSameOwnerRenewalTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!

    func fixture() throws -> SameOwnerFixture {
        let f = try SameOwnerFixture(now: now)
        f.previous.scaffold_admin_public_key = Base64URL.encode(f.owner.publicKey)
        f.previous.resolver_public_keys = f.reviewedKeys
        f.previous.bridge_owner_public_keys = Array(f.reviewedKeys.reversed())
        f.previous.expires_at = "2026-10-13T12:00:00Z"
        try f.resignPrevious(seed: f.owner.privateKey)
        return f
    }

    func renew(_ f: SameOwnerFixture, pins: ScaffoldTrustRootSameOwnerRenewalOwnerPins? = nil,
               expiry: Date? = nil, id: String = "renewed") throws -> ScaffoldAdminTrustRootDescriptor {
        try ScaffoldTrustRootSameOwnerRenewal.renew(descriptorData: f.descriptorData,
            expectedDescriptorSHA256: f.descriptorHash, expectedDomain: f.domain,
            vaultPaths: f.paths, ownerPins: pins ?? f.pins(), descriptorID: id,
            expiresAt: expiry ?? now.addingTimeInterval(14 * 86400), now: now)
    }

    func testSameOwnerPreservesEveryFieldExceptIDDatesAndSignature() throws {
        let f = try fixture(); defer { f.remove() }
        let before = try Data(contentsOf: f.vaultURL)
        let keyBefore = try Data(contentsOf: f.keyURL)
        let result = try renew(f)
        var restored = result
        restored.descriptor_id = f.previous.descriptor_id
        restored.issued_at = f.previous.issued_at
        restored.expires_at = f.previous.expires_at
        restored.signature = f.previous.signature
        XCTAssertEqual(restored, f.previous)
        XCTAssertTrue(try result.verifySignature())
        // Normal Sprout consumer validator; no expired-input exception here.
        XCTAssertNoThrow(try ScaffoldAdminTrustRootDescriptorValidator().validate(descriptor: result,
            context: .init(expectedDomain: f.domain, now: now)))
        XCTAssertEqual(try Data(contentsOf: f.vaultURL), before)
        XCTAssertEqual(try Data(contentsOf: f.keyURL), keyBefore)
        XCTAssertThrowsError(try VaporVaultDecoder.loadIdentities(paths: f.paths))
    }

    func testWrongOwnerUUIDContextFingerprintAndOtherSignerAreDenied() throws {
        let f = try fixture(); defer { f.remove() }
        for pins in [f.pins(uuid: UUID().uuidString), f.pins(context: "Other"),
                     f.pins(fingerprint: Hashing.sha256Base64URL(f.owner.publicKey))] {
            XCTAssertThrowsError(try renew(f, pins: pins))
        }
        let other = f.envelope.identities[1]
        f.previous.scaffold_admin_public_key = Base64URL.encode(other.publicKey)
        try f.resignPrevious(seed: other.privateKey)
        XCTAssertThrowsError(try renew(f)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootSameOwnerRenewalError, .differentSigner)
        }
    }

    func testVaultHashChangedAndLegacyVaultCannotFallBack() throws {
        let f = try fixture(); defer { f.remove() }
        let old = f.pins()
        try f.writeVault()
        XCTAssertThrowsError(try renew(f, pins: old)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootSameOwnerRenewalError, .vaultDigestMismatch)
        }
        try f.writeVault(payload: JSONEncoder().encode(f.envelope.identities))
        XCTAssertThrowsError(try renew(f)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootSameOwnerRenewalError, .invalidVault)
        }
    }

    func testPastUnextendedAndOverThirtyDaysExpireAreDenied() throws {
        let f = try fixture(); defer { f.remove() }
        for expiry in [now.addingTimeInterval(-1), now.addingTimeInterval(1),
                       ISO8601DateFormatter().date(from: f.previous.expires_at)!,
                       now.addingTimeInterval(30 * 86400 + 1)] {
            XCTAssertThrowsError(try renew(f, expiry: expiry))
        }
        XCTAssertNoThrow(try renew(f, expiry: now.addingTimeInterval(30 * 86400)))
        XCTAssertThrowsError(try renew(f, id: f.previous.descriptor_id))
        XCTAssertThrowsError(try renew(f, id: " "))
    }

    func testSignatureTamperUnknownFieldAndMalformedV2AreDenied() throws {
        let f = try fixture(); defer { f.remove() }
        f.previous.resolver_base_url += "tampered"
        try f.writeDescriptor()
        XCTAssertThrowsError(try renew(f))
        try f.resignPrevious(seed: f.owner.privateKey)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: f.descriptorData) as? [String: Any])
        obj["unknown"] = "must be preserved or refused"
        f.descriptorData = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertThrowsError(try renew(f))
        try f.writeDescriptor()
        f.envelope.identities.append(f.owner)
        try f.writeVault()
        XCTAssertThrowsError(try renew(f))
    }
}
