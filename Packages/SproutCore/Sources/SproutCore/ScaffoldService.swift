import Foundation
import SproutResolverAdapter
import SproutCrypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum ScaffoldServiceError: Error, Equatable, CustomStringConvertible {
    case unsupportedPlatform
    case rootRequired
    case invalidConfiguration
    case missingServiceProfile
    case multipleServices
    case pythonUnavailable
    case invalidResponse
    case coordinatorFailed(Int32, String)

    public var description: String {
        switch self {
        case .unsupportedPlatform: return "Automatisk tjenesteoppstart krever Linux. Bruk --download-only for bare bildeinstallasjon."
        case .rootRequired: return "Tjenesteinstallasjon krever root. Start den samme sprout-kommandoen med sudo."
        case .invalidConfiguration: return "Ugyldig instans, port eller HTTPS-adresse. Bruk --instance NAME --port 9089 --public-origin https://HOST."
        case .missingServiceProfile: return "Den signerte katalogen mangler en stoettet tjenesteprofil for formaalet."
        case .multipleServices: return "Denne tjenesteprofilen installerer en scaffold per instans. Velg formaal for samme scaffold, eller bruk separate instanser."
        case .pythonUnavailable: return "Tjenesteoppstart krever Python 3 paa /usr/bin/python3."
        case .invalidResponse: return "Oppstartskoordinatoren returnerte en ugyldig kvittering. Ingen tjenesteaksept er bekreftet."
        case .coordinatorFailed(let code, let reason): return "Tjenesteoppsett stoppet (\(code)): \(reason). Eksisterende noekler og tilstand er beholdt."
        }
    }
}

/// Only the fixed, signed service profile is executable. Catalogs cannot supply
/// shell fragments, host paths, Docker flags, private keys or arbitrary env.
public struct ScaffoldServiceRequest: Codable, Equatable, Sendable {
    public let schema: String
    public var operation: String
    public let image: String?
    public let platform: String?
    public let profile: String?
    public let instance: String
    public let listen_port: Int?
    public let public_origin: String?
    public let root: String
    public let purposes: [String]?

    public static func make(plan: ScaffoldInstallationPlan, instance: String,
                            port: Int, publicOrigin: String) throws -> Self {
        guard validInstance(instance), (1024...65535).contains(port), validOrigin(publicOrigin) else {
            throw ScaffoldServiceError.invalidConfiguration
        }
        let services = plan.artifacts.filter { $0.installation?.service_profile != nil }
        guard !services.isEmpty else { throw ScaffoldServiceError.missingServiceProfile }
        guard services.count == 1 else { throw ScaffoldServiceError.multipleServices }
        let artifact = services[0]
        guard artifact.kind == "cellscaffold", let installation = artifact.installation,
              installation.service_profile == "cellscaffold-web-v1",
              Set(plan.purposes).isSubset(of: Set(artifact.purpose_ids ?? [])) else {
            throw ScaffoldServiceError.missingServiceProfile
        }
        try ScaffoldInstallationPlan.validateInstallable(artifact, publisher: plan.publisher)
        return Self(schema: "haven.sprout.service-request.v1", operation: "install",
            image: installation.image, platform: installation.container_platform,
            profile: installation.service_profile, instance: instance, listen_port: port,
            public_origin: publicOrigin, root: "/var/lib/haven/sprout", purposes: plan.purposes)
    }

    public static func status(instance: String) throws -> Self {
        guard validInstance(instance) else { throw ScaffoldServiceError.invalidConfiguration }
        return Self(schema: "haven.sprout.service-request.v1", operation: "status",
            image: nil, platform: nil, profile: nil, instance: instance, listen_port: nil,
            public_origin: nil, root: "/var/lib/haven/sprout", purposes: nil)
    }

    public static func validInstance(_ value: String) -> Bool {
        value.range(of: #"^[a-z][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil
            && !value.hasSuffix("-")
    }

    public static func validOrigin(_ value: String) -> Bool {
        guard value.utf8.count <= 253, let origin = URLComponents(string: value),
              origin.scheme == "https", let host = origin.host, host.contains("."),
              host == host.lowercased(), host.range(of: #"^[a-z0-9]+([.-][a-z0-9]+)*$"#, options: .regularExpression) != nil,
              host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil,
              origin.user == nil, origin.password == nil,
              origin.port.map({ (1...65535).contains($0) }) ?? true,
              origin.query == nil, origin.fragment == nil, origin.path.isEmpty,
              origin.string == value else { return false }
        return true
    }
}

public enum ScaffoldServiceController {
    public static func requireHostAccess() throws {
        #if !os(Linux)
        throw ScaffoldServiceError.unsupportedPlatform
        #else
        guard geteuid() == 0 else { throw ScaffoldServiceError.rootRequired }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw ScaffoldServiceError.pythonUnavailable
        }
        #endif
    }

    /// The coordinator is embedded in the reviewed executable; no neighboring
    /// writable script or PYTHONPATH can replace root's implementation.
    public static func run(_ request: ScaffoldServiceRequest) async throws -> Data {
        try requireHostAccess()
        let input = try JSONEncoder().encode(request)
        let source = String(decoding: ScaffoldServiceProgram.data, as: UTF8.self)
        let result: (Int32, Data) = try await Task.detached {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-service-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let outputURL = directory.appendingPathComponent("result.json")
            guard FileManager.default.createFile(atPath: outputURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                throw ScaffoldServiceError.invalidResponse
            }
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            let process = Process()
            let inputPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", "-c", source]
            // Python's isolated mode also ignores user site-packages. The native
            // coordinator supplies its own allowlisted environment to children.
            process.environment = ["PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8"]
            process.standardInput = inputPipe
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            try process.run()
            try inputPipe.fileHandleForWriting.write(contentsOf: input)
            try inputPipe.fileHandleForWriting.close()
            process.waitUntilExit()
            let size = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber
            guard let size, size.intValue <= 1_048_576 else { throw ScaffoldServiceError.invalidResponse }
            return (process.terminationStatus, try Data(contentsOf: outputURL))
        }.value
        guard let receipt = try JSONSerialization.jsonObject(with: result.1) as? [String: Any] else {
            throw ScaffoldServiceError.invalidResponse
        }
        if result.0 != 0 {
            let value = (receipt["reason"] as? String) ?? (receipt["error"] as? String) ?? "coordinator_failed"
            let reason = value.utf8.count <= 100 && value.range(of: #"^[a-zA-Z0-9_.:-]+$"#, options: .regularExpression) != nil ? value : "coordinator_failed"
            throw ScaffoldServiceError.coordinatorFailed(result.0, reason)
        }
        guard receipt["schema"] as? String == "haven.sprout.service-receipt.v1",
              receipt["instance"] as? String == request.instance,
              receipt["status"] as? String != "failed" else { throw ScaffoldServiceError.invalidResponse }
        if request.operation == "install" {
            guard receipt["status"] as? String == "ready", receipt["image"] as? String == request.image else {
                throw ScaffoldServiceError.invalidResponse
            }
        }
        if request.operation == "preflight" {
            guard receipt["status"] as? String == "preflight-ready", receipt["writes"] as? Bool == false else {
                throw ScaffoldServiceError.invalidResponse
            }
        }
        return result.1
    }
}
