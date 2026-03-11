import Foundation
import SproutAdminSupport
import SproutResolverAdapter

enum AdminCLIError: Error, CustomStringConvertible {
    case invalidArguments(String)

    var description: String {
        switch self {
        case let .invalidArguments(message):
            return message
        }
    }
}

@main
struct SproutAdminCLI {
    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            throw AdminCLIError.invalidArguments(usage)
        }

        switch command {
        case "vapor-vault":
            try runVaporVault(arguments: Array(arguments.dropFirst()))
        case "entity-anchor":
            try runEntityAnchor(arguments: Array(arguments.dropFirst()))
        default:
            throw AdminCLIError.invalidArguments(usage)
        }
    }

    private static func runVaporVault(arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw AdminCLIError.invalidArguments(usage)
        }
        let flags = try parseFlags(Array(arguments.dropFirst()))
        let paths = resolveVaultPaths(flags: flags)

        switch subcommand {
        case "list-identities":
            let identities = try VaporVaultDecoder.loadIdentities(paths: paths).sorted {
                ($0.identityContext ?? $0.uuid) < ($1.identityContext ?? $1.uuid)
            }
            let rows = identities.map { identity in
                [
                    "identity_context": identity.identityContext ?? "",
                    "uuid": identity.uuid,
                    "display_name": identity.displayName,
                    "public_key_b64url": identity.publicKeyBase64URL
                ]
            }
            try emitJSON(rows, outPath: flags["out"])
        default:
            throw AdminCLIError.invalidArguments(usage)
        }
    }

    private static func runEntityAnchor(arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw AdminCLIError.invalidArguments(usage)
        }
        let flags = try parseFlags(Array(arguments.dropFirst()))
        switch subcommand {
        case "create-from-vapor-vault":
            try createEntityAnchorSnapshot(flags: flags)
        default:
            throw AdminCLIError.invalidArguments(usage)
        }
    }

    private static func createEntityAnchorSnapshot(flags: [String: String]) throws {
        let scaffoldDomain = try requiredFlag("scaffold-domain", flags)
        let identityContext = try requiredFlag("identity-context", flags)
        let entityID = try requiredFlag("entity-id", flags)
        let subjectPublicKey = try requiredFlag("subject-public-key", flags)
        let subjectDomain = try requiredFlag("subject-domain", flags)

        let now = try parseDate(flags["now"]) ?? Date()
        let issuedAt = try parseDate(flags["issued-at"]) ?? now
        let expiresAt = try parseDate(flags["expires-at"]) ?? issuedAt.addingTimeInterval(86_400 * 30)
        guard expiresAt > issuedAt else {
            throw AdminCLIError.invalidArguments("--expires-at must be later than --issued-at.")
        }

        let addedAt = try parseDate(flags["added-at"]) ?? issuedAt
        let snapshotID = flags["snapshot-id"] ?? "snapshot_\(scaffoldDomain.replacingOccurrences(of: ".", with: "_"))_\(Int(issuedAt.timeIntervalSince1970))"
        let acceptedContractIDs = parseCSV(flags["accepted-contract-ids"])
        let paths = resolveVaultPaths(flags: flags)
        let adminIdentity = try VaporVaultDecoder.identity(forContext: identityContext, paths: paths)

        let member = EntityAnchorIdentityMember(
            identity_public_key: subjectPublicKey,
            domain: subjectDomain,
            added_at: iso8601(addedAt),
            source_contract_id: acceptedContractIDs.first
        )
        let entityRecord = EntityAnchorEntityRecord(
            entity_id: entityID,
            identities: [member],
            accepted_entity_link_contract_ids: acceptedContractIDs
        )
        let snapshot = try EntityAnchorSnapshotBuilder.buildSignedSnapshot(
            scaffoldDomain: scaffoldDomain,
            adminIdentity: adminIdentity,
            snapshotID: snapshotID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            entities: [entityRecord]
        )
        let outputPath = flags["out"] ?? "./entity-anchor-snapshot.json"
        try emitJSON(snapshot, outPath: outputPath)
        let summary: [String: String] = [
            "snapshot_path": outputPath,
            "snapshot_id": snapshot.snapshot_id,
            "scaffold_domain": snapshot.scaffold_domain,
            "admin_public_key": snapshot.admin_public_key,
            "entity_id": entityID,
            "subject_public_key": subjectPublicKey
        ]
        try emitJSON(summary, outPath: flags["summary-out"])
    }

    private static func resolveVaultPaths(flags: [String: String]) -> VaporVaultPaths {
        let vaultRoot = URL(fileURLWithPath: flags["vault-root"] ?? "/app/CellsContainer", isDirectory: true)
        let vaultFileURL = flags["vault-file"].map { URL(fileURLWithPath: $0) }
        let masterKeyFileURL = flags["master-key-file"].map { URL(fileURLWithPath: $0) }
        return VaporVaultDecoder.resolvePaths(
            vaultRoot: vaultRoot,
            vaultFileURL: vaultFileURL,
            masterKeyFileURL: masterKeyFileURL
        )
    }

    private static func parseFlags(_ arguments: [String]) throws -> [String: String] {
        var flags = [String: String]()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                throw AdminCLIError.invalidArguments("Unexpected positional argument: \(argument)")
            }
            let key = String(argument.dropFirst(2))
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                flags[key] = arguments[index + 1]
                index += 2
            } else {
                flags[key] = "true"
                index += 1
            }
        }
        return flags
    }

    private static func parseCSV(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func requiredFlag(_ name: String, _ flags: [String: String]) throws -> String {
        guard let value = flags[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw AdminCLIError.invalidArguments("Missing required --\(name)")
        }
        return value
    }

    private static func parseDate(_ raw: String?) throws -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: raw) else {
            throw AdminCLIError.invalidArguments("Invalid ISO8601 timestamp: \(raw)")
        }
        return date
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func emitJSON<T: Encodable>(_ value: T, outPath: String?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)

        if let outPath, !outPath.isEmpty {
            let url = URL(fileURLWithPath: outPath)
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private static let usage = """
    Usage:
      sprout-admin vapor-vault list-identities [--vault-root <dir>] [--vault-file <path>] [--master-key-file <path>] [--out <file>]
      sprout-admin entity-anchor create-from-vapor-vault --scaffold-domain <domain> --identity-context <ctx> --entity-id <id> --subject-public-key <b64url> --subject-domain <domain> [--accepted-contract-ids <id1,id2>] [--vault-root <dir>] [--vault-file <path>] [--master-key-file <path>] [--snapshot-id <id>] [--issued-at <ISO8601>] [--expires-at <ISO8601>] [--added-at <ISO8601>] [--now <ISO8601>] [--out <file>] [--summary-out <file>]
    """
}
