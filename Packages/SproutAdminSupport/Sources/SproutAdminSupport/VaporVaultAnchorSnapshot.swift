import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import SproutCore
import SproutCrypto
import SproutResolverAdapter

public enum VaporVaultError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidMasterKey
    case unsupportedLegacyVaultFormat
    case invalidEncryptedVault
    case identityContextNotFound(String)
    case currentVaultRequiresOwnerBinding

    public var description: String {
        switch self {
        case .invalidMasterKey: return "Invalid vault master key."
        case .unsupportedLegacyVaultFormat: return "Unsupported encrypted vault format."
        case .invalidEncryptedVault: return "Invalid encrypted vault."
        case .identityContextNotFound(let context): return "Vault identity context not found: \(context)."
        case .currentVaultRequiresOwnerBinding:
            return "Current v2 vault signing requires verified active-owner binding support, which is unavailable in this command. Do not fall back to a legacy vault."
        }
    }
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
    private struct VaultSchemaHeader: Decodable {
        let schema: String
    }

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
        // Current CellVapor vaults carry a versioned envelope and an owner-signed
        // runtime binding. Refuse explicitly until this operator path can verify
        // that active owner; never unwrap it into the legacy signing path.
        if let header = try? JSONDecoder().decode(VaultSchemaHeader.self, from: plaintext),
           header.schema == "haven.vapor-identity-vault.v2" {
            throw VaporVaultError.currentVaultRequiresOwnerBinding
        }
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

public enum EntityAnchorSnapshotUpdateError: Error, LocalizedError {
    case invalidSnapshotSignature
    case invalidEntityLinkSignature
    case scaffoldDomainMismatch(expected: String, actual: String)
    case entityIDNotFound(String)
    case anchoredIdentityNotFound(String)
    case anchoredIdentityDoesNotMatchEntityLink(String)
    case ambiguousAnchoredIdentity([String])
    case adminIdentityMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshotSignature:
            return "Existing entity anchor snapshot signature did not verify."
        case .invalidEntityLinkSignature:
            return "Entity-link contract mutual signatures did not verify."
        case .scaffoldDomainMismatch(let expected, let actual):
            return "Entity-link scaffold domain mismatch. Expected \(expected), got \(actual)."
        case .entityIDNotFound(let entityID):
            return "Entity \(entityID) was not found in the existing entity anchor snapshot."
        case .anchoredIdentityNotFound(let publicKey):
            return "Anchored identity \(publicKey) was not found in the existing entity anchor snapshot."
        case .anchoredIdentityDoesNotMatchEntityLink(let publicKey):
            return "Anchored identity \(publicKey) is not part of the supplied entity-link contract."
        case .ambiguousAnchoredIdentity(let entityIDs):
            return "More than one entity anchor record matches the supplied entity-link contract: \(entityIDs.joined(separator: ", "))."
        case .adminIdentityMismatch(let expected, let actual):
            return "Admin identity public key mismatch. Expected \(expected), got \(actual)."
        }
    }
}

public enum EntityAnchorSnapshotUpdater {
    public static func acceptingEntityLink(
        snapshot: EntityAnchorSnapshot,
        entityLink: EntityLinkContract,
        adminIdentity: VaporVaultIdentityRecord,
        snapshotID: String? = nil,
        issuedAt: Date,
        expiresAt: Date,
        entityID: String? = nil,
        anchoredIdentityPublicKey: String? = nil,
        anchoredIdentityDomain: String? = nil
    ) throws -> EntityAnchorSnapshot {
        guard try snapshot.verifySignature() else {
            throw EntityAnchorSnapshotUpdateError.invalidSnapshotSignature
        }
        guard try entityLink.verifyMutualSignatures() else {
            throw EntityAnchorSnapshotUpdateError.invalidEntityLinkSignature
        }
        guard entityLink.domain_a == snapshot.scaffold_domain,
              entityLink.domain_b == snapshot.scaffold_domain else {
            throw EntityAnchorSnapshotUpdateError.scaffoldDomainMismatch(
                expected: snapshot.scaffold_domain,
                actual: "\(entityLink.domain_a),\(entityLink.domain_b)"
            )
        }

        let adminPublicKey = Base64URL.encode(adminIdentity.publicKey)
        guard snapshot.admin_public_key == adminPublicKey else {
            throw EntityAnchorSnapshotUpdateError.adminIdentityMismatch(
                expected: snapshot.admin_public_key,
                actual: adminPublicKey
            )
        }

        let targetEntityIndex = try resolveEntityIndex(
            in: snapshot,
            entityLink: entityLink,
            entityID: entityID,
            anchoredIdentityPublicKey: anchoredIdentityPublicKey,
            anchoredIdentityDomain: anchoredIdentityDomain
        )
        var entities = snapshot.entities
        var record = entities[targetEntityIndex]
        let acceptedIDs = Set(record.accepted_entity_link_contract_ids + [entityLink.contract_id])
        record.accepted_entity_link_contract_ids = acceptedIDs.sorted()
        entities[targetEntityIndex] = record

        let nextSnapshotID = snapshotID ?? "\(snapshot.snapshot_id)-entity-link-\(entityLink.contract_id)"
        return try EntityAnchorSnapshotBuilder.buildSignedSnapshot(
            scaffoldDomain: snapshot.scaffold_domain,
            adminIdentity: adminIdentity,
            snapshotID: nextSnapshotID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            entities: entities
        )
    }

    private static func resolveEntityIndex(
        in snapshot: EntityAnchorSnapshot,
        entityLink: EntityLinkContract,
        entityID: String?,
        anchoredIdentityPublicKey: String?,
        anchoredIdentityDomain: String?
    ) throws -> Int {
        if let entityID, let index = snapshot.entities.firstIndex(where: { $0.entity_id == entityID }) {
            if let anchoredIdentityPublicKey {
                guard snapshot.entities[index].containsIdentity(
                    anchoredIdentityPublicKey,
                    domain: anchoredIdentityDomain ?? snapshot.scaffold_domain
                ) else {
                    throw EntityAnchorSnapshotUpdateError.anchoredIdentityNotFound(anchoredIdentityPublicKey)
                }
                guard [entityLink.pubkey_a, entityLink.pubkey_b].contains(anchoredIdentityPublicKey) else {
                    throw EntityAnchorSnapshotUpdateError.anchoredIdentityDoesNotMatchEntityLink(anchoredIdentityPublicKey)
                }
            }
            return index
        }
        if let entityID {
            throw EntityAnchorSnapshotUpdateError.entityIDNotFound(entityID)
        }

        if let anchoredIdentityPublicKey {
            guard let index = snapshot.entities.firstIndex(where: {
                $0.containsIdentity(anchoredIdentityPublicKey, domain: anchoredIdentityDomain ?? snapshot.scaffold_domain)
            }) else {
                throw EntityAnchorSnapshotUpdateError.anchoredIdentityNotFound(anchoredIdentityPublicKey)
            }
            guard [entityLink.pubkey_a, entityLink.pubkey_b].contains(anchoredIdentityPublicKey) else {
                throw EntityAnchorSnapshotUpdateError.anchoredIdentityDoesNotMatchEntityLink(anchoredIdentityPublicKey)
            }
            return index
        }

        let linkedKeys = Set([entityLink.pubkey_a, entityLink.pubkey_b])
        let matchingIndices = snapshot.entities.enumerated().compactMap { index, record -> Int? in
            let anchoredKeys = Set(record.identities.map(\.identity_public_key))
            return anchoredKeys.intersection(linkedKeys).isEmpty ? nil : index
        }
        guard let first = matchingIndices.first else {
            throw EntityAnchorSnapshotUpdateError.anchoredIdentityNotFound(entityLink.contract_id)
        }
        guard matchingIndices.count == 1 else {
            throw EntityAnchorSnapshotUpdateError.ambiguousAnchoredIdentity(
                matchingIndices.map { snapshot.entities[$0].entity_id }
            )
        }
        return first
    }
}
