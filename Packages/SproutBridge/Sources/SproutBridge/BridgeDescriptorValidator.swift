import Foundation
import SproutCrypto

public enum BridgeDescriptorValidationError: Error, Equatable, Sendable {
    case invalidEndpoint
    case wrongDomain(expected: String, actual: String)
    case expired
    case purposeNotAllowed(String)
    case unsupportedSignatureAlgorithm(String)
    case signatureInvalid
}

public struct BridgeDescriptorValidationContext: Sendable {
    public var expectedDomain: String
    public var requiredPurpose: String
    public var now: Date

    public init(expectedDomain: String, requiredPurpose: String, now: Date = Date()) {
        self.expectedDomain = expectedDomain
        self.requiredPurpose = requiredPurpose
        self.now = now
    }
}

public struct BridgeDescriptorValidator: Sendable {
    public init() {}

    public func validate(
        descriptor: BridgeDescriptor,
        context: BridgeDescriptorValidationContext
    ) throws {
        guard let endpoint = URL(string: descriptor.bridge_endpoint),
              let scheme = endpoint.scheme?.lowercased(),
              scheme == "wss" || scheme == "https"
        else {
            throw BridgeDescriptorValidationError.invalidEndpoint
        }

        guard descriptor.scaffold_domain == context.expectedDomain else {
            throw BridgeDescriptorValidationError.wrongDomain(
                expected: context.expectedDomain,
                actual: descriptor.scaffold_domain
            )
        }

        guard descriptor.purpose_constraints.contains(context.requiredPurpose) else {
            throw BridgeDescriptorValidationError.purposeNotAllowed(context.requiredPurpose)
        }

        let formatter = ISO8601DateFormatter()
        guard let expiry = formatter.date(from: descriptor.expires_at), expiry > context.now else {
            throw BridgeDescriptorValidationError.expired
        }

        guard descriptor.signature.alg == "Ed25519" else {
            throw BridgeDescriptorValidationError.unsupportedSignatureAlgorithm(descriptor.signature.alg)
        }

        let payload = try descriptor.canonicalPayloadData()
        let verified = Ed25519.verifyBase64URL(
            data: payload,
            signatureBase64URL: descriptor.signature.sig,
            publicKeyBase64URL: descriptor.owner_pubkey
        )
        guard verified else {
            throw BridgeDescriptorValidationError.signatureInvalid
        }
    }
}
