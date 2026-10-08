import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import SproutCrypto
import SproutResolverAdapter

/// Independently verified operator input from the active runtime's owner binding and
/// encrypted-vault revision. Never derive these pins from the candidate input itself.
public struct ScaffoldTrustRootSameOwnerRenewalOwnerPins: Sendable {
    public let uuid: String
    public let context: String
    public let signingKeyFingerprintDigest: String
    public let encryptedVaultSHA256: String

    public init(uuid: String, context: String, signingKeyFingerprintDigest: String, encryptedVaultSHA256: String) {
        self.uuid = uuid
        self.context = context
        self.signingKeyFingerprintDigest = signingKeyFingerprintDigest
        self.encryptedVaultSHA256 = encryptedVaultSHA256
    }
}

public enum ScaffoldTrustRootSameOwnerRenewalError: Error, Equatable, CustomStringConvertible {
    case invalidPins, descriptorDigestMismatch, vaultDigestMismatch, invalidVault
    case ownerBindingMismatch, differentSigner, invalidApprovedKeys, invalidValidity, invalidDescriptorID
    case unreadableInput

    public var description: String {
        switch self {
        case .invalidPins: return "Renewal requires explicit valid current-owner UUID, Scaffold context, fingerprint digest, and lowercase SHA256 input pins."
        case .descriptorDigestMismatch: return "The existing public descriptor does not match the reviewed SHA256 pin."
        case .vaultDigestMismatch: return "The encrypted vault does not match the independently verified active runtime revision."
        case .invalidVault: return "The pinned input is not a valid current v2 vault with unique identities and consistent key material."
        case .ownerBindingMismatch: return "The pinned current-owner UUID, context and signing-key fingerprint do not match the vault."
        case .differentSigner: return "Renewal requires the same active Scaffold signer."
        case .invalidApprovedKeys: return "Renewal requires explicit nonempty, distinct canonical Ed25519 resolver and bridge-owner public keys."
        case .invalidValidity: return "Renewal requires valid historical dates and a new expiry after now, within 30 days of issuance."
        case .invalidDescriptorID: return "Renewal requires a new nonempty descriptor ID."
        case .unreadableInput: return "Unable to read a bounded renewal input file."
        }
    }
}

/// Purpose: purpose://access.audit.privacy and purpose://scaffold.operations.
/// This standalone operator path returns only a public descriptor. It neither exposes a v2
/// identity loader nor changes ordinary vault loading, runtime admission, or manifest authority.
public enum ScaffoldTrustRootSameOwnerRenewal {
    public static func renew(
        descriptorData: Data,
        expectedDescriptorSHA256: String,
        expectedDomain: String,
        vaultPaths: VaporVaultPaths,
        ownerPins: ScaffoldTrustRootSameOwnerRenewalOwnerPins,
        descriptorID: String,
        expiresAt: Date,
        now: Date = Date()
    ) throws -> ScaffoldAdminTrustRootDescriptor {
        guard UUID(uuidString: ownerPins.uuid) != nil,
              ownerPins.context == "Scaffold",
              isSHA256(ownerPins.encryptedVaultSHA256), isSHA256(expectedDescriptorSHA256),
              let fingerprint = try? Base64URL.decode(ownerPins.signingKeyFingerprintDigest),
              fingerprint.count == 32, Base64URL.encode(fingerprint) == ownerPins.signingKeyFingerprintDigest else {
            throw ScaffoldTrustRootSameOwnerRenewalError.invalidPins
        }
        guard descriptorData.count <= 1_048_576,
              sha256Hex(descriptorData) == expectedDescriptorSHA256 else {
            throw ScaffoldTrustRootSameOwnerRenewalError.descriptorDigestMismatch
        }
        let previous = try ScaffoldTrustRootDescriptorBuilder.decodeDescriptorForRenewal(from: descriptorData)
        guard previous.version == "1.0" else {
            throw ScaffoldTrustRootRenewalError.unsupportedVersion(previous.version)
        }
        let formatter = ISO8601DateFormatter()
        guard now.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > now, expiresAt.timeIntervalSince(now) <= ScaffoldTrustRootDescriptorBuilder.maximumRenewalValidity,
              let previousIssued = formatter.date(from: previous.issued_at),
              let previousExpiry = formatter.date(from: previous.expires_at),
              previousIssued < previousExpiry, previousIssued <= now, expiresAt > previousExpiry else {
            throw ScaffoldTrustRootSameOwnerRenewalError.invalidValidity
        }
        // Historical authenticity of the reviewed descriptor, including its domain. An expired
        // input is accepted only here; it is not granted current runtime authority.
        try ScaffoldAdminTrustRootDescriptorValidator().validate(
            descriptor: previous, context: .init(expectedDomain: expectedDomain, now: previousIssued))
        guard canonicalToken(descriptorID, maximum: 256), descriptorID != previous.descriptor_id else {
            throw ScaffoldTrustRootSameOwnerRenewalError.invalidDescriptorID
        }
        guard validApprovedKeys(previous.resolver_public_keys), validApprovedKeys(previous.bridge_owner_public_keys) else {
            throw ScaffoldTrustRootSameOwnerRenewalError.invalidApprovedKeys
        }
        let issuedString = formatter.string(from: now)
        let expiryString = formatter.string(from: expiresAt)
        guard let issued = formatter.date(from: issuedString), let expiry = formatter.date(from: expiryString),
              expiry > now, expiry > previousExpiry, expiry.timeIntervalSince(issued) <= ScaffoldTrustRootDescriptorBuilder.maximumRenewalValidity else {
            throw ScaffoldTrustRootSameOwnerRenewalError.invalidValidity
        }

        // Read one immutable snapshot, bind it before decryption, and never retry another vault.
        let encrypted = try boundedRead(vaultPaths.vaultFileURL, maximum: 64 * 1_024 * 1_024)
        guard sha256Hex(encrypted) == ownerPins.encryptedVaultSHA256 else {
            throw ScaffoldTrustRootSameOwnerRenewalError.vaultDigestMismatch
        }
        let identities = try decodePinnedV2Vault(encrypted, masterKeyURL: vaultPaths.masterKeyFileURL)
        guard let owner = identities.first(where: { $0.uuid == ownerPins.uuid && $0.identityContext == ownerPins.context }),
              Hashing.sha256Base64URL(Data("EdDSA:Curve25519:\(owner.publicKey.base64EncodedString())".utf8))
                == ownerPins.signingKeyFingerprintDigest else {
            throw ScaffoldTrustRootSameOwnerRenewalError.ownerBindingMismatch
        }
        guard let previousKey = try? Base64URL.decode(previous.scaffold_admin_public_key),
              previousKey == owner.publicKey else {
            throw ScaffoldTrustRootSameOwnerRenewalError.differentSigner
        }
        var renewed = previous
        renewed.descriptor_id = descriptorID
        renewed.issued_at = issuedString
        renewed.expires_at = expiryString
        renewed.signature = .init(alg: "Ed25519", sig: try Ed25519.signBase64URL(
            data: renewed.canonicalPayloadData(), seedBase64URL: Base64URL.encode(owner.privateKey)))
        try ScaffoldAdminTrustRootDescriptorValidator().validate(
            descriptor: renewed, context: .init(expectedDomain: expectedDomain, now: now))
        guard sha256Hex(try boundedRead(vaultPaths.vaultFileURL, maximum: 64 * 1_024 * 1_024)) == ownerPins.encryptedVaultSHA256 else {
            throw ScaffoldTrustRootSameOwnerRenewalError.vaultDigestMismatch
        }
        return renewed
    }

    private struct Envelope: Decodable {
        let schema: String
        let fileVersion: UInt64
        let identities: [IdentityRecord]
    }

    /// Matches the signing and key-agreement fields of CellVapor's v2 StrictVaultIdentityRecord.
    /// Properties/privateProperties are neither authority input nor exported by this operation.
    private struct IdentityRecord: Decodable {
        let uuid: String
        let displayName: String
        let identityContext: String
        let publicKey: Data
        let privateKey: Data
        let keyAgreementPublicKey: Data
        let keyAgreementPrivateKey: Data
        let publicSecureKey: KeyRecord
        let privateSecureKey: KeyRecord
        let publicKeyAgreementSecureKey: KeyRecord
        let privateKeyAgreementSecureKey: KeyRecord

        func validate() throws {
            guard ScaffoldTrustRootSameOwnerRenewal.canonicalToken(uuid, maximum: 256),
                  ScaffoldTrustRootSameOwnerRenewal.canonicalToken(identityContext, maximum: 1_024),
                  publicSecureKey.matches(publicKey, privateKey: false, use: "signature", algorithm: "EdDSA"),
                  privateSecureKey.matches(privateKey, privateKey: true, use: "signature", algorithm: "EdDSA"),
                  publicKeyAgreementSecureKey.matches(keyAgreementPublicKey, privateKey: false, use: "keyAgreement", algorithm: "X25519"),
                  privateKeyAgreementSecureKey.matches(keyAgreementPrivateKey, privateKey: true, use: "keyAgreement", algorithm: "X25519"),
                  try Ed25519KeyPair(seed: privateKey).publicKeyData == publicKey,
                  try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyAgreementPrivateKey).publicKey.rawRepresentation == keyAgreementPublicKey else {
                throw ScaffoldTrustRootSameOwnerRenewalError.invalidVault
            }
        }
    }

    private struct KeyRecord: Decodable {
        let date: Date
        let privateKey: Bool
        let use: String
        let algorithm: String
        let size: Int
        let curveType: String
        let compressedKey: Data

        func matches(_ key: Data, privateKey expectedPrivate: Bool, use expectedUse: String, algorithm expectedAlgorithm: String) -> Bool {
            key.count == 32 && compressedKey == key && privateKey == expectedPrivate && use == expectedUse
                && algorithm == expectedAlgorithm && curveType == "Curve25519" && size == 256
        }
    }

    private static func decodePinnedV2Vault(_ encrypted: Data, masterKeyURL: URL) throws -> [IdentityRecord] {
        do {
            let storedKey = try boundedRead(masterKeyURL, maximum: 4_096)
            let masterKey: Data
            if storedKey.count == 32 {
                masterKey = storedKey
            } else if let string = String(data: storedKey, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let decoded = Data(base64Encoded: string), decoded.count == 32 {
                masterKey = decoded
            } else {
                throw ScaffoldTrustRootSameOwnerRenewalError.invalidVault
            }
            guard encrypted.starts(with: Data("CVLT1".utf8)), encrypted.count >= 5 + 12 + 16 else {
                throw ScaffoldTrustRootSameOwnerRenewalError.invalidVault
            }
            let scope = "OrganisationIdentities.crypt"
            let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: masterKey),
                salt: Data("CellScaffoldVaultSalt.v1".utf8), info: Data(scope.utf8), outputByteCount: 32)
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: encrypted[5..<17]),
                ciphertext: encrypted[17..<(encrypted.count - 16)], tag: encrypted.suffix(16))
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: Data("cell-vault-v1:\(scope)".utf8))
            let document = try JSONDecoder().decode(Envelope.self, from: plaintext)
            guard document.schema == "haven.vapor-identity-vault.v2", document.fileVersion > 0,
                  !document.identities.isEmpty, document.identities.count <= 100_000 else {
                throw ScaffoldTrustRootSameOwnerRenewalError.invalidVault
            }
            var uuids = Set<String>()
            var contexts = Set<String>()
            for identity in document.identities {
                guard uuids.insert(identity.uuid).inserted, contexts.insert(identity.identityContext).inserted else {
                    throw ScaffoldTrustRootSameOwnerRenewalError.invalidVault
                }
                try identity.validate()
            }
            return document.identities
        } catch {
            // Decrypted record names, properties, key material and decoder diagnostics never escape.
            throw ScaffoldTrustRootSameOwnerRenewalError.invalidVault
        }
    }

    private static func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            guard size <= maximum else { throw ScaffoldTrustRootSameOwnerRenewalError.unreadableInput }
            try handle.seek(toOffset: 0)
            let data = try handle.read(upToCount: maximum + 1) ?? Data()
            guard data.count == size else { throw ScaffoldTrustRootSameOwnerRenewalError.unreadableInput }
            return data
        } catch {
            throw ScaffoldTrustRootSameOwnerRenewalError.unreadableInput
        }
    }

    private static func canonicalToken(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func validApprovedKeys(_ keys: [String]) -> Bool {
        !keys.isEmpty && keys.count <= 256 && Set(keys).count == keys.count && keys.allSatisfy { key in
            guard let data = try? Base64URL.decode(key) else { return false }
            return data.count == 32 && Base64URL.encode(data) == key
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func sha256Hex(_ data: Data) -> String {
        Hashing.sha256(data).map { String(format: "%02x", $0) }.joined()
    }
}
