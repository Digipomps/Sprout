import Foundation
import SproutCrypto
import SproutResolverAdapter

public enum ScaffoldTrustRootDescriptorBuilder {
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
