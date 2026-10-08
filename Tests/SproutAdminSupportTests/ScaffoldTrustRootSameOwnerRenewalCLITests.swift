import Foundation
import XCTest
import SproutAdminSupport
import SproutCrypto
import SproutResolverAdapter

final class ScaffoldTrustRootSameOwnerRenewalCLITests: XCTestCase {
    func testCLIRequiresPinsAndFailsWithoutWritingOnBadInput() throws {
        let f = try SameOwnerFixture(now: Date()); defer { f.remove() }
        f.previous.scaffold_admin_public_key = Base64URL.encode(f.owner.publicKey)
        try f.resignPrevious(seed: f.owner.privateKey)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = ProcessInfo.processInfo.environment["SPROUT_ADMIN_TEST_BINARY"] ?? root.appendingPathComponent(".build/debug/sprout-admin").path
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            XCTFail("Build the new sprout-admin before process tests; no skipped acceptance.")
            return
        }
        let output = f.file("renewed.json")
        let args = ["scaffold-trust-root", "renew-from-pinned-v2-vault", "--descriptor", f.file("previous.json").path,
                    "--expected-descriptor-sha256", f.descriptorHash, "--scaffold-domain", f.domain,
                    "--expected-owner-uuid", f.owner.uuid, "--expected-owner-context", "Scaffold",
                    "--expected-owner-fingerprint", f.pins().signingKeyFingerprintDigest,
                    "--expected-vault-sha256", f.vaultHash, "--vault-file", f.vaultURL.path,
                    "--master-key-file", f.keyURL.path, "--descriptor-id", "new-id",
                    "--expires-at", ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400)),
                    "--out", output.path]
        func run(_ args: [String]) throws -> Int32 {
            let proc = Process(); proc.executableURL = URL(fileURLWithPath: binary); proc.arguments = args
            proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
            try proc.run(); proc.waitUntilExit(); return proc.terminationStatus
        }
        for index in stride(from: 2, to: args.count, by: 2) {
            var missing = args; missing.removeSubrange(index...(index + 1))
            XCTAssertNotEqual(try run(missing), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        for extra in [["--now", "2000-01-01T00:00:00Z"], ["--expected-owner-uuid", f.owner.uuid],
                      ["--resolver-public-keys", f.reviewedKeys[0]], ["--migrate", "true"]] {
            XCTAssertNotEqual(try run(args + extra), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        let before = try Data(contentsOf: f.vaultURL)
        XCTAssertEqual(try run(args), 0)
        let result = try JSONDecoder().decode(ScaffoldAdminTrustRootDescriptor.self, from: Data(contentsOf: output))
        XCTAssertTrue(try result.verifySignature())
        XCTAssertEqual(result.resolver_public_keys, f.previous.resolver_public_keys)
        XCTAssertEqual(try Data(contentsOf: f.vaultURL), before)
        XCTAssertNotEqual(try run(args), 0, "must never overwrite existing output")
    }
}
