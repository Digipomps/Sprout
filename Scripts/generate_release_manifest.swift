import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

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
        sha256_b64url: base64url(Data(SHA256.hash(data: data)))
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
