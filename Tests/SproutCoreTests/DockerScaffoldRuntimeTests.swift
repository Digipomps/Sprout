import Foundation
import XCTest
@testable import SproutCore

final class DockerScaffoldRuntimeTests: XCTestCase {
    private let image = "registry.example/scaffold@sha256:" + String(repeating: "a", count: 64)

    func testRealProcessAdapterChecksDigestAndArchitecture() async throws {
        let executable = try script("printf '%s\\n' '{\"digests\":[\"\(image)\"],\"os\":\"linux\",\"architecture\":\"amd64\"}'")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runtime = try DockerScaffoldRuntime(executable: executable)
        let matches = try await runtime.contains(image: image, platform: "linux/amd64")
        let wrongPlatform = try await runtime.contains(image: image, platform: "linux/arm64")
        let wrongDigest = try await runtime.contains(image: image + "b", platform: "linux/amd64")
        XCTAssertTrue(matches)
        XCTAssertFalse(wrongPlatform)
        XCTAssertFalse(wrongDigest)
    }

    func testMissingImageIsFalseButDaemonFailureIsNotMisreportedAsMissing() async throws {
        let executable = try script("printf '%s\\n' 'Error response from daemon: No such image: \(image)' >&2\nexit 1")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runtime = try DockerScaffoldRuntime(executable: executable)
        let exists = try await runtime.contains(image: image, platform: "linux/amd64")
        XCTAssertFalse(exists)
        try Data("#!/bin/sh\nprintf '%s\\n' 'Cannot connect to the Docker daemon' >&2\nexit 1\n".utf8).write(to: executable)
        do {
            _ = try await runtime.contains(image: image, platform: "linux/amd64")
            XCTFail("Daemon failure must stay an error")
        } catch {
            XCTAssertEqual(error as? ScaffoldInstallationError, .dockerFailed(1))
        }
    }

    func testDockerHubFamiliarNamesPreserveFullRepositoryAndDigest() async throws {
        let digest = "@sha256:" + String(repeating: "a", count: 64)
        let executable = try script("printf '%s\\n' '{\"digests\":[\"ubuntu\(digest)\",\"myorg/scaffold\(digest)\"],\"os\":\"linux\",\"architecture\":\"amd64\"}'")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runtime = try DockerScaffoldRuntime(executable: executable)
        let official = try await runtime.contains(image: "docker.io/library/ubuntu" + digest, platform: "linux/amd64")
        let organization = try await runtime.contains(image: "docker.io/myorg/scaffold" + digest, platform: "linux/amd64")
        let otherRegistry = try await runtime.contains(image: "registry.example/myorg/scaffold" + digest, platform: "linux/amd64")
        let otherRepository = try await runtime.contains(image: "docker.io/otherorg/scaffold" + digest, platform: "linux/amd64")
        XCTAssertTrue(official)
        XCTAssertTrue(organization)
        XCTAssertFalse(otherRegistry)
        XCTAssertFalse(otherRepository)
    }

    func testServicePullAndInspectionUseTheSameExplicitLocalDaemon() async throws {
        let executable = try script("""
        [ "$1" = '--host' ] && [ "$2" = 'unix:///var/run/docker.sock' ] || exit 42
        [ -z "${DOCKER_CONTEXT+x}" ] && [ -z "${DOCKER_HOST+x}" ] && [ -z "${DOCKER_TLS_VERIFY+x}" ] || exit 43
        if [ -n "${SPROUT_EXPECTED_DOCKER_CONFIG:-}" ]; then [ "${DOCKER_CONFIG:-}" = "$SPROUT_EXPECTED_DOCKER_CONFIG" ] || exit 44; fi
        shift 2
        if [ "$1" = 'pull' ]; then exit 0; fi
        printf '%s\\n' '{"digests":["\(image)"],"os":"linux","architecture":"amd64"}'
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runtime = try DockerScaffoldRuntime(executable: executable, localDaemon: true)
        try await runtime.pull(image: image, platform: "linux/amd64")
        let present = try await runtime.contains(image: image, platform: "linux/amd64")
        XCTAssertTrue(present)
    }

    private func script(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("docker-fixture")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}
