import Foundation
import SproutCrypto
import SproutResolverAdapter

public enum ScaffoldInstallationError: Error, Equatable {
    case invalidCatalog
    case publisherPinRequired
    case invalidPurpose
    case purposeUnavailable(String)
    case ambiguousPurpose(String)
    case missingDependency(String)
    case dependencyCycle
    case unsupportedArtifact(String)
    case dockerUnavailable
    case dockerFailed(Int32)
    case digestNotInstalled
    case receiptMismatch
}

/// All inputs are resolved before the first pull. This is exact declared-purpose
/// matching, not an inference that arbitrary prose implies a capability.
public struct ScaffoldInstallationPlan: Codable, Equatable, Sendable {
    public var catalog_id: String
    public var catalog_sha256_b64url: String
    public var scaffold_domain: String
    public var publisher: String
    public var purposes: [String]
    public var platform: String
    public var artifacts: [ScaffoldExecutableArtifact]

    public static func make(catalog: ScaffoldExecutableCatalog, domain: String, publisherKeys: [String],
                            purposes: [String], platform: String, channel: String = "stable",
                            now: Date = Date()) throws -> Self {
        guard !publisherKeys.isEmpty else { throw ScaffoldInstallationError.publisherPinRequired }
        try ScaffoldExecutableCatalogValidator().validate(catalog: catalog, context: .init(
            expectedDomain: domain, trustedPublisherPublicKeys: publisherKeys, now: now))
        guard catalog.version == "1.1", catalog.artifacts.count <= 128,
              Set(catalog.artifacts.map(\.artifact_id)).count == catalog.artifacts.count,
              let issued = ISO8601DateFormatter().date(from: catalog.issued_at), issued <= now else {
            throw ScaffoldInstallationError.invalidCatalog
        }
        let purposes = Array(Set(purposes)).sorted()
        guard !purposes.isEmpty, purposes.count <= 16, purposes.allSatisfy(validPurpose) else {
            throw ScaffoldInstallationError.invalidPurpose
        }
        let byID = Dictionary(uniqueKeysWithValues: catalog.artifacts.map { ($0.artifact_id, $0) })
        var visiting = Set<String>(), visited = Set<String>(), selected: [ScaffoldExecutableArtifact] = []
        func visit(_ artifact: ScaffoldExecutableArtifact) throws {
            if visited.contains(artifact.artifact_id) { return }
            guard visiting.insert(artifact.artifact_id).inserted else { throw ScaffoldInstallationError.dependencyCycle }
            guard artifact.platform == platform, artifact.channel == channel else {
                throw ScaffoldInstallationError.unsupportedArtifact(artifact.artifact_id)
            }
            try validateInstallable(artifact, publisher: catalog.issued_by)
            for id in (artifact.dependencies ?? []).sorted() {
                guard let dependency = byID[id] else { throw ScaffoldInstallationError.missingDependency(id) }
                try visit(dependency)
            }
            visiting.remove(artifact.artifact_id)
            visited.insert(artifact.artifact_id)
            selected.append(artifact)
        }
        for purpose in purposes {
            let matches = catalog.artifacts.filter {
                $0.platform == platform && $0.channel == channel && ($0.purpose_ids ?? []).contains(purpose)
            }
            guard !matches.isEmpty else { throw ScaffoldInstallationError.purposeUnavailable(purpose) }
            guard matches.count == 1 else { throw ScaffoldInstallationError.ambiguousPurpose(purpose) }
            try visit(matches[0])
        }
        return Self(catalog_id: catalog.catalog_id,
                    catalog_sha256_b64url: Hashing.sha256Base64URL(try catalog.canonicalPayloadData()),
                    scaffold_domain: domain, publisher: catalog.issued_by, purposes: purposes,
                    platform: platform, artifacts: selected)
    }

    public static func validPurpose(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:/._-").contains($0)
        }
    }

    public static func validateInstallable(_ artifact: ScaffoldExecutableArtifact, publisher: String) throws {
        guard ["cellscaffold", "scaffold-bundle"].contains(artifact.kind),
              validPurpose(artifact.artifact_id),
              ["linux-x86_64", "linux-arm64", "macos-x86_64", "macos-arm64"].contains(artifact.platform),
              let install = artifact.installation, install.format == "oci-image",
              ["linux/amd64", "linux/arm64"].contains(install.container_platform),
              install.image.range(of: #"^[a-z0-9]+([.-][a-z0-9]+)*(:[0-9]+)?/[a-z0-9]+([._/-][a-z0-9]+)*@sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              artifact.signing.contains(where: { $0.type == "catalog-ed25519" && $0.identity == publisher }),
              (artifact.purpose_ids ?? []).allSatisfy(validPurpose),
              (artifact.dependencies ?? []).count <= 128 else {
            throw ScaffoldInstallationError.unsupportedArtifact(artifact.artifact_id)
        }
        if artifact.platform == "linux-x86_64", install.container_platform != "linux/amd64" {
            throw ScaffoldInstallationError.unsupportedArtifact(artifact.artifact_id)
        }
        if artifact.platform == "linux-arm64", install.container_platform != "linux/arm64" {
            throw ScaffoldInstallationError.unsupportedArtifact(artifact.artifact_id)
        }
        let pieces = install.image.split(separator: "@")
        let digest = String(pieces[1].dropFirst("sha256:".count))
        let expected = try Base64URL.decode(artifact.sha256_b64url).map { String(format: "%02x", $0) }.joined()
        let address = pieces[0].split(separator: "/", maxSplits: 1)
        let registry = String(address[0])
        guard registry.contains(".") || registry.contains(":") || registry == "localhost" else {
            throw ScaffoldInstallationError.unsupportedArtifact(artifact.artifact_id)
        }
        guard install.image == normalizedOCIReference(install.image), digest == expected,
              artifact.download_url == "https://\(address[0])/v2/\(address[1])/manifests/sha256:\(digest)" else {
            throw ScaffoldInstallationError.unsupportedArtifact(artifact.artifact_id)
        }
    }

    /// Docker Hub strips its domain and the official-image library namespace
    /// in familiar RepoDigests. Preserve the complete repository + digest when
    /// normalizing; a matching digest from another repository is insufficient.
    static func normalizedOCIReference(_ reference: String) -> String {
        let components = reference.split(separator: "/", maxSplits: 1)
        guard let first = components.first else { return reference }
        if components.count == 1 { return "docker.io/library/" + reference }
        let host = String(first)
        if host == "index.docker.io" || host == "docker.io" {
            let repository = String(components[1])
            return "docker.io/" + (repository.contains("/") ? "" : "library/") + repository
        }
        if !host.contains("."), !host.contains(":"), host != "localhost" { return "docker.io/" + reference }
        return reference
    }

    public static var hostPlatform: String {
        #if os(Linux)
        let os = "linux"
        #else
        let os = "macos"
        #endif
        #if arch(arm64)
        return os + "-arm64"
        #else
        return os + "-x86_64"
        #endif
    }
}
