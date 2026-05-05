import Foundation
import CryptoKit
import SproutCrypto

public struct EntityLinkRevocation: Codable, Equatable, Sendable {
    public var mode: String

    public init(mode: String) {
        self.mode = mode
    }
}

public struct EntityLinkSignature: Codable, Equatable, Sendable {
    public var by_pubkey: String
    public var alg: String
    public var sig: String

    public init(by_pubkey: String, alg: String, sig: String) {
        self.by_pubkey = by_pubkey
        self.alg = alg
        self.sig = sig
    }
}

public struct EntityLinkContract: Codable, Equatable, Sendable {
    public var contract_id: String
    public var domain_a: String
    public var pubkey_a: String
    public var domain_b: String
    public var pubkey_b: String
    public var scope: String
    public var created_at: String
    public var revocation: EntityLinkRevocation
    public var signatures: [EntityLinkSignature]

    public init(
        contract_id: String,
        domain_a: String,
        pubkey_a: String,
        domain_b: String,
        pubkey_b: String,
        scope: String,
        created_at: String,
        revocation: EntityLinkRevocation,
        signatures: [EntityLinkSignature]
    ) {
        self.contract_id = contract_id
        self.domain_a = domain_a
        self.pubkey_a = pubkey_a
        self.domain_b = domain_b
        self.pubkey_b = pubkey_b
        self.scope = scope
        self.created_at = created_at
        self.revocation = revocation
        self.signatures = signatures
    }

    public func canonicalPayloadData() throws -> Data {
        let encoded = try JSONEncoder().encode(self)
        return try JCSCanonicalizer.canonicalizeRemovingTopLevelKeys(encoded, keys: ["signatures"])
    }

    public func verifyMutualSignatures() throws -> Bool {
        let canonical = try canonicalPayloadData()
        let requiredKeys: Set<String> = [pubkey_a, pubkey_b]

        guard signatures.count >= 2 else {
            return false
        }

        var verifiedKeys = Set<String>()
        for signature in signatures {
            guard requiredKeys.contains(signature.by_pubkey) else {
                return false
            }
            let valid = verifySignature(signature, canonical: canonical)
            guard valid else {
                return false
            }
            verifiedKeys.insert(signature.by_pubkey)
        }

        return verifiedKeys == requiredKeys
    }

    private func verifySignature(_ signature: EntityLinkSignature, canonical: Data) -> Bool {
        switch signature.alg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ed25519":
            return Ed25519.verifyBase64URL(
                data: canonical,
                signatureBase64URL: signature.sig,
                publicKeyBase64URL: signature.by_pubkey
            )
        case "p256-es256", "es256":
            do {
                let publicKeyData = try Base64URL.decode(signature.by_pubkey)
                let signatureData = try Base64URL.decode(signature.sig)
                let publicKey = try P256.Signing.PublicKey(x963Representation: publicKeyData)
                let ecdsaSignature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
                return publicKey.isValidSignature(ecdsaSignature, for: canonical)
            } catch {
                return false
            }
        default:
            return false
        }
    }
}

public enum EntityLinkContractIO {
    public static func load(from fileURL: URL) throws -> EntityLinkContract {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(EntityLinkContract.self, from: data)
    }

    public static func saveCanonical(_ contract: EntityLinkContract, to fileURL: URL) throws {
        let canonical = try contract.canonicalPayloadData()
        try canonical.write(to: fileURL, options: [.atomic])
    }
}
