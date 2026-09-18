import Foundation
import SproutCrypto

public enum StarterIdentityStoreError: Error, Equatable {
    case invalidScaffoldDomain(String)
    case identityNotFound(String)
    case recoveryRequired(String)
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
        let lock = try PrivateStateLock(directory: root)
        defer { withExtendedLifetime(lock) {} }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard !names.contains(where: { $0 != validatedDomain && $0.lowercased() == validatedDomain }) else {
            throw StarterIdentityStoreError.recoveryRequired(validatedDomain)
        }
        let domainRoot = self.domainRoot(for: validatedDomain)
        if PrivateStateFiles.exists(domainRoot) {
            // Missing or corrupt metadata is not permission to replace an existing key.
            return try load(scaffoldDomain: validatedDomain)
        }
        try PrivateStateFiles.ensureDirectory(domainRoot)
        let seed = Ed25519.generateSeed()
        let publicKey = try Ed25519.publicKeyBase64URL(fromSeed: seed)
        let record = StarterIdentityRecord(
            scaffold_domain: validatedDomain,
            identity_context: Self.identityContext(for: validatedDomain),
            identity_public_key: publicKey,
            created_at: Self.iso8601String(from: now())
        )

        let keys = domainRoot.appendingPathComponent("keys", isDirectory: true)
        try PrivateStateFiles.ensureDirectory(keys)
        try PrivateStateFiles.write(seed, to: keys.appendingPathComponent(Self.seedKeyName))
        try persist(record: record, scaffoldDomain: validatedDomain)
        return record
    }

    public func load(scaffoldDomain: String) throws -> StarterIdentityRecord {
        let validatedDomain = try Self.validateDomain(scaffoldDomain)
        guard PrivateStateFiles.exists(domainRoot(for: validatedDomain)) else {
            throw StarterIdentityStoreError.identityNotFound(validatedDomain)
        }
        try PrivateStateFiles.validateDirectory(root)
        try PrivateStateFiles.validateDirectory(domainRoot(for: validatedDomain))
        let recordURL = domainRoot(for: validatedDomain).appendingPathComponent("identity.json")
        do {
            let record = try JSONDecoder().decode(StarterIdentityRecord.self, from: PrivateStateFiles.read(recordURL))
            guard record.version == "1.0", record.scaffold_domain == validatedDomain,
                  record.identity_context == Self.identityContext(for: validatedDomain),
                  record.key_algorithm == "Ed25519", record.seed_key_name == Self.seedKeyName,
                  try Ed25519.publicKeyBase64URL(fromSeed: readSeed(domain: validatedDomain)) == record.identity_public_key else {
                throw StarterIdentityStoreError.recoveryRequired(validatedDomain)
            }
            return record
        } catch {
            throw StarterIdentityStoreError.recoveryRequired(validatedDomain)
        }
    }

    public func seedBase64URL(scaffoldDomain: String) async throws -> String {
        let validatedDomain = try Self.validateDomain(scaffoldDomain)
        _ = try load(scaffoldDomain: validatedDomain)
        return Base64URL.encode(try readSeed(domain: validatedDomain))
    }

    public static func identityContext(for scaffoldDomain: String) -> String {
        "Starter/\(scaffoldDomain)"
    }

    private func persist(record: StarterIdentityRecord, scaffoldDomain: String) throws {
        let recordURL = domainRoot(for: scaffoldDomain).appendingPathComponent("identity.json")
        let data = try JSONEncoder.pretty.encode(record)
        try PrivateStateFiles.write(data, to: recordURL)
    }

    private func domainRoot(for scaffoldDomain: String) -> URL {
        root.appendingPathComponent(scaffoldDomain, isDirectory: true)
    }

    private func readSeed(domain: String) throws -> Data {
        let keys = domainRoot(for: domain).appendingPathComponent("keys", isDirectory: true)
        try PrivateStateFiles.validateDirectory(keys)
        let seed = try PrivateStateFiles.read(keys.appendingPathComponent(Self.seedKeyName), maximumBytes: 32)
        guard seed.count == 32 else { throw StarterIdentityStoreError.recoveryRequired(domain) }
        return seed
    }

    public static func validateDomain(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let labels = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let pattern = "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
        guard !trimmed.isEmpty, trimmed.utf8.count <= 253,
              labels.allSatisfy({ String($0).range(of: pattern, options: .regularExpression) != nil }) else {
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
