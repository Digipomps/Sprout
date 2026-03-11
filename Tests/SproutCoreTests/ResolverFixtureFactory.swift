import Foundation
import SproutBridge
import SproutCrypto
import SproutResolverAdapter

enum ResolverFixtureFactory {
    static let resolverSeed = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    static let bridgeSeed = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"

    static func resolverPublicKey() throws -> String {
        try Ed25519.publicKeyBase64URL(fromSeedBase64URL: resolverSeed)
    }

    static func bridgeOwnerPublicKey() throws -> String {
        try Ed25519.publicKeyBase64URL(fromSeedBase64URL: bridgeSeed)
    }

    static func makeSignedBridgeDescriptor(
        descriptorID: String = "bd_anchor_0001",
        bridgeEndpoint: String = "wss://bridge.example.haven.local/cell",
        scaffoldDomain: String = "example.haven.local",
        capabilities: [String] = ["cap.join", "cap.discover"],
        purposes: [String] = ["bootstrap.join_scaffold"],
        expiresAt: String = "2026-02-26T09:00:00Z",
        ownerSeedBase64URL: String = resolverSeed
    ) throws -> BridgeDescriptor {
        var descriptor = BridgeDescriptor(
            descriptor_id: descriptorID,
            bridge_endpoint: bridgeEndpoint,
            scaffold_domain: scaffoldDomain,
            owner_pubkey: try Ed25519.publicKeyBase64URL(fromSeedBase64URL: ownerSeedBase64URL),
            capability_requirements: capabilities,
            purpose_constraints: purposes,
            expires_at: expiresAt,
            signature: SignatureEnvelope(alg: "Ed25519", sig: "")
        )
        descriptor.signature = SignatureEnvelope(
            alg: "Ed25519",
            sig: try Ed25519.signBase64URL(data: try descriptor.canonicalPayloadData(), seedBase64URL: ownerSeedBase64URL)
        )
        return descriptor
    }

    static func makeScaffoldTrustRootDescriptor(
        scaffoldDomain: String = "example.haven.local",
        bridgeOwnerPublicKeys: [String]? = nil,
        resolverPublicKeys: [String]? = nil,
        issuedAt: String = "2026-02-26T08:00:00Z",
        expiresAt: String = "2026-02-26T09:00:00Z"
    ) throws -> ScaffoldAdminTrustRootDescriptor {
        let resolvedResolverPublicKeys = try resolverPublicKeys ?? [resolverPublicKey()]
        let resolvedBridgeOwnerPublicKeys = try bridgeOwnerPublicKeys ?? [bridgeOwnerPublicKey()]
        var descriptor = ScaffoldAdminTrustRootDescriptor(
            version: "1.0",
            descriptor_id: "trd_0001",
            scaffold_domain: scaffoldDomain,
            scaffold_admin_public_key: try resolverPublicKey(),
            resolver_public_keys: resolvedResolverPublicKeys,
            bridge_owner_public_keys: resolvedBridgeOwnerPublicKeys,
            starter_bootstrap_url: "https://\(scaffoldDomain)/v1/resolver/starter-auth/intent",
            bridge_discovery_url: "https://\(scaffoldDomain)/v1/bridges/query",
            resolver_base_url: "https://\(scaffoldDomain)",
            issued_at: issuedAt,
            expires_at: expiresAt,
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )
        descriptor.signature = ResolverSignatureEnvelope(
            alg: "Ed25519",
            sig: try Ed25519.signBase64URL(data: try descriptor.canonicalPayloadData(), seedBase64URL: resolverSeed)
        )
        return descriptor
    }

    static func makeSignedEntityAnchorSnapshot(
        entityID: String = "entity_anchor_primary",
        identities: [EntityAnchorIdentityMember],
        acceptedContractIDs: [String] = [],
        issuedAt: String = "2026-02-26T08:00:00Z",
        expiresAt: String = "2026-02-26T09:00:00Z"
    ) throws -> EntityAnchorSnapshot {
        var snapshot = EntityAnchorSnapshot(
            snapshot_id: "anchor_0001",
            scaffold_domain: "example.haven.local",
            admin_public_key: try resolverPublicKey(),
            issued_at: issuedAt,
            expires_at: expiresAt,
            entities: [
                EntityAnchorEntityRecord(
                    entity_id: entityID,
                    identities: identities,
                    accepted_entity_link_contract_ids: acceptedContractIDs
                )
            ],
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )
        snapshot.signature = ResolverSignatureEnvelope(
            alg: "Ed25519",
            sig: try Ed25519.signBase64URL(data: try snapshot.canonicalPayloadData(), seedBase64URL: resolverSeed)
        )
        return snapshot
    }

    static func makePortholeAccessContract(
        clientKind: PortholeClientKind,
        protocolKind: PortholeProtocolKind,
        bridgeEndpoint: String = "wss://bridge.example.haven.local/cell",
        issuedAt: String = "2026-02-26T08:01:00Z",
        expiresAt: String = "2026-02-26T08:06:00Z"
    ) throws -> PortholeAccessContract {
        var contract = PortholeAccessContract(
            contract_id: "pac_fixture_0001",
            scaffold_domain: "example.haven.local",
            entity_id: "entity_example_primary",
            identity_public_key: "m2J3MyPvQaEYNIJBlOVRZNMl65zcwQ3dp9EK3k-9j20",
            scaffold_admin_public_key: try resolverPublicKey(),
            bridge_descriptor_id: "bd_anchor_0001",
            bridge_endpoint: bridgeEndpoint,
            client_kind: clientKind,
            porthole_protocol: protocolKind,
            capability_grants: ["cap.join", "cap.discover"],
            purpose: "bootstrap.join_scaffold",
            goal: "Join scaffold and register identity",
            interests: ["haven.core.bootstrap", "haven.core.bridge"],
            issued_at: issuedAt,
            expires_at: expiresAt,
            issued_by: try resolverPublicKey(),
            entity_evidence_contract_id: nil,
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )
        contract.signature = ResolverSignatureEnvelope(
            alg: "Ed25519",
            sig: try Ed25519.signBase64URL(data: try contract.canonicalPayloadData(), seedBase64URL: resolverSeed)
        )
        return contract
    }
}
