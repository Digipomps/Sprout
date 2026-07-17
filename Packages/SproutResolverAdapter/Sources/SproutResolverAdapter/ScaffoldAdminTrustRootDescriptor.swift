import Foundation
import SproutCrypto

public enum ScaffoldAdminTrustRootDescriptorValidationError: Error, Equatable, Sendable {
    case wrongDomain(expected: String, got: String)
    case invalidURL(String)
    case expired
    case unsupportedSignatureAlgorithm(String)
    case signatureInvalid
    case missingResolverPublicKeys
    case missingBridgeOwnerPublicKeys
    case missingScaffoldAdminPublicKey
}

public struct ScaffoldAdminTrustRootDescriptorValidationContext: Equatable, Sendable {
    public var expectedDomain: String
    public var now: Date

    public init(expectedDomain: String, now: Date = Date()) {
        self.expectedDomain = expectedDomain
        self.now = now
    }
}

public struct ScaffoldAdminTrustRootDescriptor: Codable, Equatable, Sendable {
    public var version: String
    public var descriptor_id: String
    public var scaffold_domain: String
    public var scaffold_admin_public_key: String
    public var resolver_public_keys: [String]
    public var bridge_owner_public_keys: [String]
    public var starter_bootstrap_url: String
    public var bridge_discovery_url: String
    public var resolver_base_url: String
    public var software_catalog_url: String?
    public var issued_at: String
    public var expires_at: String
    public var signature: ResolverSignatureEnvelope

    public init(
        version: String,
        descriptor_id: String,
        scaffold_domain: String,
        scaffold_admin_public_key: String,
        resolver_public_keys: [String],
        bridge_owner_public_keys: [String],
        starter_bootstrap_url: String,
        bridge_discovery_url: String,
        resolver_base_url: String,
        software_catalog_url: String? = nil,
        issued_at: String,
        expires_at: String,
        signature: ResolverSignatureEnvelope
    ) {
        self.version = version
        self.descriptor_id = descriptor_id
        self.scaffold_domain = scaffold_domain
        self.scaffold_admin_public_key = scaffold_admin_public_key
        self.resolver_public_keys = resolver_public_keys
        self.bridge_owner_public_keys = bridge_owner_public_keys
        self.starter_bootstrap_url = starter_bootstrap_url
        self.bridge_discovery_url = bridge_discovery_url
        self.resolver_base_url = resolver_base_url
        self.software_catalog_url = software_catalog_url
        self.issued_at = issued_at
        self.expires_at = expires_at
        self.signature = signature
    }

    public func canonicalPayloadData() throws -> Data {
        let encoded = try JSONEncoder.sorted.encode(self)
        return try JCSCanonicalizer.canonicalizeRemovingTopLevelKeys(encoded, keys: ["signature"])
    }

    public func verifySignature() throws -> Bool {
        guard signature.alg == "Ed25519" else {
            return false
        }
        return Ed25519.verifyBase64URL(
            data: try canonicalPayloadData(),
            signatureBase64URL: signature.sig,
            publicKeyBase64URL: scaffold_admin_public_key
        )
    }

    public func isExpired(now: Date = Date()) -> Bool {
        let formatter = ISO8601DateFormatter()
        guard let expiry = formatter.date(from: expires_at) else {
            return true
        }
        return now >= expiry
    }

    public func trustsBridgeOwner(_ publicKey: String) -> Bool {
        bridge_owner_public_keys.contains(publicKey)
    }

    public func trustsResolver(_ publicKey: String) -> Bool {
        resolver_public_keys.contains(publicKey)
    }
}

public struct ScaffoldAdminTrustRootDescriptorValidator: Sendable {
    public init() {}

    public func validate(
        descriptor: ScaffoldAdminTrustRootDescriptor,
        context: ScaffoldAdminTrustRootDescriptorValidationContext
    ) throws {
        guard descriptor.scaffold_domain == context.expectedDomain else {
            throw ScaffoldAdminTrustRootDescriptorValidationError.wrongDomain(
                expected: context.expectedDomain,
                got: descriptor.scaffold_domain
            )
        }
        guard !descriptor.scaffold_admin_public_key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScaffoldAdminTrustRootDescriptorValidationError.missingScaffoldAdminPublicKey
        }
        guard !descriptor.resolver_public_keys.isEmpty else {
            throw ScaffoldAdminTrustRootDescriptorValidationError.missingResolverPublicKeys
        }
        guard !descriptor.bridge_owner_public_keys.isEmpty else {
            throw ScaffoldAdminTrustRootDescriptorValidationError.missingBridgeOwnerPublicKeys
        }
        try validateURLString(descriptor.starter_bootstrap_url)
        try validateURLString(descriptor.bridge_discovery_url)
        try validateURLString(descriptor.resolver_base_url)
        if let softwareCatalogURL = descriptor.software_catalog_url {
            try validateURLString(softwareCatalogURL)
        }
        guard !descriptor.isExpired(now: context.now) else {
            throw ScaffoldAdminTrustRootDescriptorValidationError.expired
        }
        guard descriptor.signature.alg == "Ed25519" else {
            throw ScaffoldAdminTrustRootDescriptorValidationError.unsupportedSignatureAlgorithm(descriptor.signature.alg)
        }
        guard try descriptor.verifySignature() else {
            throw ScaffoldAdminTrustRootDescriptorValidationError.signatureInvalid
        }
    }

    private func validateURLString(_ value: String) throws {
        guard
            let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            scheme == "https"
        else {
            throw ScaffoldAdminTrustRootDescriptorValidationError.invalidURL(value)
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        if #available(macOS 10.13, iOS 11.0, *) {
            encoder.outputFormatting = [.sortedKeys]
        }
        return encoder
    }
}
