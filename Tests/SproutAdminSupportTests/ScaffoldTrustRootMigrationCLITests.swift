import Foundation
import XCTest
import SproutAdminSupport
import SproutCrypto
import SproutResolverAdapter

final class ScaffoldTrustRootMigrationCLITests: XCTestCase {
    private var fixture: MigrationFixture!
    private var executable: URL!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let path = ProcessInfo.processInfo.environment["SPROUT_ADMIN_TEST_BINARY"] {
            executable = URL(fileURLWithPath: path)
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw NSError(domain: "ScaffoldTrustRootMigrationCLITests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "SPROUT_ADMIN_TEST_BINARY must name an executable"])
            }
        } else {
            executable = root.appendingPathComponent(".build/debug/sprout-admin")
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Build sprout-admin before running migration process tests")
        }
        fixture = try MigrationFixture(now: Date())
    }

    override func tearDownWithError() throws { fixture?.remove() }

    func testCommandMigratesWithAllPinsAndReportsExactOutputDigest() throws {
        let result = try run(arguments())
        XCTAssertEqual(result.status, 0, result.output)
        let bytes = try Data(contentsOf: fixture.file("migrated.json"))
        let descriptor = try JSONDecoder().decode(ScaffoldAdminTrustRootDescriptor.self, from: bytes)
        XCTAssertTrue(try descriptor.verifySignature())
        XCTAssertFalse(descriptor.isExpired())
        XCTAssertEqual(descriptor.scaffold_admin_public_key, Base64URL.encode(fixture.owner.publicKey))
        XCTAssertEqual(descriptor.software_catalog_url, fixture.previous.software_catalog_url)
        XCTAssertEqual(descriptor.resolver_public_keys, fixture.reviewedKeys)
        XCTAssertEqual(descriptor.bridge_owner_public_keys, fixture.reviewedKeys)
        let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        XCTAssertEqual(summary["migrated_descriptor_sha256"] as? String, MigrationFixture.sha256(bytes))
        XCTAssertEqual(summary["encrypted_vault_sha256"] as? String, fixture.vaultHash)
        XCTAssertFalse(result.output.contains(fixture.owner.privateKey.base64EncodedString()))
        XCTAssertFalse(result.output.contains(Base64URL.encode(fixture.owner.privateKey)))
        XCTAssertFalse(result.output.contains(fixture.masterKey.base64EncodedString()))
        let ordinary = try run(["vapor-vault", "list-identities", "--vault-file", fixture.vaultURL.path,
                                "--master-key-file", fixture.keyURL.path])
        XCTAssertNotEqual(ordinary.status, 0)
        XCTAssertTrue(ordinary.output.contains("verified active-owner binding"))
    }

    func testEveryAuthorityInputAndReviewedKeySetIsMandatory() throws {
        let original = arguments()
        for index in stride(from: 2, to: original.count, by: 2) {
            var missing = original
            missing.removeSubrange(index...(index + 1))
            let result = try run(missing)
            XCTAssertNotEqual(result.status, 0, "Accepted missing \(original[index]): \(result.output)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file("migrated.json").path))
        }
    }

    func testWrongPinsDomainAndForgedDescriptorProduceNoOutput() throws {
        for change in [
            ("--expected-owner-uuid", UUID().uuidString), ("--expected-owner-context", "Compatibility"),
            ("--expected-owner-fingerprint", Hashing.sha256Base64URL(fixture.owner.publicKey)),
            ("--expected-vault-sha256", String(repeating: "0", count: 64)),
            ("--expected-descriptor-sha256", String(repeating: "0", count: 64)),
            ("--scaffold-domain", "other.example.test")
        ] {
            let result = try run(replacing(change.0, with: change.1))
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file("migrated.json").path))
        }
        fixture.previous.bridge_discovery_url = "https://forged.example.test"
        try fixture.writeDescriptor()
        let result = try run(arguments())
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("signatureInvalid"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file("migrated.json").path))
    }

    func testUnknownDuplicateEmptyAndUnsafeFlagsFailClosed() throws {
        let valid = arguments()
        for attempt in [
            valid + ["--now", "2000-01-01T00:00:00Z"], valid + ["--vault-root", fixture.directory.path],
            valid + ["--expected-owner-uuid", fixture.owner.uuid], valid + ["--unused"],
            replacing("--resolver-public-keys", with: fixture.reviewedKeys[0] + ","),
            replacing("--bridge-owner-public-keys", with: [fixture.reviewedKeys[0], fixture.reviewedKeys[0]].joined(separator: ",")),
            replacing("--expires-at", with: ISO8601DateFormatter().string(from: Date().addingTimeInterval(31 * 86_400))),
            replacing("--descriptor-id", with: fixture.previous.descriptor_id)
        ] {
            let result = try run(attempt)
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file("migrated.json").path))
        }
    }

    func testOutputCannotReplaceInputKeyVaultOrSymlink() throws {
        for url in [fixture.file("previous.json"), fixture.vaultURL, fixture.keyURL] {
            let before = try Data(contentsOf: url)
            let result = try run(replacing("--out", with: url.path))
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.output.contains("refusing to overwrite"))
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
        let link = fixture.file("dangling-output.json")
        let target = fixture.file("must-not-create.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let result = try run(replacing("--out", with: link.path))
        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    private func arguments() -> [String] {
        let pins = fixture.pins()
        return ["scaffold-trust-root", "migrate-from-pinned-v2-vault",
            "--descriptor", fixture.file("previous.json").path, "--expected-descriptor-sha256", fixture.descriptorHash,
            "--scaffold-domain", fixture.domain, "--expected-owner-uuid", pins.uuid,
            "--expected-owner-context", pins.context, "--expected-owner-fingerprint", pins.signingKeyFingerprintDigest,
            "--expected-vault-sha256", pins.encryptedVaultSHA256, "--vault-file", fixture.vaultURL.path,
            "--master-key-file", fixture.keyURL.path, "--resolver-public-keys", fixture.reviewedKeys.joined(separator: ","),
            "--bridge-owner-public-keys", fixture.reviewedKeys.joined(separator: ","), "--descriptor-id", "migration-reviewed",
            "--expires-at", ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400)),
            "--out", fixture.file("migrated.json").path]
    }

    private func replacing(_ flag: String, with value: String) -> [String] {
        var args = arguments()
        args[args.firstIndex(of: flag)! + 1] = value
        return args
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
