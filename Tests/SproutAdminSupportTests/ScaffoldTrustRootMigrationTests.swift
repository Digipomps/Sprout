import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
import SproutAdminSupport
import SproutCrypto
import SproutResolverAdapter

final class ScaffoldTrustRootMigrationTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!

    func testMigrationRequiresCurrentOwnerAndPreservesReviewedPublicParameters() throws {
        let fixture = try MigrationFixture(now: now)
        defer { fixture.remove() }
        let beforeVault = try Data(contentsOf: fixture.vaultURL)
        let beforeKey = try Data(contentsOf: fixture.keyURL)
        let result = try migrate(fixture)
        XCTAssertNotEqual(result.scaffold_admin_public_key, fixture.previous.scaffold_admin_public_key)
        XCTAssertEqual(result.scaffold_admin_public_key, Base64URL.encode(fixture.owner.publicKey))
        XCTAssertEqual(result.resolver_public_keys, fixture.reviewedKeys)
        XCTAssertEqual(result.bridge_owner_public_keys, Array(fixture.reviewedKeys.reversed()))
        XCTAssertEqual(result.software_catalog_url, fixture.previous.software_catalog_url)
        XCTAssertEqual(result.starter_bootstrap_url, fixture.previous.starter_bootstrap_url)
        XCTAssertEqual(result.bridge_discovery_url, fixture.previous.bridge_discovery_url)
        XCTAssertEqual(result.resolver_base_url, fixture.previous.resolver_base_url)
        XCTAssertEqual(result.scaffold_domain, fixture.previous.scaffold_domain)
        XCTAssertEqual(result.version, fixture.previous.version)
        XCTAssertTrue(try result.verifySignature())
        XCTAssertNoThrow(try ScaffoldAdminTrustRootDescriptorValidator().validate(descriptor: result,
            context: .init(expectedDomain: fixture.domain, now: now)))
        XCTAssertThrowsError(try ScaffoldAdminTrustRootDescriptorValidator().validate(descriptor: fixture.previous,
            context: .init(expectedDomain: fixture.domain, now: now)))
        XCTAssertEqual(try Data(contentsOf: fixture.vaultURL), beforeVault)
        XCTAssertEqual(try Data(contentsOf: fixture.keyURL), beforeKey)
        // Migration does not broaden the ordinary identity loader.
        XCTAssertThrowsError(try VaporVaultDecoder.loadIdentities(paths: fixture.paths)) {
            XCTAssertEqual($0 as? VaporVaultError, .currentVaultRequiresOwnerBinding)
        }
    }

    func testRejectMissingMalformedAndWrongCurrentOwnerPins() throws {
        let fixture = try MigrationFixture(now: now)
        defer { fixture.remove() }
        for pins in [
            fixture.pins(uuid: ""), fixture.pins(context: "Other"), fixture.pins(fingerprint: ""),
            fixture.pins(vaultHash: ""), fixture.pins(vaultHash: fixture.vaultHash.uppercased())
        ] {
            XCTAssertThrowsError(try migrate(fixture, pins: pins)) {
                XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .invalidPins)
            }
        }
        for pins in [fixture.pins(uuid: UUID().uuidString),
                     fixture.pins(fingerprint: Hashing.sha256Base64URL(fixture.owner.publicKey))] {
            XCTAssertThrowsError(try migrate(fixture, pins: pins)) {
                XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .ownerBindingMismatch)
            }
        }
    }

    func testDescriptorAndEncryptedVaultMustMatchExactReviewedBytes() throws {
        let fixture = try MigrationFixture(now: now)
        defer { fixture.remove() }
        XCTAssertThrowsError(try migrate(fixture, descriptorHash: String(repeating: "0", count: 64))) {
            XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .descriptorDigestMismatch)
        }
        let stalePins = fixture.pins()
        try fixture.writeVault() // Fresh nonce changes the encrypted revision, retaining the same keys.
        XCTAssertThrowsError(try migrate(fixture, pins: stalePins)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .vaultDigestMismatch)
        }
        var corrupted = try Data(contentsOf: fixture.vaultURL)
        corrupted[corrupted.count - 1] ^= 1
        try corrupted.write(to: fixture.vaultURL)
        fixture.vaultHash = MigrationFixture.sha256(corrupted)
        XCTAssertThrowsError(try migrate(fixture)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .invalidVault)
        }
    }

    func testWrongMasterKeyAndNonV2PayloadCannotFallBack() throws {
        let fixture = try MigrationFixture(now: now)
        defer { fixture.remove() }
        try Data(repeating: 99, count: 32).write(to: fixture.keyURL)
        XCTAssertThrowsError(try migrate(fixture)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .invalidVault)
        }
        try fixture.masterKey.write(to: fixture.keyURL)
        try fixture.writeVault(payload: JSONEncoder().encode(fixture.envelope.identities))
        XCTAssertThrowsError(try migrate(fixture)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .invalidVault)
        }
        fixture.envelope.schema = "haven.vapor-identity-vault.v3"
        try fixture.writeVault()
        XCTAssertThrowsError(try migrate(fixture)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .invalidVault)
        }
        fixture.envelope.schema = "haven.vapor-identity-vault.v2"
        fixture.envelope.fileVersion = 0
        try fixture.writeVault()
        XCTAssertThrowsError(try migrate(fixture)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .invalidVault)
        }
    }

    func testDuplicateUUIDOrContextAndInconsistentKeyRolesAreDenied() throws {
        let fixture = try MigrationFixture(now: now)
        defer { fixture.remove() }
        let original = fixture.envelope
        let mutations: [(inout MigrationFixture.Envelope) -> Void] = [
            { $0.identities[1].uuid = $0.identities[0].uuid },
            { $0.identities[1].identityContext = "Scaffold" },
            {
                $0.identities[0].privateKey = Data(repeating: 8, count: 32)
                $0.identities[0].privateSecureKey.compressedKey = Data(repeating: 8, count: 32)
            },
            { $0.identities[0].publicSecureKey.algorithm = "ECDSA" },
            { $0.identities[0].privateSecureKey.privateKey = false },
            { $0.identities[0].privateSecureKey.compressedKey = Data(repeating: 8, count: 32) },
            {
                $0.identities[0].keyAgreementPrivateKey = Data(repeating: 8, count: 32)
                $0.identities[0].privateKeyAgreementSecureKey.compressedKey = Data(repeating: 8, count: 32)
            },
            { $0.identities[0].publicKeyAgreementSecureKey.use = "signature" }
        ]
        for mutate in mutations {
            fixture.envelope = original
            mutate(&fixture.envelope)
            try fixture.writeVault()
            XCTAssertThrowsError(try migrate(fixture)) {
                XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .invalidVault)
            }
        }
        fixture.envelope = original
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var identities = try XCTUnwrap(object["identities"] as? [[String: Any]])
        identities[0].removeValue(forKey: "privateSecureKey")
        object["identities"] = identities
        try fixture.writeVault(payload: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try migrate(fixture)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .invalidVault)
        }
    }

    func testOwnerPinCannotSelectACompatibilityIdentity() throws {
        let fixture = try MigrationFixture(now: now)
        defer { fixture.remove() }
        let pinnedOwner = fixture.pins()
        fixture.envelope.identities[0].identityContext = "RealOwner"
        fixture.envelope.identities[1].identityContext = "Scaffold"
        try fixture.writeVault()
        let pins = ScaffoldTrustRootMigrationOwnerPins(uuid: pinnedOwner.uuid, context: pinnedOwner.context,
            signingKeyFingerprintDigest: pinnedOwner.signingKeyFingerprintDigest, encryptedVaultSHA256: fixture.vaultHash)
        XCTAssertThrowsError(try migrate(fixture, pins: pins)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .ownerBindingMismatch)
        }
    }

    func testOldDescriptorMustHaveGenuineSignatureAndCorrectDomain() throws {
        let fixture = try MigrationFixture(now: now)
        defer { fixture.remove() }
        XCTAssertThrowsError(try migrate(fixture, domain: "other.example.test")) {
            XCTAssertEqual($0 as? ScaffoldAdminTrustRootDescriptorValidationError,
                .wrongDomain(expected: "other.example.test", got: fixture.domain))
        }
        fixture.previous.software_catalog_url = "https://attacker.example.test/catalog"
        try fixture.writeDescriptor() // Re-pin bytes: authenticity still must hold independently.
        XCTAssertThrowsError(try migrate(fixture)) {
            XCTAssertEqual($0 as? ScaffoldAdminTrustRootDescriptorValidationError, .signatureInvalid)
        }
    }

    func testRequireReviewedKeysAndBoundedValidity() throws {
        let fixture = try MigrationFixture(now: now)
        defer { fixture.remove() }
        for keys in [[], ["invalid"], [fixture.reviewedKeys[0], fixture.reviewedKeys[0]],
                     [fixture.reviewedKeys[0] + "="], [""]] {
            XCTAssertThrowsError(try migrate(fixture, resolverKeys: keys)) {
                XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .invalidApprovedKeys)
            }
            XCTAssertThrowsError(try migrate(fixture, bridgeKeys: keys)) {
                XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .invalidApprovedKeys)
            }
        }
        for interval in [-1.0, 0, 0.5, 30 * 86_400 + 1, .infinity, .nan] {
            XCTAssertThrowsError(try migrate(fixture, expiresAt: now.addingTimeInterval(interval))) {
                XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .invalidValidity)
            }
        }
        XCTAssertNoThrow(try migrate(fixture, expiresAt: now.addingTimeInterval(30 * 86_400)))
        for id in ["", " ", fixture.previous.descriptor_id] {
            XCTAssertThrowsError(try migrate(fixture, descriptorID: id)) {
                XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .invalidDescriptorID)
            }
        }
    }

    func testRejectSameSignerAndInvalidHistoricalDates() throws {
        let fixture = try MigrationFixture(now: now)
        defer { fixture.remove() }
        fixture.previous.scaffold_admin_public_key = Base64URL.encode(fixture.owner.publicKey)
        try fixture.resignPrevious(seed: fixture.owner.privateKey)
        XCTAssertThrowsError(try migrate(fixture)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .unchangedSigner)
        }
        fixture.previous.scaffold_admin_public_key += "="
        try fixture.resignPrevious(seed: fixture.owner.privateKey)
        XCTAssertThrowsError(try migrate(fixture)) {
            // The existing signature verifier rejects noncanonical Base64URL before owner selection.
            XCTAssertEqual($0 as? ScaffoldAdminTrustRootDescriptorValidationError, .signatureInvalid)
        }
        fixture.previous.scaffold_admin_public_key = Base64URL.encode(fixture.owner.publicKey)
        fixture.previous.issued_at = fixture.previous.expires_at
        try fixture.resignPrevious(seed: fixture.owner.privateKey)
        XCTAssertThrowsError(try migrate(fixture)) {
            XCTAssertEqual($0 as? ScaffoldTrustRootMigrationError, .invalidValidity)
        }
    }

    private func migrate(_ fixture: MigrationFixture, pins: ScaffoldTrustRootMigrationOwnerPins? = nil,
                         descriptorHash: String? = nil, domain: String? = nil, resolverKeys: [String]? = nil,
                         bridgeKeys: [String]? = nil, expiresAt: Date? = nil, descriptorID: String = "migrated-reviewed") throws -> ScaffoldAdminTrustRootDescriptor {
        try ScaffoldTrustRootMigration.migrate(descriptorData: fixture.descriptorData,
            expectedDescriptorSHA256: descriptorHash ?? fixture.descriptorHash, expectedDomain: domain ?? fixture.domain,
            vaultPaths: fixture.paths, ownerPins: pins ?? fixture.pins(), descriptorID: descriptorID,
            expiresAt: expiresAt ?? now.addingTimeInterval(86_400), resolverPublicKeys: resolverKeys ?? fixture.reviewedKeys,
            bridgeOwnerPublicKeys: bridgeKeys ?? Array(fixture.reviewedKeys.reversed()), now: now)
    }
}

/// Entirely synthetic fixture following CP 9c60001's encrypted v2 and SecureKey encoding.
final class MigrationFixture {
    struct Key: Codable {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        var privateKey: Bool
        var use: String
        var algorithm: String
        var size = 256
        var curveType = "Curve25519"
        var compressedKey: Data
    }
    struct Identity: Codable {
        var uuid: String
        var displayName = "Synthetic migration identity"
        var identityContext: String
        var publicKey: Data
        var privateKey: Data
        var keyAgreementPublicKey: Data
        var keyAgreementPrivateKey: Data
        var publicSecureKey: Key
        var privateSecureKey: Key
        var publicKeyAgreementSecureKey: Key
        var privateKeyAgreementSecureKey: Key

        init(context: String) throws {
            uuid = UUID().uuidString
            identityContext = context
            privateKey = Ed25519.generateSeed()
            publicKey = try Ed25519KeyPair(seed: privateKey).publicKeyData
            let agreement = Curve25519.KeyAgreement.PrivateKey()
            keyAgreementPublicKey = agreement.publicKey.rawRepresentation
            keyAgreementPrivateKey = agreement.rawRepresentation
            publicSecureKey = Key(privateKey: false, use: "signature", algorithm: "EdDSA", compressedKey: publicKey)
            privateSecureKey = Key(privateKey: true, use: "signature", algorithm: "EdDSA", compressedKey: privateKey)
            publicKeyAgreementSecureKey = Key(privateKey: false, use: "keyAgreement", algorithm: "X25519", compressedKey: keyAgreementPublicKey)
            privateKeyAgreementSecureKey = Key(privateKey: true, use: "keyAgreement", algorithm: "X25519", compressedKey: keyAgreementPrivateKey)
        }
    }
    struct Envelope: Codable {
        var schema = "haven.vapor-identity-vault.v2"
        var fileVersion: UInt64 = 17
        var identities: [Identity]
    }

    let directory: URL
    let domain = "migration.example.test"
    let masterKey: Data
    var envelope: Envelope
    var previous: ScaffoldAdminTrustRootDescriptor
    var descriptorData = Data()
    var vaultHash = ""
    var descriptorHash: String { Self.sha256(descriptorData) }
    var owner: Identity { envelope.identities[0] }
    var reviewedKeys: [String] { envelope.identities.map { Base64URL.encode($0.publicKey) } }
    var vaultURL: URL { file("OrganisationIdentities.crypt") }
    var keyURL: URL { file("synthetic-master.key") }
    var paths: VaporVaultPaths { .init(vaultFileURL: vaultURL, masterKeyFileURL: keyURL) }

    init(now: Date) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        masterKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        envelope = try Envelope(identities: [Identity(context: "Scaffold"), Identity(context: "Service")])
        let oldSeed = Ed25519.generateSeed()
        let oldAdmin = VaporVaultIdentityRecord(uuid: UUID().uuidString, displayName: "Synthetic old admin",
            identityContext: "Scaffold", publicKey: try Ed25519KeyPair(seed: oldSeed).publicKeyData, privateKey: oldSeed)
        previous = try ScaffoldTrustRootDescriptorBuilder.buildSignedDescriptor(scaffoldDomain: domain,
            adminIdentity: oldAdmin, descriptorID: "old-reviewed", issuedAt: now.addingTimeInterval(-60 * 86_400),
            expiresAt: now.addingTimeInterval(-30 * 86_400), resolverPublicKeys: [oldAdmin.publicKeyBase64URL],
            bridgeOwnerPublicKeys: [oldAdmin.publicKeyBase64URL],
            starterBootstrapURL: URL(string: "https://auth.example.test:443/intent?x=1&y=2")!,
            bridgeDiscoveryURL: URL(string: "https://bridges.example.test/query")!,
            resolverBaseURL: URL(string: "https://resolver.example.test/base/")!)
        previous.software_catalog_url = "https://catalog.example.test/releases?channel=stable"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try masterKey.write(to: keyURL)
        try resignPrevious(seed: oldSeed)
        try writeVault()
    }

    func resignPrevious(seed: Data) throws {
        previous.signature = .init(alg: "Ed25519", sig: try Ed25519.signBase64URL(
            data: previous.canonicalPayloadData(), seedBase64URL: Base64URL.encode(seed)))
        try writeDescriptor()
    }
    func writeDescriptor() throws {
        descriptorData = try JSONEncoder().encode(previous)
        try descriptorData.write(to: file("previous.json"))
    }
    func writeVault(payload: Data? = nil) throws {
        let plaintext = try payload ?? JSONEncoder().encode(envelope)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: masterKey),
            salt: Data("CellScaffoldVaultSalt.v1".utf8), info: Data("OrganisationIdentities.crypt".utf8), outputByteCount: 32)
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: Data("cell-vault-v1:OrganisationIdentities.crypt".utf8))
        var encrypted = Data("CVLT1".utf8)
        encrypted.append(box.nonce.withUnsafeBytes { Data($0) })
        encrypted.append(box.ciphertext)
        encrypted.append(box.tag)
        try encrypted.write(to: vaultURL)
        vaultHash = Self.sha256(encrypted)
    }
    func pins(uuid: String? = nil, context: String? = nil, fingerprint: String? = nil, vaultHash: String? = nil) -> ScaffoldTrustRootMigrationOwnerPins {
        .init(uuid: uuid ?? owner.uuid, context: context ?? "Scaffold",
            signingKeyFingerprintDigest: fingerprint ?? Hashing.sha256Base64URL(Data("EdDSA:Curve25519:\(owner.publicKey.base64EncodedString())".utf8)),
            encryptedVaultSHA256: vaultHash ?? self.vaultHash)
    }
    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    static func sha256(_ data: Data) -> String { Hashing.sha256(data).map { String(format: "%02x", $0) }.joined() }
}
