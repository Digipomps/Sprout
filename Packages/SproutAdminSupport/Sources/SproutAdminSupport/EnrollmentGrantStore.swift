import Foundation

/// Persistence seam for issued enrollment grants. The CLI uses a JSON file
/// store; the HTTP enrollment endpoint can later supply a DB-backed store.
/// Neither `mintProvisioningPack()` nor redemption validation cares which.
public protocol EnrollmentGrantStore: Sendable {
    func all() throws -> [EnrollmentGrant]
    func find(byCodeHash codeHash: String) throws -> EnrollmentGrant?
    func upsert(_ grant: EnrollmentGrant) throws
    /// Atomically bump `uses` for the matching grant. Single-use is only real
    /// if this is called (and succeeds) before minting.
    func consume(grantId: String) throws
    /// Operator kill switch.
    func revoke(grantId: String) throws
}

public enum EnrollmentGrantStoreError: Error, Equatable, Sendable {
    case grantNotFound(String)
}

/// JSON-file backed store: one file holding an array of grants.
///
/// Adequate for a single operator machine driving the CLI. It is not safe
/// against concurrent writers across processes — the HTTP layer should use a
/// transactional store instead.
public struct FileEnrollmentGrantStore: EnrollmentGrantStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func all() throws -> [EnrollmentGrant] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        return try JSONDecoder().decode([EnrollmentGrant].self, from: data)
    }

    public func find(byCodeHash codeHash: String) throws -> EnrollmentGrant? {
        try all().first { $0.codeHash == codeHash }
    }

    public func upsert(_ grant: EnrollmentGrant) throws {
        var grants = try all()
        if let index = grants.firstIndex(where: { $0.grantId == grant.grantId }) {
            grants[index] = grant
        } else {
            grants.append(grant)
        }
        try write(grants)
    }

    public func consume(grantId: String) throws {
        try mutate(grantId: grantId) { $0.uses += 1 }
    }

    public func revoke(grantId: String) throws {
        try mutate(grantId: grantId) { $0.revoked = true }
    }

    // MARK: - Internals

    private func mutate(grantId: String, _ change: (inout EnrollmentGrant) -> Void) throws {
        var grants = try all()
        guard let index = grants.firstIndex(where: { $0.grantId == grantId }) else {
            throw EnrollmentGrantStoreError.grantNotFound(grantId)
        }
        change(&grants[index])
        try write(grants)
    }

    private func write(_ grants: [EnrollmentGrant]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(grants).write(to: fileURL, options: [.atomic])
    }
}
