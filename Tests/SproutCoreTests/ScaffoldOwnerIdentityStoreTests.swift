import Foundation
import XCTest
import SproutStorage
import SproutCrypto

final class ScaffoldOwnerIdentityStoreTests: XCTestCase {
    func testInitializeLoadAndListScaffoldOwnerIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ScaffoldOwnerIdentityStore(
            root: root,
            now: { ISO8601DateFormatter().date(from: "2026-05-20T12:00:00Z") ?? Date(timeIntervalSince1970: 0) }
        )

        let created = try await store.initialize(
            scaffoldDomain: "local.haven.test",
            displayName: "Local owner",
            note: "first cloud scaffold owner"
        )

        XCTAssertEqual(created.scaffold_domain, "local.haven.test")
        XCTAssertEqual(created.identity_context, "Scaffold")
        XCTAssertEqual(created.key_algorithm, "Ed25519")
        XCTAssertEqual(created.seed_key_name, "ed25519.seed")
        XCTAssertEqual(created.display_name, "Local owner")
        XCTAssertEqual(created.note, "first cloud scaffold owner")
        XCTAssertFalse(created.identity_public_key.isEmpty)

        let loaded = try await store.load(scaffoldDomain: "local.haven.test")
        XCTAssertEqual(loaded, created)

        let listed = try await store.list()
        XCTAssertEqual(listed, [created])

        let seedURL = root
            .appendingPathComponent("local.haven.test", isDirectory: true)
            .appendingPathComponent("keys", isDirectory: true)
            .appendingPathComponent("ed25519.seed")
        let seedData = try Data(contentsOf: seedURL)
        XCTAssertEqual(seedData.count, 32)
        XCTAssertEqual(try Ed25519.publicKeyBase64URL(fromSeed: seedData), created.identity_public_key)
    }

    func testInitializeReturnsExistingRecordWhenOverwriteIsFalse() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ScaffoldOwnerIdentityStore(root: root)

        let created = try await store.initialize(scaffoldDomain: "owner.haven.test")
        let loaded = try await store.initialize(scaffoldDomain: "owner.haven.test")

        XCTAssertEqual(loaded, created)
    }

    func testInvalidScaffoldDomainIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ScaffoldOwnerIdentityStore(root: root)

        do {
            _ = try await store.initialize(scaffoldDomain: "../owner")
            XCTFail("Expected invalidScaffoldDomain")
        } catch let error as ScaffoldOwnerIdentityStoreError {
            XCTAssertEqual(error, .invalidScaffoldDomain("../owner"))
        }
    }
}
