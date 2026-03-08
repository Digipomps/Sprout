import Foundation

struct SPDXDocument: Encodable {
    let spdxVersion = "SPDX-2.3"
    let dataLicense = "CC0-1.0"
    let SPDXID = "SPDXRef-DOCUMENT"
    let name: String
    let documentNamespace: String
    let creationInfo: CreationInfo
    let packages: [SPDXPackage]
}

struct CreationInfo: Encodable {
    let created: String
    let creators: [String]
}

struct SPDXPackage: Encodable {
    let SPDXID: String
    let name: String
    let downloadLocation = "NOASSERTION"
    let filesAnalyzed = false
    let licenseConcluded = "NOASSERTION"
    let licenseDeclared = "NOASSERTION"
    let versionInfo: String?
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("usage: generate_spdx_sbom.swift <Package.swift> <out.json>\n", stderr)
    exit(1)
}

let packageSwiftPath = arguments[1]
let outputPath = arguments[2]
let packageSource = try String(contentsOfFile: packageSwiftPath, encoding: .utf8)

let packageName = firstMatch(
    pattern: #"let\s+package\s*=\s*Package\(\s*name:\s*"([^"]+)""#,
    in: packageSource
) ?? "sprout"

let targetPatterns = [
    #"\.target\(\s*name:\s*"([^"]+)""#,
    #"\.executableTarget\(\s*name:\s*"([^"]+)""#,
    #"\.testTarget\(\s*name:\s*"([^"]+)""#
]

let targetNames = Set(targetPatterns.flatMap { matches(pattern: $0, in: packageSource) }).sorted()
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime]

let packages = targetNames.map { name in
    SPDXPackage(
        SPDXID: "SPDXRef-\(name.replacingOccurrences(of: " ", with: "-"))",
        name: name,
        versionInfo: nil
    )
}

let document = SPDXDocument(
    name: "\(packageName)-sbom",
    documentNamespace: "https://haven.local/sprout/sbom/\(UUID().uuidString)",
    creationInfo: CreationInfo(
        created: formatter.string(from: Date()),
        creators: ["Tool: sprout Scripts/generate_spdx_sbom.swift"]
    ),
    packages: packages
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(document)
try data.write(to: URL(fileURLWithPath: outputPath), options: [.atomic])

func firstMatch(pattern: String, in source: String) -> String? {
    matches(pattern: pattern, in: source).first
}

func matches(pattern: String, in source: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        return []
    }
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    return regex.matches(in: source, options: [], range: range).compactMap { match in
        guard match.numberOfRanges > 1, let capturedRange = Range(match.range(at: 1), in: source) else {
            return nil
        }
        return String(source[capturedRange])
    }
}
