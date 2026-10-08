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

/// Entirely synthetic fixture following CP 9c60001's encrypted v2 and SecureKey encoding.
final class SameOwnerFixture {
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
    func pins(uuid: String? = nil, context: String? = nil, fingerprint: String? = nil, vaultHash: String? = nil) -> ScaffoldTrustRootSameOwnerRenewalOwnerPins {
        .init(uuid: uuid ?? owner.uuid, context: context ?? "Scaffold",
            signingKeyFingerprintDigest: fingerprint ?? Hashing.sha256Base64URL(Data("EdDSA:Curve25519:\(owner.publicKey.base64EncodedString())".utf8)),
            encryptedVaultSHA256: vaultHash ?? self.vaultHash)
    }
    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    static func sha256(_ data: Data) -> String { Hashing.sha256(data).map { String(format: "%02x", $0) }.joined() }
}
