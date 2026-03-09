import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum Ed25519Error: Error, Equatable {
    case invalidSeedLength(Int)
    case invalidPublicKeyLength(Int)
    case signingFailed
    case invalidBase64URL
}

public struct Ed25519KeyPair {
    public let privateKey: Curve25519.Signing.PrivateKey

    public init(seed: Data) throws {
        guard seed.count == 32 else {
            throw Ed25519Error.invalidSeedLength(seed.count)
        }
        self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    public var publicKeyData: Data {
        privateKey.publicKey.rawRepresentation
    }

    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data)
    }
}

public enum Ed25519 {
    public static func generateSeed() -> Data {
        Curve25519.Signing.PrivateKey().rawRepresentation
    }

    public static func generateSeedBase64URL() -> String {
        Base64URL.encode(generateSeed())
    }

    public static func publicKeyBase64URL(fromSeed seed: Data) throws -> String {
        let keyPair = try Ed25519KeyPair(seed: seed)
        return Base64URL.encode(keyPair.publicKeyData)
    }

    public static func publicKeyBase64URL(fromSeedBase64URL seedBase64URL: String) throws -> String {
        let seed: Data
        do {
            seed = try Base64URL.decode(seedBase64URL)
        } catch {
            throw Ed25519Error.invalidBase64URL
        }
        return try publicKeyBase64URL(fromSeed: seed)
    }

    public static func signBase64URL(data: Data, seedBase64URL: String) throws -> String {
        let seed: Data
        do {
            seed = try Base64URL.decode(seedBase64URL)
        } catch {
            throw Ed25519Error.invalidBase64URL
        }
        let keyPair = try Ed25519KeyPair(seed: seed)
        let signature = try keyPair.sign(data)
        return Base64URL.encode(signature)
    }

    public static func verify(data: Data, signature: Data, publicKey: Data) -> Bool {
        guard publicKey.count == 32 else {
            return false
        }
        do {
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            return key.isValidSignature(signature, for: data)
        } catch {
            return false
        }
    }

    public static func verifyBase64URL(data: Data, signatureBase64URL: String, publicKeyBase64URL: String) -> Bool {
        guard
            let signature = try? Base64URL.decode(signatureBase64URL),
            let publicKey = try? Base64URL.decode(publicKeyBase64URL)
        else {
            return false
        }
        return verify(data: data, signature: signature, publicKey: publicKey)
    }
}
