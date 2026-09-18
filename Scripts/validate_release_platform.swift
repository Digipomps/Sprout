import Foundation

enum ArtifactFailure: Error { case invalidArguments, wrongPlatform, invalidHeader, dynamicLinuxBinary }

func number(_ data: Data, offset: Int, bytes: Int) throws -> UInt64 {
    guard offset >= 0, bytes <= 8, offset <= data.count - bytes else { throw ArtifactFailure.invalidHeader }
    return (0..<bytes).reduce(UInt64(0)) { $0 | (UInt64(data[offset + $1]) << (8 * $1)) }
}

func validate(_ path: String, platform: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    guard data.count >= 64 else { throw ArtifactFailure.invalidHeader }
    if platform.hasPrefix("macos-") {
        guard try number(data, offset: 0, bytes: 4) == 0xfeedfacf else { throw ArtifactFailure.wrongPlatform }
        let expected: UInt64 = platform == "macos-arm64" ? 0x0100000c : 0x01000007
        guard try number(data, offset: 4, bytes: 4) == expected else { throw ArtifactFailure.wrongPlatform }
        return
    }
    guard Array(data.prefix(6)) == [0x7f, 0x45, 0x4c, 0x46, 2, 1] else { throw ArtifactFailure.wrongPlatform }
    let expected: UInt64 = platform == "linux-x86_64" ? 62 : 183
    guard try number(data, offset: 18, bytes: 2) == expected else { throw ArtifactFailure.wrongPlatform }
    let kind = try number(data, offset: 16, bytes: 2)
    guard kind == 2 || kind == 3 else { throw ArtifactFailure.invalidHeader }
    let headerOffset = try number(data, offset: 32, bytes: 8)
    let headerSize = try number(data, offset: 54, bytes: 2)
    let count = try number(data, offset: 56, bytes: 2)
    guard count > 0, headerSize >= 56, headerOffset <= data.count,
          count * headerSize <= UInt64(data.count) - headerOffset else { throw ArtifactFailure.invalidHeader }
    for index in 0..<count {
        let offset = Int(headerOffset + index * headerSize)
        let type = try number(data, offset: offset, bytes: 4)
        if type == 3 { throw ArtifactFailure.dynamicLinuxBinary } // PT_INTERP requires a host loader.
        if type == 2 {
            let start = try number(data, offset: offset + 8, bytes: 8)
            let length = try number(data, offset: offset + 32, bytes: 8)
            guard start <= data.count, length <= UInt64(data.count) - start,
                  length % 16 == 0 else { throw ArtifactFailure.invalidHeader }
            for entry in stride(from: Int(start), to: Int(start + length), by: 16) {
                let tag = try number(data, offset: entry, bytes: 8)
                if tag == 0 { break }
                if tag == 1 { throw ArtifactFailure.dynamicLinuxBinary } // DT_NEEDED
            }
        }
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2,
          ["macos-arm64", "macos-x86_64", "linux-x86_64", "linux-aarch64"].contains(arguments[0]) else {
        throw ArtifactFailure.invalidArguments
    }
    for path in arguments.dropFirst() { try validate(path, platform: arguments[0]) }
    print("Platform verified: \(arguments[0]); Linux artifacts must be fully static.")
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("Artifact platform verification failed: \(error)\n".utf8))
    exit(1)
}
