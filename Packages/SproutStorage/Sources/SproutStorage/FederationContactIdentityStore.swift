import Foundation
import SproutCrypto

public enum FederationContactIdentityStoreError: Error, Equatable {
    case invalidRemoteDomain(String)
    case invalidLocalDomain(String)
    case identityNotFound(String)
}

public struct FederationContactIdentityRecord: Codable, Equatable, Sendable {
    public var version: String
    public var remote_domain: String
    public var local_scaffold_domain: String?
    public var identity_context: String
    public var identity_public_key: String
    public var key_algorithm: String
    public var seed_key_name: String
    public var created_at: String
    public var note: String?

    public init(
        version: String = "1.0",
        remote_domain: String,
        local_scaffold_domain: String?,
        identity_context: String,
        identity_public_key: String,
        key_algorithm: String = "Ed25519",
        seed_key_name: String = "ed25519.seed",
        created_at: String,
        note: String?
    ) {
        self.version = version
        self.remote_domain = remote_domain
        self.local_scaffold_domain = local_scaffold_domain
        self.identity_context = identity_context
        self.identity_public_key = identity_public_key
        self.key_algorithm = key_algorithm
        self.seed_key_name = seed_key_name
        self.created_at = created_at
        self.note = note
    }
}

public actor FederationContactIdentityStore {
    public static let seedKeyName = "ed25519.seed"

    private let root: URL
    private let now: @Sendable () -> Date

    public init(root: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.root = root
        self.now = now
    }

    public func initialize(
        remoteDomain: String,
        localScaffoldDomain: String? = nil,
        note: String? = nil,
        overwrite: Bool = false
    ) async throws -> FederationContactIdentityRecord {
        let validatedRemoteDomain = try Self.validateDomain(remoteDomain, label: "remote")
        let validatedLocalDomain = try localScaffoldDomain.map { try Self.validateDomain($0, label: "local") }

        if !overwrite, let existing = try? load(remoteDomain: validatedRemoteDomain) {
            return existing
        }

        try ensureDirectory(root)
        let seed = Ed25519.generateSeed()
        let publicKey = try Ed25519.publicKeyBase64URL(fromSeed: seed)
        let record = FederationContactIdentityRecord(
            remote_domain: validatedRemoteDomain,
            local_scaffold_domain: validatedLocalDomain,
            identity_context: Self.identityContext(for: validatedRemoteDomain),
            identity_public_key: publicKey,
            created_at: Self.iso8601String(from: now()),
            note: note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )

        let domainRoot = self.domainRoot(for: validatedRemoteDomain)
        try ensureDirectory(domainRoot)
        let keyStore = LocalKeyStore(root: domainRoot.appendingPathComponent("keys", isDirectory: true))
        try await keyStore.writeKey(seed, named: Self.seedKeyName)
        try persist(record: record, remoteDomain: validatedRemoteDomain)
        return record
    }

    public func load(remoteDomain: String) throws -> FederationContactIdentityRecord {
        let validatedRemoteDomain = try Self.validateDomain(remoteDomain, label: "remote")
        let recordURL = domainRoot(for: validatedRemoteDomain).appendingPathComponent("contact.json")
        guard FileManager.default.fileExists(atPath: recordURL.path) else {
            throw FederationContactIdentityStoreError.identityNotFound(validatedRemoteDomain)
        }
        return try JSONDecoder().decode(FederationContactIdentityRecord.self, from: Data(contentsOf: recordURL))
    }

    public func list() throws -> [FederationContactIdentityRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }

        let directoryURLs = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return try directoryURLs
            .filter { $0.hasDirectoryPath }
            .compactMap { url in
                let recordURL = url.appendingPathComponent("contact.json")
                guard FileManager.default.fileExists(atPath: recordURL.path) else {
                    return nil
                }
                return try JSONDecoder().decode(FederationContactIdentityRecord.self, from: Data(contentsOf: recordURL))
            }
            .sorted { $0.remote_domain < $1.remote_domain }
    }

    public static func identityContext(for remoteDomain: String) -> String {
        "FederationContact/\(remoteDomain)"
    }

    private func persist(record: FederationContactIdentityRecord, remoteDomain: String) throws {
        let recordURL = domainRoot(for: remoteDomain).appendingPathComponent("contact.json")
        let data = try JSONEncoder.pretty.encode(record)
        try data.write(to: recordURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
    }

    private func domainRoot(for remoteDomain: String) -> URL {
        root.appendingPathComponent(remoteDomain, isDirectory: true)
    }

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static func validateDomain(_ value: String, label: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^[A-Za-z0-9.-]+$"
        guard !trimmed.isEmpty, trimmed.range(of: pattern, options: .regularExpression) != nil else {
            if label == "local" {
                throw FederationContactIdentityStoreError.invalidLocalDomain(value)
            }
            throw FederationContactIdentityStoreError.invalidRemoteDomain(value)
        }
        return trimmed
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
