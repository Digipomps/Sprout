import Foundation
import SproutStorage
@testable import SproutCrypto
import XCTest

final class StarterIdentityStoreTests: XCTestCase {
    func testLoadOrCreatePersistsSeedAndRecord() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = StarterIdentityStore(
            root: root,
            now: { ISO8601DateFormatter().date(from: "2026-03-10T21:00:00Z")! }
        )

        let first = try await store.loadOrCreate(scaffoldDomain: "staging.haven.digipomps.org")
        let second = try await store.loadOrCreate(scaffoldDomain: "staging.haven.digipomps.org")
        let seedBase64URL = try await store.seedBase64URL(scaffoldDomain: "staging.haven.digipomps.org")

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.identity_context, "Starter/staging.haven.digipomps.org")
        XCTAssertEqual(
            try Ed25519.publicKeyBase64URL(fromSeedBase64URL: seedBase64URL),
            first.identity_public_key
        )
    }
}
