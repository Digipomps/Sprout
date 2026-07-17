import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum P256ES256 {
    public static func verify(
        data: Data,
        derSignature: Data,
        x963PublicKey: Data
    ) -> Bool {
        do {
            let publicKey = try P256.Signing.PublicKey(x963Representation: x963PublicKey)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: derSignature)
            return publicKey.isValidSignature(signature, for: data)
        } catch {
            return false
        }
    }

    public static func verifyBase64URL(
        data: Data,
        derSignatureBase64URL: String,
        x963PublicKeyBase64URL: String
    ) -> Bool {
        guard
            let signature = try? Base64URL.decode(derSignatureBase64URL),
            let publicKey = try? Base64URL.decode(x963PublicKeyBase64URL)
        else {
            return false
        }
        return verify(data: data, derSignature: signature, x963PublicKey: publicKey)
    }
}
