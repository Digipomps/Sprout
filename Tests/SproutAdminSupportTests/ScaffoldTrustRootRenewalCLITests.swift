import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
import SproutAdminSupport
import SproutCrypto
import SproutResolverAdapter

/// Run after `swift build --product sprout-admin`; fixtures contain only freshly generated keys.
final class ScaffoldTrustRootRenewalCLITests: XCTestCase {
    private var temporaryDirectory: URL!
    private var executable: URL!
    private var original: ScaffoldAdminTrustRootDescriptor!
    private let domain = "renewal.example.test"

    override func setUpWithError() throws {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        if let override = ProcessInfo.processInfo.environment["SPROUT_ADMIN_TEST_BINARY"] {
            executable = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw NSError(domain: "ScaffoldTrustRootRenewalCLITests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "SPROUT_ADMIN_TEST_BINARY must name an executable"])
            }
        } else {
            executable = packageRoot.appendingPathComponent(".build/debug/sprout-admin")
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Build the operator CLI first: swift build --product sprout-admin")
        }
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let seed = Ed25519.generateSeed()
        let admin = VaporVaultIdentityRecord(uuid: "synthetic-cli-admin", displayName: "Synthetic admin",
            identityContext: "Scaffold", publicKey: try Ed25519KeyPair(seed: seed).publicKeyData, privateKey: seed)
        let now = Date()
        original = try ScaffoldTrustRootDescriptorBuilder.buildSignedDescriptor(
            scaffoldDomain: domain, adminIdentity: admin, descriptorID: "expired-original",
            issuedAt: now.addingTimeInterval(-2 * 86_400), expiresAt: now.addingTimeInterval(-86_400),
            resolverPublicKeys: ["resolver-b", "resolver-a"], bridgeOwnerPublicKeys: ["bridge-b", "bridge-a"],
            starterBootstrapURL: URL(string: "https://auth.example.test/intent")!,
            bridgeDiscoveryURL: URL(string: "https://bridges.example.test/query")!,
            resolverBaseURL: URL(string: "https://resolver.example.test/custom")!
        )
        original.software_catalog_url = "https://catalog.example.test/releases?channel=stable"
        original.signature = .init(alg: "Ed25519", sig: try Ed25519.signBase64URL(
            data: original.canonicalPayloadData(), seedBase64URL: Base64URL.encode(seed)))
        try JSONEncoder().encode(original).write(to: file("original.json"))
        try writeSyntheticVault(admin: admin)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory { try FileManager.default.removeItem(at: temporaryDirectory) }
    }

    func testCommandRenewsExpiredDescriptorAndPreservesTrustParameters() throws {
        let result = try run(arguments())
        XCTAssertEqual(result.status, 0, result.output)
        let renewed = try JSONDecoder().decode(ScaffoldAdminTrustRootDescriptor.self, from: Data(contentsOf: file("renewed.json")))
        XCTAssertTrue(try renewed.verifySignature())
        XCTAssertFalse(renewed.isExpired())
        XCTAssertNotEqual(renewed.descriptor_id, original.descriptor_id)
        var restored = renewed
        restored.descriptor_id = original.descriptor_id
        restored.issued_at = original.issued_at
        restored.expires_at = original.expires_at
        restored.signature = original.signature
        XCTAssertEqual(restored, original)
        XCTAssertEqual(try JSONDecoder().decode(ScaffoldAdminTrustRootDescriptor.self,
            from: Data(contentsOf: file("original.json"))), original)
        let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        XCTAssertEqual(summary["previous_descriptor_id"] as? String, original.descriptor_id)
        XCTAssertNil(summary["privateKey"])
    }

    func testCommandRejectsMissingDuplicateAndUnsupportedFlags() throws {
        let base = arguments()
        let attempts = [
            removing("--out", from: base), removing("--expires-at", from: base),
            removing("--descriptor", from: base), removing("--scaffold-domain", from: base),
            base + ["--expires-at", date(Date().addingTimeInterval(2 * 86_400))],
            base + ["--now", "2000-01-01T00:00:00Z"],
            base + ["--resolver-public-keys", "replacement"], base + ["--descriptor-id"]
        ]
        for attempt in attempts {
            let result = try run(attempt)
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file("renewed.json").path))
        }
    }

    func testCommandRefusesExistingOutputIncludingInputAndVault() throws {
        for name in ["original.json", "OrganisationIdentities.crypt", "vault-master.key"] {
            let before = try Data(contentsOf: file(name))
            let result = try run(replacing("--out", with: file(name).path, in: arguments()))
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("refusing to overwrite"))
            XCTAssertEqual(try Data(contentsOf: file(name)), before)
        }
    }

    func testCommandRejectsWrongDomainContextAndForgedDescriptor() throws {
        for attempt in [
            replacing("--scaffold-domain", with: "other.example.test", in: arguments()),
            replacing("--identity-context", with: "Other", in: arguments())
        ] {
            XCTAssertNotEqual(try run(attempt).status, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file("renewed.json").path))
        }
        var forged = original!
        forged.bridge_owner_public_keys = ["forged"]
        try JSONEncoder().encode(forged).write(to: file("original.json"))
        let result = try run(arguments())
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("signatureInvalid"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("renewed.json").path))
    }

    func testCommandRejectsUnsafeValidityAndUnchangedID() throws {
        for expiry in ["invalid", date(Date().addingTimeInterval(-60)), date(Date().addingTimeInterval(31 * 86_400))] {
            XCTAssertNotEqual(try run(replacing("--expires-at", with: expiry, in: arguments())).status, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file("renewed.json").path))
        }
        XCTAssertNotEqual(try run(arguments() + ["--descriptor-id", original.descriptor_id]).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("renewed.json").path))
    }

    private func arguments() -> [String] {
        ["scaffold-trust-root", "renew-from-vapor-vault", "--descriptor", file("original.json").path,
         "--scaffold-domain", domain, "--identity-context", "Scaffold",
         "--expires-at", date(Date().addingTimeInterval(86_400)), "--out", file("renewed.json").path,
         "--vault-root", temporaryDirectory.path, "--master-key-file", file("vault-master.key").path]
    }

    private func file(_ name: String) -> URL { temporaryDirectory.appendingPathComponent(name) }
    private func date(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }

    private func replacing(_ flag: String, with value: String, in arguments: [String]) -> [String] {
        var result = arguments
        result[result.firstIndex(of: flag)! + 1] = value
        return result
    }

    private func removing(_ flag: String, from arguments: [String]) -> [String] {
        var result = arguments
        let index = result.firstIndex(of: flag)!
        result.removeSubrange(index...(index + 1))
        return result
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func writeSyntheticVault(admin: VaporVaultIdentityRecord) throws {
        let masterKey = SymmetricKey(size: .bits256)
        let masterKeyData = masterKey.withUnsafeBytes { Data($0) }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: masterKey,
            salt: Data("CellScaffoldVaultSalt.v1".utf8), info: Data("OrganisationIdentities.crypt".utf8), outputByteCount: 32)
        let sealed = try ChaChaPoly.seal(JSONEncoder().encode([admin]), using: key,
            authenticating: Data("cell-vault-v1:OrganisationIdentities.crypt".utf8))
        var encrypted = Data("CVLT1".utf8)
        encrypted.append(sealed.nonce.withUnsafeBytes { Data($0) })
        encrypted.append(sealed.ciphertext)
        encrypted.append(sealed.tag)
        try encrypted.write(to: file("OrganisationIdentities.crypt"))
        try masterKeyData.write(to: file("vault-master.key"))
    }
}
