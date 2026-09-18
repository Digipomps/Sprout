import Foundation
import SproutCrypto

public struct SproutDoctorReport: Codable, Equatable, Sendable {
    public let schema: String
    public let platform: String
    public let architecture: String
    public let cRuntime: String
    public let cryptography: String
    public let network: String
    public let identityStorage: String
    public let channelReadiness: String
}

public enum SproutDoctor {
    /// Local diagnostics only. Ephemeral crypto self-test keys are not persisted or enrolled.
    public static func inspect() throws -> SproutDoctorReport {
        let seed = Ed25519.generateSeed()
        let pair = try Ed25519KeyPair(seed: seed)
        let message = Data("sprout.local.crypto-self-test.v1".utf8)
        let signature = try pair.sign(message)
        guard Ed25519.verify(data: message, signature: signature, publicKey: pair.publicKeyData),
              !Ed25519.verify(data: Data("tampered".utf8), signature: signature, publicKey: pair.publicKeyData),
              try Base64URL.decode(Base64URL.encode(signature)) == signature else {
            throw Ed25519Error.signingFailed
        }
        #if os(Linux)
        let platform = "linux"
        #elseif os(macOS)
        let platform = "macos"
        #else
        let platform = "other"
        #endif
        #if arch(x86_64)
        let architecture = "x86_64"
        #elseif arch(arm64)
        let architecture = "aarch64"
        #else
        let architecture = "other"
        #endif
        #if canImport(Musl)
        let runtime = "musl"
        #elseif canImport(Glibc)
        let runtime = "glibc"
        #else
        let runtime = "darwin"
        #endif
        return SproutDoctorReport(schema: "sprout.doctor.v1", platform: platform,
            architecture: architecture, cRuntime: runtime, cryptography: "passed",
            network: "not_contacted", identityStorage: "not_read_or_created", channelReadiness: "not_verified")
    }
}
