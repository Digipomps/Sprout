import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import SproutAdminSupport
import SproutCrypto
import SproutResolverAdapter

final class VaporVaultAnchorSnapshotTests: XCTestCase {
    func testBuildSignedSnapshotVerifies() throws {
        let seed = Ed25519.generateSeed()
        let keyPair = try Ed25519KeyPair(seed: seed)
        let admin = VaporVaultIdentityRecord(
            uuid: "admin-uuid",
            displayName: "Admin",
            identityContext: "Scaffold",
            publicKey: keyPair.publicKeyData,
            privateKey: seed
        )

        let snapshot = try EntityAnchorSnapshotBuilder.buildSignedSnapshot(
            scaffoldDomain: "staging.haven.digipomps.org",
            adminIdentity: admin,
            snapshotID: "snapshot_0001",
            issuedAt: Date(timeIntervalSince1970: 1_762_700_000),
            expiresAt: Date(timeIntervalSince1970: 1_765_292_000),
            entities: [
                EntityAnchorEntityRecord(
                    entity_id: "entity_0001",
                    identities: [
                        EntityAnchorIdentityMember(
                            identity_public_key: "subject_key",
                            domain: "staging.haven.digipomps.org",
                            added_at: "2026-03-11T00:00:00Z"
                        )
                    ]
                )
            ]
        )

        XCTAssertEqual(snapshot.admin_public_key, Base64URL.encode(keyPair.publicKeyData))
        XCTAssertTrue(try snapshot.verifySignature())
    }

    func testVaultDecoderLoadsEncryptedIdentityFile() throws {
        let seed = Ed25519.generateSeed()
        let keyPair = try Ed25519KeyPair(seed: seed)
        let identities = [
            VaporVaultIdentityRecord(
                uuid: "admin-uuid",
                displayName: "Admin",
                identityContext: "Scaffold",
                publicKey: keyPair.publicKeyData,
                privateKey: seed
            )
        ]

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let secretsDir = tempDir.appendingPathComponent(".secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)

        let masterKey = SymmetricKey(size: .bits256)
        let masterKeyData = masterKey.withUnsafeBytes { Data($0) }
        let keyFileURL = secretsDir.appendingPathComponent("vault-master.key")
        try masterKeyData.base64EncodedString().data(using: .utf8)?.write(to: keyFileURL)

        let vaultFileURL = tempDir.appendingPathComponent("OrganisationIdentities.crypt")
        try encryptVault(identities: identities, masterKeyData: masterKeyData).write(to: vaultFileURL)

        let paths = VaporVaultDecoder.resolvePaths(vaultRoot: tempDir)
        let loaded = try VaporVaultDecoder.loadIdentities(paths: paths)

        XCTAssertEqual(loaded, identities)
        let loadedIdentity = try VaporVaultDecoder.identity(forContext: "Scaffold", paths: paths)
        XCTAssertEqual(loadedIdentity.uuid, "admin-uuid")
    }

    func testBuildSignedScaffoldTrustRootDescriptorVerifies() throws {
        let seed = Ed25519.generateSeed()
        let keyPair = try Ed25519KeyPair(seed: seed)
        let admin = VaporVaultIdentityRecord(
            uuid: "admin-uuid",
            displayName: "Admin",
            identityContext: "Scaffold",
            publicKey: keyPair.publicKeyData,
            privateKey: seed
        )

        let descriptor = try ScaffoldTrustRootDescriptorBuilder.buildSignedDescriptor(
            scaffoldDomain: "staging.haven.digipomps.org",
            adminIdentity: admin,
            descriptorID: "trd_0001",
            issuedAt: Date(timeIntervalSince1970: 1_762_700_000),
            expiresAt: Date(timeIntervalSince1970: 1_765_292_000),
            resolverPublicKeys: [Base64URL.encode(keyPair.publicKeyData)],
            bridgeOwnerPublicKeys: ["bridge_owner_key"],
            starterBootstrapURL: URL(string: "https://staging.haven.digipomps.org/v1/resolver/starter-auth/intent")!,
            bridgeDiscoveryURL: URL(string: "https://staging.haven.digipomps.org/v1/bridges/query")!,
            resolverBaseURL: URL(string: "https://staging.haven.digipomps.org")!
        )

        XCTAssertEqual(descriptor.scaffold_admin_public_key, Base64URL.encode(keyPair.publicKeyData))
        XCTAssertTrue(try descriptor.verifySignature())
    }

    func testCurrentV2VaultExplicitlyRefusesSigningWithoutActiveOwnerBinding() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let masterKeyData = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let masterKeyURL = temporaryDirectory.appendingPathComponent("synthetic-master.key")
        try masterKeyData.write(to: masterKeyURL)
        let seed = Ed25519.generateSeed()
        let admin = VaporVaultIdentityRecord(uuid: "synthetic-v2-owner", displayName: "Synthetic owner",
            identityContext: "Scaffold", publicKey: try Ed25519KeyPair(seed: seed).publicKeyData, privateKey: seed)
        struct CurrentEnvelope: Encodable {
            let schema = "haven.vapor-identity-vault.v2"
            let fileVersion: UInt64 = 1
            let identities: [VaporVaultIdentityRecord]
        }
        let plaintext = try JSONEncoder().encode(CurrentEnvelope(identities: [admin]))
        let encrypted = try encryptVault(plaintext: plaintext, masterKeyData: masterKeyData)
        let vaultURL = temporaryDirectory.appendingPathComponent("OrganisationIdentities.crypt")
        try encrypted.write(to: vaultURL)
        let paths = VaporVaultPaths(vaultFileURL: vaultURL, masterKeyFileURL: masterKeyURL)
        XCTAssertThrowsError(try VaporVaultDecoder.loadIdentities(paths: paths)) {
            XCTAssertEqual($0 as? VaporVaultError, .currentVaultRequiresOwnerBinding)
            XCTAssertTrue(String(describing: $0).contains("verified active-owner binding"))
        }
        XCTAssertThrowsError(try VaporVaultDecoder.identity(forContext: "Scaffold", paths: paths)) {
            XCTAssertEqual($0 as? VaporVaultError, .currentVaultRequiresOwnerBinding)
        }
        XCTAssertEqual(try Data(contentsOf: vaultURL), encrypted)
        XCTAssertEqual(try Data(contentsOf: masterKeyURL), masterKeyData)
    }

    private func encryptVault(identities: [VaporVaultIdentityRecord], masterKeyData: Data) throws -> Data {
        try encryptVault(plaintext: JSONEncoder().encode(identities), masterKeyData: masterKeyData)
    }

    private func encryptVault(plaintext: Data, masterKeyData: Data) throws -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKeyData),
            salt: Data("CellScaffoldVaultSalt.v1".utf8),
            info: Data("OrganisationIdentities.crypt".utf8),
            outputByteCount: 32
        )
        let aad = Data("cell-vault-v1:OrganisationIdentities.crypt".utf8)
        let sealed = try ChaChaPoly.seal(plaintext, using: key, authenticating: aad)
        let nonceData = sealed.nonce.withUnsafeBytes { Data($0) }
        var output = Data("CVLT1".utf8)
        output.append(nonceData)
        output.append(sealed.ciphertext)
        output.append(sealed.tag)
        return output
    }
}
