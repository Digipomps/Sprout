import Foundation
import XCTest
@testable import SproutAdminSupport
import SproutCore
import SproutCrypto
import SproutResolverAdapter

final class EntityAnchorSnapshotUpdaterTests: XCTestCase {
    func testAcceptingEntityLinkAddsContractIDToMatchingEntityAndResignsSnapshot() throws {
        let adminSeed = Ed25519.generateSeed()
        let adminKeyPair = try Ed25519KeyPair(seed: adminSeed)
        let adminIdentity = VaporVaultIdentityRecord(
            uuid: "admin-uuid",
            displayName: "Admin",
            identityContext: "Scaffold",
            publicKey: adminKeyPair.publicKeyData,
            privateKey: adminSeed
        )

        let operatorSeed = Ed25519.generateSeed()
        let operatorKeyPair = try Ed25519KeyPair(seed: operatorSeed)
        let agentSeed = Ed25519.generateSeed()
        let agentKeyPair = try Ed25519KeyPair(seed: agentSeed)
        let operatorPublicKey = Base64URL.encode(operatorKeyPair.publicKeyData)
        let agentPublicKey = Base64URL.encode(agentKeyPair.publicKeyData)

        let snapshot = try EntityAnchorSnapshotBuilder.buildSignedSnapshot(
            scaffoldDomain: "staging.haven.digipomps.org",
            adminIdentity: adminIdentity,
            snapshotID: "snapshot_0001",
            issuedAt: Date(timeIntervalSince1970: 1_762_700_000),
            expiresAt: Date(timeIntervalSince1970: 1_765_292_000),
            entities: [
                EntityAnchorEntityRecord(
                    entity_id: "entity_0001",
                    identities: [
                        EntityAnchorIdentityMember(
                            identity_public_key: operatorPublicKey,
                            domain: "staging.haven.digipomps.org",
                            added_at: "2026-03-11T00:00:00Z"
                        )
                    ]
                )
            ]
        )

        var entityLink = EntityLinkContract(
            contract_id: "elc_fixture_0001",
            domain_a: "staging.haven.digipomps.org",
            pubkey_a: operatorPublicKey,
            domain_b: "staging.haven.digipomps.org",
            pubkey_b: agentPublicKey,
            scope: "purpose-bound:bootstrap.join_scaffold",
            created_at: "2026-03-15T12:00:00Z",
            revocation: EntityLinkRevocation(mode: "mutual"),
            signatures: []
        )
        let canonical = try entityLink.canonicalPayloadData()
        entityLink.signatures = [
            EntityLinkSignature(
                by_pubkey: operatorPublicKey,
                alg: "Ed25519",
                sig: Base64URL.encode(try operatorKeyPair.sign(canonical))
            ),
            EntityLinkSignature(
                by_pubkey: agentPublicKey,
                alg: "Ed25519",
                sig: Base64URL.encode(try agentKeyPair.sign(canonical))
            )
        ]

        let updated = try EntityAnchorSnapshotUpdater.acceptingEntityLink(
            snapshot: snapshot,
            entityLink: entityLink,
            adminIdentity: adminIdentity,
            issuedAt: Date(timeIntervalSince1970: 1_762_800_000),
            expiresAt: Date(timeIntervalSince1970: 1_765_292_000)
        )

        XCTAssertTrue(try updated.verifySignature())
        XCTAssertEqual(updated.entities.count, 1)
        XCTAssertEqual(updated.entities[0].entity_id, "entity_0001")
        XCTAssertEqual(updated.entities[0].accepted_entity_link_contract_ids, ["elc_fixture_0001"])
    }
}
