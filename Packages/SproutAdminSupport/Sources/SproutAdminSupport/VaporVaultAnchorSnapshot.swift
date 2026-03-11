import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import SproutCrypto
import SproutResolverAdapter

public enum VaporVaultError: Error, Equatable, Sendable {
    case invalidMasterKey
    case unsupportedLegacyVaultFormat
    case invalidEncryptedVault
    case identityContextNotFound(String)
}

public struct VaporVaultIdentityRecord: Codable, Equatable, Sendable {
    public var uuid: String
    public var displayName: String
    public var identityContext: String?
    public var publicKey: Data
    public var privateKey: Data

    public init(
        uuid: String,
        displayName: String,
        identityContext: String?,
        publicKey: Data,
        privateKey: Data
    ) {
        self.uuid = uuid
        self.displayName = displayName
        self.identityContext = identityContext
        self.publicKey = publicKey
        self.privateKey = privateKey
    }

    public var publicKeyBase64URL: String {
        Base64URL.encode(publicKey)
    }
}

public struct VaporVaultPaths: Equatable, Sendable {
    public var vaultFileURL: URL
    public var masterKeyFileURL: URL

    public init(vaultFileURL: URL, masterKeyFileURL: URL) {
        self.vaultFileURL = vaultFileURL
        self.masterKeyFileURL = masterKeyFileURL
    }
}

public enum VaporVaultDecoder {
    private static let vaultFilename = "OrganisationIdentities.crypt"
    private static let defaultMasterKeyFilename = "vault-master.key"
    private static let vaultMagic = Data("CVLT1".utf8)
    private static let vaultScope = "OrganisationIdentities.crypt"
    private static let nonceLength = 12
    private static let tagLength = 16
    private static let hkdfSalt = Data("CellScaffoldVaultSalt.v1".utf8)

    public static func resolvePaths(
        vaultRoot: URL,
        vaultFileURL: URL? = nil,
        masterKeyFileURL: URL? = nil
    ) -> VaporVaultPaths {
        VaporVaultPaths(
            vaultFileURL: vaultFileURL ?? vaultRoot.appendingPathComponent(vaultFilename),
            masterKeyFileURL: masterKeyFileURL ?? vaultRoot.appendingPathComponent(".secrets/\(defaultMasterKeyFilename)")
        )
    }

    public static func loadIdentities(paths: VaporVaultPaths) throws -> [VaporVaultIdentityRecord] {
        let encryptedVault = try Data(contentsOf: paths.vaultFileURL)
        let masterKeyData = try loadMasterKeyData(from: paths.masterKeyFileURL)
        let plaintext = try decryptVaultData(encryptedVault, masterKeyData: masterKeyData, scope: vaultScope)
        return try JSONDecoder().decode([VaporVaultIdentityRecord].self, from: plaintext)
    }

    public static func identity(
        forContext identityContext: String,
        paths: VaporVaultPaths
    ) throws -> VaporVaultIdentityRecord {
        let identities = try loadIdentities(paths: paths)
        guard let record = identities.first(where: { $0.identityContext == identityContext }) else {
            throw VaporVaultError.identityContextNotFound(identityContext)
        }
        return record
    }

    private static func loadMasterKeyData(from fileURL: URL) throws -> Data {
        let storedData = try Data(contentsOf: fileURL)
        if storedData.count == 32 {
            return storedData
        }
        if let string = String(data: storedData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let decoded = Data(base64Encoded: string),
           decoded.count == 32 {
            return decoded
        }
        throw VaporVaultError.invalidMasterKey
    }

    private static func decryptVaultData(
        _ encryptedData: Data,
        masterKeyData: Data,
        scope: String
    ) throws -> Data {
        guard encryptedData.starts(with: vaultMagic) else {
            throw VaporVaultError.unsupportedLegacyVaultFormat
        }

        let minimumLength = vaultMagic.count + nonceLength + tagLength
        guard encryptedData.count >= minimumLength else {
            throw VaporVaultError.invalidEncryptedVault
        }

        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKeyData),
            salt: hkdfSalt,
            info: Data(scope.utf8),
            outputByteCount: 32
        )
        let aad = Data("cell-vault-v1:\(scope)".utf8)
        let headerSize = vaultMagic.count
        let nonceRange = headerSize..<(headerSize + nonceLength)
        let tagRange = (encryptedData.count - tagLength)..<encryptedData.count
        let ciphertextRange = nonceRange.upperBound..<tagRange.lowerBound

        let nonce = try ChaChaPoly.Nonce(data: encryptedData[nonceRange])
        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: encryptedData[ciphertextRange],
            tag: encryptedData[tagRange]
        )
        return try ChaChaPoly.open(sealedBox, using: key, authenticating: aad)
    }
}

public enum EntityAnchorSnapshotBuilder {
    public static func buildSignedSnapshot(
        scaffoldDomain: String,
        adminIdentity: VaporVaultIdentityRecord,
        snapshotID: String,
        issuedAt: Date,
        expiresAt: Date,
        entities: [EntityAnchorEntityRecord]
    ) throws -> EntityAnchorSnapshot {
        let formatter = ISO8601DateFormatter()
        var snapshot = EntityAnchorSnapshot(
            snapshot_id: snapshotID,
            scaffold_domain: scaffoldDomain,
            admin_public_key: adminIdentity.publicKeyBase64URL,
            issued_at: formatter.string(from: issuedAt),
            expires_at: formatter.string(from: expiresAt),
            entities: entities,
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )
        snapshot.signature = ResolverSignatureEnvelope(
            alg: "Ed25519",
            sig: try Ed25519.signBase64URL(
                data: snapshot.canonicalPayloadData(),
                seedBase64URL: Base64URL.encode(adminIdentity.privateKey)
            )
        )
        return snapshot
    }
}
