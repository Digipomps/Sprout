import Foundation
import SproutCrypto

public struct SignatureEnvelope: Codable, Equatable, Sendable {
    public var alg: String
    public var sig: String

    public init(alg: String, sig: String) {
        self.alg = alg
        self.sig = sig
    }
}

public struct BridgeDescriptor: Codable, Equatable, Sendable {
    public var descriptor_id: String
    public var bridge_endpoint: String
    public var scaffold_domain: String
    public var owner_pubkey: String
    public var capability_requirements: [String]
    public var purpose_constraints: [String]
    public var expires_at: String
    public var signature: SignatureEnvelope

    public init(
        descriptor_id: String,
        bridge_endpoint: String,
        scaffold_domain: String,
        owner_pubkey: String,
        capability_requirements: [String],
        purpose_constraints: [String],
        expires_at: String,
        signature: SignatureEnvelope
    ) {
        self.descriptor_id = descriptor_id
        self.bridge_endpoint = bridge_endpoint
        self.scaffold_domain = scaffold_domain
        self.owner_pubkey = owner_pubkey
        self.capability_requirements = capability_requirements
        self.purpose_constraints = purpose_constraints
        self.expires_at = expires_at
        self.signature = signature
    }

    public func canonicalPayloadData() throws -> Data {
        let encoded = try JSONEncoder.sorted.encode(self)
        return try JCSCanonicalizer.canonicalizeRemovingTopLevelKeys(encoded, keys: ["signature"])
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        if #available(macOS 10.13, iOS 11.0, *) {
            encoder.outputFormatting = [.sortedKeys]
        }
        return encoder
    }
}

extension JSONDecoder {
    static var plain: JSONDecoder {
        JSONDecoder()
    }
}
