import Foundation
import XCTest
import SproutStorage
import SproutCrypto

final class FederationContactIdentityStoreTests: XCTestCase {
    func testInitializeLoadAndListFederationContactIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FederationContactIdentityStore(
            root: root,
            now: { ISO8601DateFormatter().date(from: "2026-03-09T09:00:00Z") ?? Date(timeIntervalSince1970: 0) }
        )

        let created = try await store.initialize(
            remoteDomain: "staging.haven.digipomps.org",
            localScaffoldDomain: "local.haven.test",
            note: "staging helper contact"
        )

        XCTAssertEqual(created.remote_domain, "staging.haven.digipomps.org")
        XCTAssertEqual(created.local_scaffold_domain, "local.haven.test")
        XCTAssertEqual(created.identity_context, "FederationContact/staging.haven.digipomps.org")
        XCTAssertEqual(created.key_algorithm, "Ed25519")
        XCTAssertEqual(created.seed_key_name, "ed25519.seed")
        XCTAssertEqual(created.note, "staging helper contact")
        XCTAssertFalse(created.identity_public_key.isEmpty)

        let loaded = try await store.load(remoteDomain: "staging.haven.digipomps.org")
        XCTAssertEqual(loaded, created)

        let listed = try await store.list()
        XCTAssertEqual(listed, [created])

        let seedURL = root
            .appendingPathComponent("staging.haven.digipomps.org", isDirectory: true)
            .appendingPathComponent("keys", isDirectory: true)
            .appendingPathComponent("ed25519.seed")
        let seedData = try Data(contentsOf: seedURL)
        XCTAssertEqual(seedData.count, 32)
        XCTAssertEqual(try Ed25519.publicKeyBase64URL(fromSeed: seedData), created.identity_public_key)
    }

    func testInitializeReturnsExistingRecordWhenOverwriteIsFalse() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FederationContactIdentityStore(root: root)

        let created = try await store.initialize(remoteDomain: "dev.haven.digipomps.org")
        let loaded = try await store.initialize(remoteDomain: "dev.haven.digipomps.org")

        XCTAssertEqual(loaded, created)
    }

    func testInvalidRemoteDomainIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FederationContactIdentityStore(root: root)

        do {
            _ = try await store.initialize(remoteDomain: "../staging")
            XCTFail("Expected invalidRemoteDomain")
        } catch let error as FederationContactIdentityStoreError {
            XCTAssertEqual(error, .invalidRemoteDomain("../staging"))
        }
    }
}
