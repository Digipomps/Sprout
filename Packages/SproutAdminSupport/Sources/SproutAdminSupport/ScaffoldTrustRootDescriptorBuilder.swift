import Foundation
import SproutCrypto
import SproutResolverAdapter

public enum ScaffoldTrustRootDescriptorBuilder {
    /// Operator renewal policy, not a relaxation of runtime descriptor validation.
    public static let maximumRenewalValidity: TimeInterval = 30 * 86_400

    /// Reject fields this version cannot preserve instead of silently dropping them on decode.
    public static func decodeDescriptorForRenewal(from data: Data) throws -> ScaffoldAdminTrustRootDescriptor {
        let descriptor = try JSONDecoder().decode(ScaffoldAdminTrustRootDescriptor.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let supported: Set<String> = [
            "version", "descriptor_id", "scaffold_domain", "scaffold_admin_public_key",
            "resolver_public_keys", "bridge_owner_public_keys", "starter_bootstrap_url",
            "bridge_discovery_url", "resolver_base_url", "software_catalog_url",
            "issued_at", "expires_at", "signature"
        ]
        var unknown = Set(object.keys).subtracting(supported).sorted()
        if let signature = object["signature"] as? [String: Any] {
            unknown += Set(signature.keys).subtracting(["alg", "sig"]).sorted().map { "signature.\($0)" }
        }
        guard unknown.isEmpty else {
            throw ScaffoldTrustRootRenewalError.unsupportedFields(unknown)
        }
        return descriptor
    }

    /// Renew an authentic descriptor with its existing Scaffold signer. This does not authorize
    /// use of the expired input: historical validation is local to this administrative operation.
    public static func renewSignedDescriptor(
        descriptor: ScaffoldAdminTrustRootDescriptor,
        expectedDomain: String,
        adminIdentity: VaporVaultIdentityRecord,
        descriptorID: String,
        expiresAt: Date,
        now: Date = Date()
    ) throws -> ScaffoldAdminTrustRootDescriptor {
        guard descriptor.version == "1.0" else {
            throw ScaffoldTrustRootRenewalError.unsupportedVersion(descriptor.version)
        }
        guard adminIdentity.identityContext == "Scaffold" else {
            throw ScaffoldTrustRootRenewalError.wrongIdentityContext
        }
        guard descriptor.scaffold_admin_public_key == adminIdentity.publicKeyBase64URL,
              try Ed25519KeyPair(seed: adminIdentity.privateKey).publicKeyData == adminIdentity.publicKey else {
            throw ScaffoldTrustRootRenewalError.signerMismatch
        }

        let formatter = ISO8601DateFormatter()
        guard now.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > now,
              expiresAt.timeIntervalSince(now) <= maximumRenewalValidity,
              let previousIssuedAt = formatter.date(from: descriptor.issued_at),
              let previousExpiresAt = formatter.date(from: descriptor.expires_at),
              previousIssuedAt < previousExpiresAt,
              previousIssuedAt <= now else {
            throw ScaffoldTrustRootRenewalError.invalidValidity
        }
        // All the existing structural, domain and signature checks still run. The signed
        // issuance time is used only to check historical authenticity of an expired input.
        try ScaffoldAdminTrustRootDescriptorValidator().validate(
            descriptor: descriptor,
            context: .init(expectedDomain: expectedDomain, now: previousIssuedAt)
        )
        guard !descriptorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              descriptorID != descriptor.descriptor_id else {
            throw ScaffoldTrustRootRenewalError.invalidDescriptorID
        }

        // Check the seconds actually encoded on the wire, including subsecond boundary cases.
        let issuedString = formatter.string(from: now)
        let expiresString = formatter.string(from: expiresAt)
        guard let issued = formatter.date(from: issuedString),
              let expires = formatter.date(from: expiresString),
              expires > now,
              expires > previousExpiresAt,
              expires.timeIntervalSince(issued) <= maximumRenewalValidity else {
            throw ScaffoldTrustRootRenewalError.invalidValidity
        }

        var renewed = descriptor
        renewed.descriptor_id = descriptorID
        renewed.issued_at = issuedString
        renewed.expires_at = expiresString
        renewed.signature = ResolverSignatureEnvelope(
            alg: "Ed25519",
            sig: try Ed25519.signBase64URL(
                data: renewed.canonicalPayloadData(),
                seedBase64URL: Base64URL.encode(adminIdentity.privateKey)
            )
        )
        try ScaffoldAdminTrustRootDescriptorValidator().validate(
            descriptor: renewed,
            context: .init(expectedDomain: expectedDomain, now: now)
        )
        return renewed
    }

    public static func buildSignedDescriptor(
        scaffoldDomain: String,
        adminIdentity: VaporVaultIdentityRecord,
        descriptorID: String,
        issuedAt: Date,
        expiresAt: Date,
        resolverPublicKeys: [String],
        bridgeOwnerPublicKeys: [String],
        starterBootstrapURL: URL,
        bridgeDiscoveryURL: URL,
        resolverBaseURL: URL
    ) throws -> ScaffoldAdminTrustRootDescriptor {
        let formatter = ISO8601DateFormatter()
        var descriptor = ScaffoldAdminTrustRootDescriptor(
            version: "1.0",
            descriptor_id: descriptorID,
            scaffold_domain: scaffoldDomain,
            scaffold_admin_public_key: adminIdentity.publicKeyBase64URL,
            resolver_public_keys: resolverPublicKeys,
            bridge_owner_public_keys: bridgeOwnerPublicKeys,
            starter_bootstrap_url: starterBootstrapURL.absoluteString,
            bridge_discovery_url: bridgeDiscoveryURL.absoluteString,
            resolver_base_url: resolverBaseURL.absoluteString,
            issued_at: formatter.string(from: issuedAt),
            expires_at: formatter.string(from: expiresAt),
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )
        descriptor.signature = ResolverSignatureEnvelope(
            alg: "Ed25519",
            sig: try Ed25519.signBase64URL(
                data: try descriptor.canonicalPayloadData(),
                seedBase64URL: Base64URL.encode(adminIdentity.privateKey)
            )
        )
        return descriptor
    }
}

public enum ScaffoldTrustRootRenewalError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(String)
    case unsupportedFields([String])
    case wrongIdentityContext
    case signerMismatch
    case invalidValidity
    case invalidDescriptorID

    public var description: String {
        switch self {
        case .unsupportedVersion(let version):
            return "Cannot renew unsupported descriptor version: \(version)."
        case .unsupportedFields(let fields):
            return "Cannot preserve unsupported descriptor fields: \(fields.joined(separator: ", "))."
        case .wrongIdentityContext:
            return "Trust-root renewal requires the existing Scaffold vault identity context."
        case .signerMismatch:
            return "The vault signing key must match the existing descriptor's Scaffold admin key."
        case .invalidValidity:
            return "Renewal requires valid historical dates and an expiry after now and the previous expiry, within 30 days of issuance."
        case .invalidDescriptorID:
            return "Renewal requires a nonempty descriptor ID different from the previous ID."
        }
    }
}
