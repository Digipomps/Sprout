import Foundation
import SproutCore
import SproutCrypto

@main
struct SproutUpdater {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            printUsage()
            exit(1)
        }

        switch arguments[0] {
        case "plan":
            try runPlan(arguments: Array(arguments.dropFirst()))
        case "verify-bundle":
            try runVerifyBundle(arguments: Array(arguments.dropFirst()))
        default:
            printUsage()
            exit(1)
        }
    }

    private static func runPlan(arguments: [String]) throws {
        let flags = try parseFlags(arguments)
        let artifactPath = try requiredFlag("artifact-path", flags)
        let policyPath = try requiredFlag("policy", flags)
        let artifactName = try requiredFlag("artifact-name", flags)
        let artifactVersion = try requiredFlag("version", flags)
        let channel = try requiredFlag("channel", flags)
        let trigger = try requiredFlag("trigger", flags)

        let artifactData = try Data(contentsOf: URL(fileURLWithPath: artifactPath))
        let policyData = try Data(contentsOf: URL(fileURLWithPath: policyPath))
        let policy = try JSONDecoder().decode(UpdateGrantPolicy.self, from: policyData)

        let request = UpdateRequest(
            artifact_name: artifactName,
            artifact_sha256_b64url: Hashing.sha256Base64URL(artifactData),
            artifact_semver: artifactVersion,
            channel: channel,
            trigger_identity: trigger,
            is_automatic: flags["auto"] == "true"
        )

        let decision = UpdatePolicyEnforcer.evaluate(request: request, policy: policy)
        switch decision {
        case .allow:
            let plan = UpdateInstallPlan(
                artifact_name: artifactName,
                artifact_path: artifactPath,
                artifact_sha256_b64url: request.artifact_sha256_b64url,
                artifact_semver: artifactVersion,
                channel: channel,
                trigger_identity: trigger,
                policy_path: policyPath,
                installation_mode: "operator-applied",
                status: "authorized"
            )
            print(String(data: try JSONEncoder.pretty.encode(plan), encoding: .utf8) ?? "{}")
        case let .deny(reason):
            let plan = UpdateInstallPlan(
                artifact_name: artifactName,
                artifact_path: artifactPath,
                artifact_sha256_b64url: request.artifact_sha256_b64url,
                artifact_semver: artifactVersion,
                channel: channel,
                trigger_identity: trigger,
                policy_path: policyPath,
                installation_mode: "operator-applied",
                status: "denied",
                reason: reason
            )
            print(String(data: try JSONEncoder.pretty.encode(plan), encoding: .utf8) ?? "{}")
            exit(2)
        }
    }

    private static func runVerifyBundle(arguments: [String]) throws {
        let flags = try parseFlags(arguments)
        let artifactPath = try requiredFlag("artifact-path", flags)
        let checksumPath = try requiredFlag("checksum-file", flags)

        let artifactURL = URL(fileURLWithPath: artifactPath)
        let artifactName = artifactURL.lastPathComponent
        let artifactData = try Data(contentsOf: artifactURL)
        let expectedLines = try String(contentsOfFile: checksumPath, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)

        let expectedHash = try checksumHash(for: artifactName, lines: expectedLines)
        let actualHash = Hashing.sha256Base64URL(artifactData)
        let result = BundleVerificationResult(
            artifact_name: artifactName,
            expected_sha256_b64url: expectedHash,
            actual_sha256_b64url: actualHash,
            verified: expectedHash == actualHash
        )

        print(String(data: try JSONEncoder.pretty.encode(result), encoding: .utf8) ?? "{}")
        if !result.verified {
            exit(2)
        }
    }

    private static func checksumHash(for artifactName: String, lines: [String]) throws -> String {
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let hash = String(parts[0])
            let file = String(parts[parts.count - 1]).replacingOccurrences(of: "*", with: "")
            if file == artifactName {
                let data = Data(base64Encoded: hash) ?? (try? Base64URL.decode(hash))
                guard let data else { throw UpdaterError.invalidChecksumFormat }
                return Base64URL.encode(data)
            }
        }
        throw UpdaterError.missingChecksumEntry(artifactName)
    }

    private static func parseFlags(_ arguments: [String]) throws -> [String: String] {
        var flags = [String: String]()
        var index = 0
        while index < arguments.count {
            let current = arguments[index]
            if current.hasPrefix("--") {
                let key = String(current.dropFirst(2))
                let nextIndex = index + 1
                if nextIndex < arguments.count, !arguments[nextIndex].hasPrefix("--") {
                    flags[key] = arguments[nextIndex]
                    index += 2
                } else {
                    flags[key] = "true"
                    index += 1
                }
            } else {
                throw UpdaterError.invalidArguments("Unexpected argument: \(current)")
            }
        }
        return flags
    }

    private static func requiredFlag(_ name: String, _ flags: [String: String]) throws -> String {
        guard let value = flags[name], !value.isEmpty else {
            throw UpdaterError.invalidArguments("Missing --\(name)")
        }
        return value
    }

    private static func printUsage() {
        let text = """
        sprout-updater commands:
          sprout-updater plan --policy <policy.json> --artifact-path <file> --artifact-name <name> --version <semver> --channel <stable|beta> --trigger <pubkey-or-contract> [--auto]
          sprout-updater verify-bundle --artifact-path <file> --checksum-file <SHA256SUMS.b64url>
        """
        print(text)
    }
}

private struct UpdateInstallPlan: Codable {
    var artifact_name: String
    var artifact_path: String
    var artifact_sha256_b64url: String
    var artifact_semver: String
    var channel: String
    var trigger_identity: String
    var policy_path: String
    var installation_mode: String
    var status: String
    var reason: String?
}

private struct BundleVerificationResult: Codable {
    var artifact_name: String
    var expected_sha256_b64url: String
    var actual_sha256_b64url: String
    var verified: Bool
}

private enum UpdaterError: Error {
    case invalidArguments(String)
    case missingChecksumEntry(String)
    case invalidChecksumFormat
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
