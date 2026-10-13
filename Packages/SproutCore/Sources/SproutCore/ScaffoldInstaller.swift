import Foundation
import SproutCrypto
import SproutResolverAdapter
import SproutStorage

public protocol ScaffoldImageRuntime: Sendable {
    func pull(image: String, platform: String) async throws
    func contains(image: String, platform: String) async throws -> Bool
}

/// Docker is the optional OCI runtime, not a dependency of Sprout identity/CLI.
/// Arguments are passed directly to exec, never interpolated into a shell.
public struct DockerScaffoldRuntime: ScaffoldImageRuntime {
    public let executable: URL
    public let localDaemon: Bool

    public init(executable: URL? = nil, localDaemon: Bool = false) throws {
        let paths = ["/usr/bin/docker", "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker/bin/docker").path]
        guard let candidate = executable ?? paths.first(where: FileManager.default.isExecutableFile(atPath:)).map({ URL(fileURLWithPath: $0) }) else {
            throw ScaffoldInstallationError.dockerUnavailable
        }
        self.executable = candidate
        self.localDaemon = localDaemon
    }

    public func pull(image: String, platform: String) async throws {
        _ = try await run(["pull", "--platform", platform, image], capture: false)
    }

    public func contains(image: String, platform: String) async throws -> Bool {
        let data = try await run(["image", "inspect", "--format", "{\"digests\":{{json .RepoDigests}},\"os\":{{json .Os}},\"architecture\":{{json .Architecture}}}", image], capture: true, missingImage: image)
        let report = try JSONDecoder().decode(DockerImageReport.self, from: data)
        return (report.digests ?? []).map(ScaffoldInstallationPlan.normalizedOCIReference).contains(ScaffoldInstallationPlan.normalizedOCIReference(image)) && "\(report.os)/\(report.architecture)" == platform
    }

    private func run(_ arguments: [String], capture: Bool, missingImage: String? = nil) async throws -> Data {
        let executable = executable
        let localDaemon = localDaemon
        return try await Task.detached {
            // A file avoids pipe backpressure while Docker reports large image pulls.
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-docker-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: outputURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                throw PrivateStateError.ioFailure
            }
            defer { try? FileManager.default.removeItem(at: outputURL) }
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = executable
            process.arguments = (localDaemon ? ["--host", "unix:///var/run/docker.sock"] : []) + arguments
            if localDaemon {
                var environment = ProcessInfo.processInfo.environment
                for key in ["DOCKER_CONTEXT", "DOCKER_HOST", "DOCKER_TLS", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"] {
                    environment.removeValue(forKey: key)
                }
                process.environment = environment
            }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = capture ? output : FileHandle.standardError
            let errorURL = outputURL.appendingPathExtension("stderr")
            guard FileManager.default.createFile(atPath: errorURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                throw PrivateStateError.ioFailure
            }
            defer { try? FileManager.default.removeItem(at: errorURL) }
            let errors = try FileHandle(forWritingTo: errorURL)
            defer { try? errors.close() }
            process.standardError = missingImage == nil ? FileHandle.standardError : errors
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                if let missingImage, process.terminationStatus == 1 {
                    let handle = try FileHandle(forReadingFrom: errorURL)
                    defer { try? handle.close() }
                    let errorData = try handle.read(upToCount: 65_537) ?? Data()
                    let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if message == "Error response from daemon: No such image: \(missingImage)" {
                        return Data(#"{"digests":[],"os":"","architecture":""}"#.utf8)
                    }
                }
                throw ScaffoldInstallationError.dockerFailed(process.terminationStatus)
            }
            if !capture { return Data() }
            let size = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber
            guard let size, size.intValue <= 65_536 else { throw ScaffoldInstallationError.receiptMismatch }
            return try Data(contentsOf: outputURL)
        }.value
    }
}

public struct ScaffoldInstallationReceipt: Codable, Equatable, Sendable {
    public var version = 1
    public var artifact_id: String
    public var image: String
    public var platform: String
    public var installed_at: String
    public var catalog_id: String
    public var catalog_sha256_b64url: String
    public var publisher: String
    public var scaffold_domain: String
    public var purposes: [String]
    public var status: String
}

public struct ScaffoldInstaller: Sendable {
    public let root: URL
    public let runtime: any ScaffoldImageRuntime

    public init(root: URL, runtime: any ScaffoldImageRuntime) {
        self.root = root
        self.runtime = runtime
    }

    /// Revalidate the signed catalog at apply time, not a caller-editable plan.
    /// Successful pulls are resumable, but receipt publication is all-or-nothing.
    public func install(catalog: ScaffoldExecutableCatalog, domain: String, publisherKeys: [String],
                        purposes: [String], platform: String = ScaffoldInstallationPlan.hostPlatform,
                        channel: String = "stable", offline: Bool = false) async throws -> [ScaffoldInstallationReceipt] {
        let plan = try ScaffoldInstallationPlan.make(catalog: catalog, domain: domain, publisherKeys: publisherKeys,
                                                    purposes: purposes, platform: platform, channel: channel)
        let lock = try PrivateStateLock(directory: root)
        defer { withExtendedLifetime(lock) {} }
        var receipts: [ScaffoldInstallationReceipt] = []
        for artifact in plan.artifacts {
            _ = try ScaffoldInstallationPlan.make(catalog: catalog, domain: domain, publisherKeys: publisherKeys,
                                                 purposes: purposes, platform: platform, channel: channel)
            guard let spec = artifact.installation else { throw ScaffoldInstallationError.unsupportedArtifact(artifact.artifact_id) }
            if !offline { try await runtime.pull(image: spec.image, platform: spec.container_platform) }
            guard try await runtime.contains(image: spec.image, platform: spec.container_platform) else { throw ScaffoldInstallationError.digestNotInstalled }
            receipts.append(.init(artifact_id: artifact.artifact_id, image: spec.image, platform: spec.container_platform,
                installed_at: ISO8601DateFormatter().string(from: Date()), catalog_id: plan.catalog_id,
                catalog_sha256_b64url: plan.catalog_sha256_b64url, publisher: plan.publisher,
                scaffold_domain: domain, purposes: plan.purposes, status: "installed-not-started"))
        }
        _ = try ScaffoldInstallationPlan.make(catalog: catalog, domain: domain, publisherKeys: publisherKeys,
                                             purposes: purposes, platform: platform, channel: channel)
        // A single atomic transaction includes its signed source and all receipts.
        let record = InstallationRecord(catalog: catalog, receipts: receipts)
        let name = Hashing.sha256Base64URL(Data((domain + "\n" + plan.purposes.joined(separator: "\n") + "\n" + platform + "\n" + channel).utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(record)
        guard bytes.count <= 1_048_576 else { throw ScaffoldInstallationError.invalidCatalog }
        let destination = root.appendingPathComponent(name + ".json")
        // PrivateStateFiles.write's default overwrite read cap is 64 KiB.
        if PrivateStateFiles.exists(destination) { _ = try PrivateStateFiles.read(destination, maximumBytes: 1_048_576) }
        try bytes.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return receipts
    }

    public func inspect() async throws -> [ScaffoldInstallationReceipt] {
        let lock = try PrivateStateLock(directory: root)
        defer { withExtendedLifetime(lock) {} }
        var receipts: [ScaffoldInstallationReceipt] = []
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) where file.pathExtension == "json" {
            let record = try JSONDecoder().decode(InstallationRecord.self, from: PrivateStateFiles.read(file, maximumBytes: 1_048_576))
            guard try record.catalog.verifySignature(), let first = record.receipts.first,
                  let installedAt = ISO8601DateFormatter().date(from: first.installed_at), installedAt <= Date(),
                  let firstArtifact = record.catalog.artifacts.first(where: { $0.artifact_id == first.artifact_id }) else {
                throw ScaffoldInstallationError.receiptMismatch
            }
            let originalPlan: ScaffoldInstallationPlan
            do {
                originalPlan = try ScaffoldInstallationPlan.make(catalog: record.catalog,
                    domain: first.scaffold_domain, publisherKeys: [first.publisher], purposes: first.purposes,
                    platform: firstArtifact.platform, channel: firstArtifact.channel, now: installedAt)
            } catch { throw ScaffoldInstallationError.receiptMismatch }
            guard record.receipts.map(\.artifact_id) == originalPlan.artifacts.map(\.artifact_id),
                  record.receipts.allSatisfy({ $0.purposes == originalPlan.purposes }) else {
                throw ScaffoldInstallationError.receiptMismatch
            }
            for var receipt in record.receipts {
                guard receipt.version == 1, receipt.publisher == record.catalog.issued_by,
                      receipt.scaffold_domain == record.catalog.scaffold_domain,
                      receipt.catalog_id == record.catalog.catalog_id,
                      receipt.catalog_sha256_b64url == Hashing.sha256Base64URL(try record.catalog.canonicalPayloadData()),
                      let artifact = record.catalog.artifacts.first(where: { $0.artifact_id == receipt.artifact_id }),
                      artifact.installation?.image == receipt.image,
                      artifact.installation?.container_platform == receipt.platform,
                      !receipt.purposes.isEmpty,
                      receipt.purposes.allSatisfy(ScaffoldInstallationPlan.validPurpose),
                      receipt.status == "installed-not-started",
                      ISO8601DateFormatter().date(from: receipt.installed_at) != nil else { throw ScaffoldInstallationError.receiptMismatch }
                try ScaffoldInstallationPlan.validateInstallable(artifact, publisher: receipt.publisher)
                receipt.status = (try await runtime.contains(image: receipt.image, platform: receipt.platform)) ? "installed-not-started" : "missing-image"
                receipts.append(receipt)
            }
        }
        return receipts
    }
}

private struct InstallationRecord: Codable {
    var catalog: ScaffoldExecutableCatalog
    var receipts: [ScaffoldInstallationReceipt]
}

private struct DockerImageReport: Decodable {
    var digests: [String]?
    var os: String
    var architecture: String
}
