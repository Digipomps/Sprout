import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum Hashing {
    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func sha256Base64URL(_ data: Data) -> String {
        Base64URL.encode(sha256(data))
    }
}
