import Foundation
import SproutAdminSupport
import SproutCore
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
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
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
        case "scaffold-trust-root":
            try runScaffoldTrustRoot(arguments: Array(arguments.dropFirst()))
        case "continuity-proof":
            try runContinuityProof(arguments: Array(arguments.dropFirst()))
        case "admission-contract":
            try runAdmissionContract(arguments: Array(arguments.dropFirst()))
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
        case "accept-entity-link":
            try acceptEntityLinkIntoAnchorSnapshot(flags: flags)
        default:
            throw AdminCLIError.invalidArguments(usage)
        }
    }

    private static func runScaffoldTrustRoot(arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw AdminCLIError.invalidArguments(usage)
        }
        let flags = try parseFlags(Array(arguments.dropFirst()))
        switch subcommand {
        case "create-from-vapor-vault":
            try createScaffoldTrustRootDescriptor(flags: flags)
        default:
            throw AdminCLIError.invalidArguments(usage)
        }
    }

    private static func runContinuityProof(arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw AdminCLIError.invalidArguments(usage)
        }
        let flags = try parseFlags(Array(arguments.dropFirst()))
        switch subcommand {
        case "create-from-vapor-vault":
            try createContinuityProof(flags: flags)
        default:
            throw AdminCLIError.invalidArguments(usage)
        }
    }

    private static func runAdmissionContract(arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw AdminCLIError.invalidArguments(usage)
        }
        let flags = try parseFlags(Array(arguments.dropFirst()))
        switch subcommand {
        case "create-from-vapor-vault":
            try createAdmissionContract(flags: flags)
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

    private static func acceptEntityLinkIntoAnchorSnapshot(flags: [String: String]) throws {
        let snapshotPath = try requiredFlag("snapshot", flags)
        let entityLinkPath = try requiredFlag("entity-link", flags)
        let identityContext = try requiredFlag("identity-context", flags)
        let paths = resolveVaultPaths(flags: flags)
        let adminIdentity = try VaporVaultDecoder.identity(forContext: identityContext, paths: paths)

        let snapshotURL = URL(fileURLWithPath: snapshotPath)
        let entityLinkURL = URL(fileURLWithPath: entityLinkPath)
        let snapshot = try JSONDecoder().decode(EntityAnchorSnapshot.self, from: Data(contentsOf: snapshotURL))
        let entityLink = try EntityLinkContractIO.load(from: entityLinkURL)

        let now = try parseDate(flags["now"]) ?? Date()
        let issuedAt = try parseDate(flags["issued-at"]) ?? now
        let preservedExpiry = ISO8601DateFormatter().date(from: snapshot.expires_at)
        let expiresAt = try parseDate(flags["expires-at"]) ?? preservedExpiry ?? issuedAt.addingTimeInterval(86_400 * 30)
        guard expiresAt > issuedAt else {
            throw AdminCLIError.invalidArguments("--expires-at must be later than --issued-at.")
        }

        let updatedSnapshot = try EntityAnchorSnapshotUpdater.acceptingEntityLink(
            snapshot: snapshot,
            entityLink: entityLink,
            adminIdentity: adminIdentity,
            snapshotID: flags["snapshot-id"],
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            entityID: flags["entity-id"],
            anchoredIdentityPublicKey: flags["anchored-public-key"],
            anchoredIdentityDomain: flags["anchored-domain"]
        )

        let outputPath = flags["out"] ?? "./entity-anchor-snapshot.updated.json"
        try emitJSON(updatedSnapshot, outPath: outputPath)
        let linkedPublicKeys = [entityLink.pubkey_a, entityLink.pubkey_b].sorted()
        let entityRecord = try requiredEntityRecord(
            snapshot: updatedSnapshot,
            contractID: entityLink.contract_id,
            linkedPublicKeys: linkedPublicKeys,
            requestedEntityID: flags["entity-id"]
        )
        let summary: [String: AnyCodable] = [
            "snapshot_path": AnyCodable(outputPath),
            "snapshot_id": AnyCodable(updatedSnapshot.snapshot_id),
            "scaffold_domain": AnyCodable(updatedSnapshot.scaffold_domain),
            "entity_id": AnyCodable(entityRecord.entity_id),
            "accepted_contract_id": AnyCodable(entityLink.contract_id),
            "linked_public_keys": AnyCodable(linkedPublicKeys)
        ]
        try emitJSON(summary, outPath: flags["summary-out"])
    }

    private static func createScaffoldTrustRootDescriptor(flags: [String: String]) throws {
        let scaffoldDomain = try requiredFlag("scaffold-domain", flags)
        let identityContext = try requiredFlag("identity-context", flags)
        let now = try parseDate(flags["now"]) ?? Date()
        let issuedAt = try parseDate(flags["issued-at"]) ?? now
        let expiresAt = try parseDate(flags["expires-at"]) ?? issuedAt.addingTimeInterval(86_400 * 30)
        guard expiresAt > issuedAt else {
            throw AdminCLIError.invalidArguments("--expires-at must be later than --issued-at.")
        }

        let descriptorID = flags["descriptor-id"] ?? "trd_\(scaffoldDomain.replacingOccurrences(of: ".", with: "_"))_\(Int(issuedAt.timeIntervalSince1970))"
        let paths = resolveVaultPaths(flags: flags)
        let adminIdentity = try VaporVaultDecoder.identity(forContext: identityContext, paths: paths)
        let defaultPublicKey = adminIdentity.publicKeyBase64URL

        let resolverPublicKeys = parseCSV(flags["resolver-public-keys"]).isEmpty
            ? [defaultPublicKey]
            : parseCSV(flags["resolver-public-keys"])
        let bridgeOwnerPublicKeys = parseCSV(flags["bridge-owner-public-keys"]).isEmpty
            ? [defaultPublicKey]
            : parseCSV(flags["bridge-owner-public-keys"])

        let defaultResolverBaseURL = URL(string: "https://\(scaffoldDomain)")!
        let resolverBaseURL = try parseURL(flags["resolver-base-url"]) ?? defaultResolverBaseURL
        let starterBootstrapURL = try parseURL(flags["starter-bootstrap-url"])
            ?? resolverBaseURL
                .appendingPathComponent("v1")
                .appendingPathComponent("resolver")
                .appendingPathComponent("starter-auth")
                .appendingPathComponent("intent")
        let bridgeDiscoveryURL = try parseURL(flags["bridge-discovery-url"])
            ?? resolverBaseURL
                .appendingPathComponent("v1")
                .appendingPathComponent("bridges")
                .appendingPathComponent("query")

        let descriptor = try ScaffoldTrustRootDescriptorBuilder.buildSignedDescriptor(
            scaffoldDomain: scaffoldDomain,
            adminIdentity: adminIdentity,
            descriptorID: descriptorID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            resolverPublicKeys: resolverPublicKeys,
            bridgeOwnerPublicKeys: bridgeOwnerPublicKeys,
            starterBootstrapURL: starterBootstrapURL,
            bridgeDiscoveryURL: bridgeDiscoveryURL,
            resolverBaseURL: resolverBaseURL
        )
        let outputPath = flags["out"] ?? "./scaffold-admin-trust-root.json"
        try emitJSON(descriptor, outPath: outputPath)
        let summary: [String: AnyCodable] = [
            "descriptor_path": AnyCodable(outputPath),
            "descriptor_id": AnyCodable(descriptor.descriptor_id),
            "scaffold_domain": AnyCodable(descriptor.scaffold_domain),
            "scaffold_admin_public_key": AnyCodable(descriptor.scaffold_admin_public_key),
            "resolver_public_keys": AnyCodable(descriptor.resolver_public_keys),
            "bridge_owner_public_keys": AnyCodable(descriptor.bridge_owner_public_keys),
            "resolver_base_url": AnyCodable(descriptor.resolver_base_url),
            "starter_bootstrap_url": AnyCodable(descriptor.starter_bootstrap_url),
            "bridge_discovery_url": AnyCodable(descriptor.bridge_discovery_url)
        ]
        try emitJSON(summary, outPath: flags["summary-out"])
    }

    private static func createContinuityProof(flags: [String: String]) throws {
        let sourceScaffoldDomain = try requiredFlag("source-scaffold-domain", flags)
        let identityContext = try requiredFlag("identity-context", flags)
        let sourceEntityID = try requiredFlag("source-entity-id", flags)
        let sourceIdentityPublicKey = try requiredFlag("source-identity-public-key", flags)
        let sourceIdentityDomain = try requiredFlag("source-identity-domain", flags)
        let targetScaffoldDomain = try requiredFlag("target-scaffold-domain", flags)
        let purpose = try requiredFlag("purpose", flags)
        let goal = try requiredFlag("goal", flags)
        let interests = parseCSV(flags["interests"])
        guard !interests.isEmpty else {
            throw AdminCLIError.invalidArguments("Missing required --interests")
        }

        let now = try parseDate(flags["now"]) ?? Date()
        let issuedAt = try parseDate(flags["issued-at"]) ?? now
        let expiresAt = try parseDate(flags["expires-at"]) ?? issuedAt.addingTimeInterval(600)
        guard expiresAt > issuedAt else {
            throw AdminCLIError.invalidArguments("--expires-at must be later than --issued-at.")
        }

        let proofID = flags["proof-id"] ?? "ccp_\(sourceScaffoldDomain.replacingOccurrences(of: ".", with: "_"))_\(Int(issuedAt.timeIntervalSince1970))"
        let paths = resolveVaultPaths(flags: flags)
        let adminIdentity = try VaporVaultDecoder.identity(forContext: identityContext, paths: paths)
        let proof = try CrossScaffoldContinuityProofBuilder.buildSignedProof(
            sourceScaffoldDomain: sourceScaffoldDomain,
            adminIdentity: adminIdentity,
            proofID: proofID,
            sourceEntityID: sourceEntityID,
            sourceIdentityPublicKey: sourceIdentityPublicKey,
            sourceIdentityDomain: sourceIdentityDomain,
            targetScaffoldDomain: targetScaffoldDomain,
            purpose: purpose,
            goal: goal,
            interests: interests,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
        let outputPath = flags["out"] ?? "./cross-scaffold-continuity-proof.json"
        try emitJSON(proof, outPath: outputPath)
        let summary: [String: AnyCodable] = [
            "proof_path": AnyCodable(outputPath),
            "proof_id": AnyCodable(proof.proof_id),
            "source_scaffold_domain": AnyCodable(proof.source_scaffold_domain),
            "source_entity_id": AnyCodable(proof.source_entity_id),
            "target_scaffold_domain": AnyCodable(proof.target_scaffold_domain),
            "issued_by": AnyCodable(proof.issued_by)
        ]
        try emitJSON(summary, outPath: flags["summary-out"])
    }

    private static func createAdmissionContract(flags: [String: String]) throws {
        let targetScaffoldDomain = try requiredFlag("target-scaffold-domain", flags)
        let targetEntityID = try requiredFlag("target-entity-id", flags)
        let targetIdentityPublicKey = try requiredFlag("target-identity-public-key", flags)
        let targetIdentityDomain = try requiredFlag("target-identity-domain", flags)
        let identityContext = try requiredFlag("identity-context", flags)
        let continuityProofPath = try requiredFlag("continuity-proof", flags)
        let admissionRequestPath = try requiredFlag("admission-request", flags)

        let continuityProof = try JSONDecoder().decode(
            CrossScaffoldEntityContinuityProof.self,
            from: Data(contentsOf: URL(fileURLWithPath: continuityProofPath))
        )
        let admissionRequest = try JSONDecoder().decode(
            EntityAdmissionRequest.self,
            from: Data(contentsOf: URL(fileURLWithPath: admissionRequestPath))
        )
        guard try continuityProof.verifySignature(), !continuityProof.isExpired(now: try parseDate(flags["now"]) ?? Date()) else {
            throw AdminCLIError.invalidArguments("Continuity proof is invalid or expired.")
        }
        guard try admissionRequest.verifySignature(), !admissionRequest.isExpired(now: try parseDate(flags["now"]) ?? Date()) else {
            throw AdminCLIError.invalidArguments("Admission request is invalid or expired.")
        }

        let now = try parseDate(flags["now"]) ?? Date()
        let issuedAt = try parseDate(flags["issued-at"]) ?? now
        let expiresAt = try parseDate(flags["expires-at"]) ?? issuedAt.addingTimeInterval(600)
        guard expiresAt > issuedAt else {
            throw AdminCLIError.invalidArguments("--expires-at must be later than --issued-at.")
        }

        let contractID = flags["contract-id"] ?? "eac_\(targetScaffoldDomain.replacingOccurrences(of: ".", with: "_"))_\(Int(issuedAt.timeIntervalSince1970))"
        let paths = resolveVaultPaths(flags: flags)
        let adminIdentity = try VaporVaultDecoder.identity(forContext: identityContext, paths: paths)
        let contract = try EntityAdmissionContractBuilder.buildSignedContract(
            targetScaffoldDomain: targetScaffoldDomain,
            adminIdentity: adminIdentity,
            contractID: contractID,
            targetEntityID: targetEntityID,
            targetIdentityPublicKey: targetIdentityPublicKey,
            targetIdentityDomain: targetIdentityDomain,
            continuityProof: continuityProof,
            admissionRequest: admissionRequest,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
        let outputPath = flags["out"] ?? "./entity-admission-contract.json"
        try emitJSON(contract, outPath: outputPath)
        let summary: [String: AnyCodable] = [
            "contract_path": AnyCodable(outputPath),
            "contract_id": AnyCodable(contract.contract_id),
            "target_scaffold_domain": AnyCodable(contract.target_scaffold_domain),
            "target_entity_id": AnyCodable(contract.target_entity_id),
            "continuity_proof_id": AnyCodable(contract.continuity_proof_id),
            "issued_by": AnyCodable(contract.issued_by)
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

    private static func parseURL(_ raw: String?) throws -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let url = URL(string: raw) else {
            throw AdminCLIError.invalidArguments("Invalid URL: \(raw)")
        }
        return url
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

    private static func requiredEntityRecord(
        snapshot: EntityAnchorSnapshot,
        contractID: String,
        linkedPublicKeys: [String],
        requestedEntityID: String?
    ) throws -> EntityAnchorEntityRecord {
        if let requestedEntityID,
           let record = snapshot.entities.first(where: { $0.entity_id == requestedEntityID }) {
            return record
        }

        if let record = snapshot.entities.first(where: { record in
            record.accepted_entity_link_contract_ids.contains(contractID) &&
                !Set(record.identities.map(\.identity_public_key)).intersection(linkedPublicKeys).isEmpty
        }) {
            return record
        }

        throw AdminCLIError.invalidArguments("Updated snapshot does not contain an entity record accepting contract \(contractID).")
    }

    private static let usage = """
    Usage:
      sprout-admin vapor-vault list-identities [--vault-root <dir>] [--vault-file <path>] [--master-key-file <path>] [--out <file>]
      sprout-admin entity-anchor create-from-vapor-vault --scaffold-domain <domain> --identity-context <ctx> --entity-id <id> --subject-public-key <b64url> --subject-domain <domain> [--accepted-contract-ids <id1,id2>] [--vault-root <dir>] [--vault-file <path>] [--master-key-file <path>] [--snapshot-id <id>] [--issued-at <ISO8601>] [--expires-at <ISO8601>] [--added-at <ISO8601>] [--now <ISO8601>] [--out <file>] [--summary-out <file>]
      sprout-admin entity-anchor accept-entity-link --snapshot <snapshot.json> --entity-link <entity-link.json> --identity-context <ctx> [--entity-id <id> | --anchored-public-key <b64url> [--anchored-domain <domain>]] [--vault-root <dir>] [--vault-file <path>] [--master-key-file <path>] [--snapshot-id <id>] [--issued-at <ISO8601>] [--expires-at <ISO8601>] [--now <ISO8601>] [--out <file>] [--summary-out <file>]
      sprout-admin scaffold-trust-root create-from-vapor-vault --scaffold-domain <domain> --identity-context <ctx> [--resolver-public-keys <k1,k2>] [--bridge-owner-public-keys <k1,k2>] [--resolver-base-url <https://domain>] [--starter-bootstrap-url <https://domain/v1/resolver/starter-auth/intent>] [--bridge-discovery-url <https://domain/v1/bridges/query>] [--vault-root <dir>] [--vault-file <path>] [--master-key-file <path>] [--descriptor-id <id>] [--issued-at <ISO8601>] [--expires-at <ISO8601>] [--now <ISO8601>] [--out <file>] [--summary-out <file>]
      sprout-admin continuity-proof create-from-vapor-vault --source-scaffold-domain <domain> --identity-context <ctx> --source-entity-id <id> --source-identity-public-key <b64url> --source-identity-domain <domain> --target-scaffold-domain <domain> --purpose <purpose> --goal <goal> --interests <i1,i2> [--vault-root <dir>] [--vault-file <path>] [--master-key-file <path>] [--proof-id <id>] [--issued-at <ISO8601>] [--expires-at <ISO8601>] [--now <ISO8601>] [--out <file>] [--summary-out <file>]
      sprout-admin admission-contract create-from-vapor-vault --target-scaffold-domain <domain> --target-entity-id <id> --target-identity-public-key <b64url> --target-identity-domain <domain> --identity-context <ctx> --continuity-proof <file> --admission-request <file> [--vault-root <dir>] [--vault-file <path>] [--master-key-file <path>] [--contract-id <id>] [--issued-at <ISO8601>] [--expires-at <ISO8601>] [--now <ISO8601>] [--out <file>] [--summary-out <file>]
    """
}

private struct AnyCodable: Encodable {
    private let value: any Encodable

    init(_ value: any Encodable) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}
