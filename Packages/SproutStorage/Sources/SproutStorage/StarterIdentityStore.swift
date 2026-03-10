import Foundation
import SproutCrypto

public enum StarterIdentityStoreError: Error, Equatable {
    case invalidScaffoldDomain(String)
    case identityNotFound(String)
}

public struct StarterIdentityRecord: Codable, Equatable, Sendable {
    public var version: String
    public var scaffold_domain: String
    public var identity_context: String
    public var identity_public_key: String
    public var key_algorithm: String
    public var seed_key_name: String
    public var created_at: String

    public init(
        version: String = "1.0",
        scaffold_domain: String,
        identity_context: String,
        identity_public_key: String,
        key_algorithm: String = "Ed25519",
        seed_key_name: String = "ed25519.seed",
        created_at: String
    ) {
        self.version = version
        self.scaffold_domain = scaffold_domain
        self.identity_context = identity_context
        self.identity_public_key = identity_public_key
        self.key_algorithm = key_algorithm
        self.seed_key_name = seed_key_name
        self.created_at = created_at
    }
}

public actor StarterIdentityStore {
    public static let seedKeyName = "ed25519.seed"

    private let root: URL
    private let now: @Sendable () -> Date

    public init(root: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.root = root
        self.now = now
    }

    public func loadOrCreate(scaffoldDomain: String) async throws -> StarterIdentityRecord {
        let validatedDomain = try Self.validateDomain(scaffoldDomain)
        if let existing = try? load(scaffoldDomain: validatedDomain) {
            return existing
        }

        try ensureDirectory(root)
        let seed = Ed25519.generateSeed()
        let publicKey = try Ed25519.publicKeyBase64URL(fromSeed: seed)
        let record = StarterIdentityRecord(
            scaffold_domain: validatedDomain,
            identity_context: Self.identityContext(for: validatedDomain),
            identity_public_key: publicKey,
            created_at: Self.iso8601String(from: now())
        )

        let domainRoot = self.domainRoot(for: validatedDomain)
        try ensureDirectory(domainRoot)
        let keyStore = LocalKeyStore(root: domainRoot.appendingPathComponent("keys", isDirectory: true))
        try await keyStore.writeKey(seed, named: Self.seedKeyName)
        try persist(record: record, scaffoldDomain: validatedDomain)
        return record
    }

    public func load(scaffoldDomain: String) throws -> StarterIdentityRecord {
        let validatedDomain = try Self.validateDomain(scaffoldDomain)
        let recordURL = domainRoot(for: validatedDomain).appendingPathComponent("identity.json")
        guard FileManager.default.fileExists(atPath: recordURL.path) else {
            throw StarterIdentityStoreError.identityNotFound(validatedDomain)
        }
        return try JSONDecoder().decode(StarterIdentityRecord.self, from: Data(contentsOf: recordURL))
    }

    public func seedBase64URL(scaffoldDomain: String) async throws -> String {
        let validatedDomain = try Self.validateDomain(scaffoldDomain)
        let keyStore = LocalKeyStore(root: domainRoot(for: validatedDomain).appendingPathComponent("keys", isDirectory: true))
        let seed = try await keyStore.readKey(named: Self.seedKeyName)
        return Base64URL.encode(seed)
    }

    public static func identityContext(for scaffoldDomain: String) -> String {
        "Starter/\(scaffoldDomain)"
    }

    private func persist(record: StarterIdentityRecord, scaffoldDomain: String) throws {
        let recordURL = domainRoot(for: scaffoldDomain).appendingPathComponent("identity.json")
        let data = try JSONEncoder.pretty.encode(record)
        try data.write(to: recordURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
    }

    private func domainRoot(for scaffoldDomain: String) -> URL {
        root.appendingPathComponent(scaffoldDomain, isDirectory: true)
    }

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static func validateDomain(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^[A-Za-z0-9.-]+$"
        guard !trimmed.isEmpty, trimmed.range(of: pattern, options: .regularExpression) != nil else {
            throw StarterIdentityStoreError.invalidScaffoldDomain(value)
        }
        return trimmed
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
