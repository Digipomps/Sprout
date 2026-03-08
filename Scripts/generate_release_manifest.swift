import Foundation

struct ReleaseArtifact: Codable {
    let name: String
    let size_bytes: Int
    let sha256_b64url: String
}

struct ReleaseManifest: Codable {
    let generated_at: String
    let artifacts: [ReleaseArtifact]
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    fputs("usage: generate_release_manifest.swift <dist-dir> <artifact> [<artifact> ...]\n", stderr)
    exit(1)
}

let distDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
let artifactPaths = Array(arguments.dropFirst(2))
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime]

let artifacts: [ReleaseArtifact] = try artifactPaths.map { path in
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return ReleaseArtifact(
        name: url.lastPathComponent,
        size_bytes: data.count,
        sha256_b64url: try sha256Base64URL(for: url)
    )
}

let manifest = ReleaseManifest(
    generated_at: formatter.string(from: Date()),
    artifacts: artifacts.sorted { $0.name < $1.name }
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let manifestData = try encoder.encode(manifest)
try manifestData.write(to: distDir.appendingPathComponent("release-manifest.json"), options: [.atomic])

let sums = manifest.artifacts
    .map { "\($0.sha256_b64url) *\($0.name)" }
    .joined(separator: "\n") + "\n"
try Data(sums.utf8).write(to: distDir.appendingPathComponent("SHA256SUMS.b64url"), options: [.atomic])

func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func sha256Base64URL(for url: URL) throws -> String {
    let hexDigest = try sha256HexDigest(for: url)
    return base64url(try dataFromHex(hexDigest))
}

func sha256HexDigest(for url: URL) throws -> String {
    let candidates: [[String]] = [
        ["shasum", "-a", "256", url.path],
        ["sha256sum", url.path],
        ["openssl", "dgst", "-sha256", url.path]
    ]

    for candidate in candidates {
        do {
            let output = try run(command: candidate)
            if let digest = parseDigest(from: output) {
                return digest.lowercased()
            }
        } catch {
            continue
        }
    }

    throw ManifestError.hashingToolUnavailable
}

func run(command: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    if process.terminationStatus == 0 {
        return output
    }

    let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    throw ManifestError.commandFailed(command.joined(separator: " "), errorOutput)
}

func parseDigest(from output: String) -> String? {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = trimmed.split(whereSeparator: \.isWhitespace)
    guard let first = components.first else {
        return nil
    }
    let candidate = String(first)
    if candidate.count == 64, candidate.allSatisfy({ $0.isHexDigit }) {
        return candidate
    }
    if let range = trimmed.range(of: "= ") {
        let digest = String(trimmed[range.upperBound...])
        if digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) {
            return digest
        }
    }
    return nil
}

func dataFromHex(_ hex: String) throws -> Data {
    guard hex.count.isMultiple(of: 2) else {
        throw ManifestError.invalidHexDigest(hex)
    }

    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let nextIndex = hex.index(index, offsetBy: 2)
        let byteString = hex[index..<nextIndex]
        guard let byte = UInt8(byteString, radix: 16) else {
            throw ManifestError.invalidHexDigest(hex)
        }
        data.append(byte)
        index = nextIndex
    }
    return data
}

enum ManifestError: Error {
    case hashingToolUnavailable
    case commandFailed(String, String)
    case invalidHexDigest(String)
}
