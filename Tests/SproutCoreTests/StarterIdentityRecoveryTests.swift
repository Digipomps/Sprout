import Foundation
import SproutStorage
import SproutCrypto
import XCTest

final class StarterIdentityRecoveryTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-recovery-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCorruptMetadataDoesNotReplaceKey() async throws {
        let root = root()
        let store = StarterIdentityStore(root: root)
        _ = try await store.loadOrCreate(scaffoldDomain: "example.test")
        let seedURL = root.appendingPathComponent("example.test/keys/ed25519.seed")
        let before = try Data(contentsOf: seedURL)
        try PrivateStateFiles.write(Data("broken".utf8), to: root.appendingPathComponent("example.test/identity.json"))
        do {
            _ = try await store.loadOrCreate(scaffoldDomain: "example.test")
            XCTFail("Corrupt metadata must not create another identity")
        } catch { XCTAssertEqual(error as? StarterIdentityStoreError, .recoveryRequired("example.test")) }
        XCTAssertEqual(before, try Data(contentsOf: seedURL))
    }

    func testMissingMetadataWithSeedFailsClosed() async throws {
        let root = root()
        let store = StarterIdentityStore(root: root)
        _ = try await store.loadOrCreate(scaffoldDomain: "example.test")
        let seed = try await store.seedBase64URL(scaffoldDomain: "example.test")
        try FileManager.default.removeItem(at: root.appendingPathComponent("example.test/identity.json"))
        do {
            _ = try await store.loadOrCreate(scaffoldDomain: "example.test")
            XCTFail("Orphaned keys require recovery")
        } catch { XCTAssertEqual(error as? StarterIdentityStoreError, .recoveryRequired("example.test")) }
        XCTAssertEqual(seed, Base64URL.encode(try Data(contentsOf: root.appendingPathComponent("example.test/keys/ed25519.seed"))))
    }

    func testPublicKeyAndSeedMustMatch() async throws {
        let root = root()
        let store = StarterIdentityStore(root: root)
        var record = try await store.loadOrCreate(scaffoldDomain: "example.test")
        record.identity_public_key = try Ed25519.publicKeyBase64URL(fromSeed: Ed25519.generateSeed())
        try PrivateStateFiles.write(JSONEncoder().encode(record), to: root.appendingPathComponent("example.test/identity.json"))
        do {
            _ = try await store.loadOrCreate(scaffoldDomain: "example.test")
            XCTFail("A record cannot relabel a private key")
        } catch { XCTAssertEqual(error as? StarterIdentityStoreError, .recoveryRequired("example.test")) }
    }

    func testSymlinkedSeedRejected() async throws {
        let root = root()
        let store = StarterIdentityStore(root: root)
        _ = try await store.loadOrCreate(scaffoldDomain: "example.test")
        let seedURL = root.appendingPathComponent("example.test/keys/ed25519.seed")
        let other = root.appendingPathComponent("other.seed")
        try FileManager.default.moveItem(at: seedURL, to: other)
        try FileManager.default.createSymbolicLink(at: seedURL, withDestinationURL: other)
        do {
            _ = try await store.loadOrCreate(scaffoldDomain: "example.test")
            XCTFail("Symlinked keys are unsafe")
        } catch { XCTAssertEqual(error as? StarterIdentityStoreError, .recoveryRequired("example.test")) }
    }

    func testBroadSeedPermissionsRejected() async throws {
        let root = root()
        let store = StarterIdentityStore(root: root)
        _ = try await store.loadOrCreate(scaffoldDomain: "example.test")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("example.test/keys/ed25519.seed").path)
        do {
            _ = try await store.loadOrCreate(scaffoldDomain: "example.test")
            XCTFail("Readable-by-others seed must not be used")
        } catch { XCTAssertEqual(error as? StarterIdentityStoreError, .recoveryRequired("example.test")) }
    }

    func testDomainRejectsTraversalAndCanonicalizesCase() async throws {
        for value in [".", "..", "../foo", "foo/../bar", "foo..bar", "-foo.test", "foo-.test", "https://foo.test", "foo.test:443"] {
            XCTAssertThrowsError(try StarterIdentityStore.validateDomain(value))
        }
        let store = StarterIdentityStore(root: root())
        let first = try await store.loadOrCreate(scaffoldDomain: "EXAMPLE.test")
        let second = try await store.loadOrCreate(scaffoldDomain: "example.test")
        XCTAssertEqual(first, second)
    }

    func testInterruptedCreationAndLegacyCaseRequireRecovery() async throws {
        let root = root()
        try PrivateStateFiles.ensureDirectory(root.appendingPathComponent("example.test"))
        let store = StarterIdentityStore(root: root)
        do {
            _ = try await store.loadOrCreate(scaffoldDomain: "example.test")
            XCTFail("An existing empty identity directory is an interrupted creation")
        } catch { XCTAssertEqual(error as? StarterIdentityStoreError, .recoveryRequired("example.test")) }
        try PrivateStateFiles.ensureDirectory(root.appendingPathComponent("OTHER.test"))
        do {
            _ = try await store.loadOrCreate(scaffoldDomain: "other.test")
            XCTFail("Legacy case must not result in a new identity on Linux")
        } catch { XCTAssertEqual(error as? StarterIdentityStoreError, .recoveryRequired("other.test")) }
    }

    func testSecondProcessLockIsRejected() throws {
        let root = root()
        let first = try PrivateStateLock(directory: root)
        XCTAssertThrowsError(try PrivateStateLock(directory: root)) { error in
            XCTAssertEqual(error as? PrivateStateError, .busy)
        }
        withExtendedLifetime(first) {}
    }
}
