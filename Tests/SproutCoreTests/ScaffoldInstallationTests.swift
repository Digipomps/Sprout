import Foundation
import SproutCore
import SproutCrypto
import SproutResolverAdapter
import SproutStorage
import XCTest

/// These tests execute installation against an observable fake image runtime.
/// They prove selection, verification and receipt behavior, not a real Docker pull.
final class ScaffoldInstallationTests: XCTestCase {
    private let domain = "install.example.test"
    private let purpose = "purpose://scaffold.operations"
    private let secondaryPurpose = "purpose://test.acceptance"
    private let platform = "linux-x86_64"
    private var now: Date { ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z")! }

    func testSignedV11RoundTripSelectsExactPurposeAndRetainsInstallationContract() throws {
        let wanted = try artifact("web", purposes: [purpose])
        let similar = try artifact("other", purposes: [purpose + ".other"])
        let signed = try catalog([similar, wanted])
        let decoded = try JSONDecoder().decode(ScaffoldExecutableCatalog.self, from: JSONEncoder().encode(signed))
        XCTAssertTrue(try decoded.verifySignature())
        XCTAssertEqual(decoded.artifacts, [similar, wanted])
        let result = try plan(decoded)
        XCTAssertEqual(result.artifacts.map(\.artifact_id), ["web"])
        XCTAssertEqual(result.purposes, [purpose])
        XCTAssertEqual(result.publisher, try ResolverFixtureFactory.resolverPublicKey())
        XCTAssertEqual(result.catalog_sha256_b64url, Hashing.sha256Base64URL(try signed.canonicalPayloadData()))
    }

    func testMultiplePurposesResolveDeterministicDependencyOrderAndDeduplicateSharedImages() throws {
        let base = try artifact("base")
        let middle = try artifact("middle", dependencies: ["base"])
        let web = try artifact("web", purposes: [purpose], dependencies: ["middle", "base"])
        let tester = try artifact("tester", purposes: [secondaryPurpose], dependencies: ["base"])
        let result = try plan(catalog([tester, web, middle, base]), purposes: [secondaryPurpose, purpose, purpose])
        XCTAssertEqual(result.purposes, [purpose, secondaryPurpose].sorted())
        XCTAssertEqual(result.artifacts.map(\.artifact_id), ["base", "middle", "web", "tester"])
    }

    func testUnknownPurposeFailsWithoutChoosingSimilarDescription() throws {
        let signed = try catalog([artifact("web", purposes: [purpose])])
        assertPlanError(.purposeUnavailable(purpose + ".unknown"), signed, purposes: [purpose + ".unknown"])
        assertPlanError(.invalidPurpose, signed, purposes: ["run a scaffold for me"])
        assertPlanError(.invalidPurpose, signed, purposes: [])
    }

    func testAmbiguousPurposeRequiresAnExplicitCatalogDecision() throws {
        assertPlanError(.ambiguousPurpose(purpose), try catalog([
            artifact("one", purposes: [purpose]), artifact("two", purposes: [purpose])
        ]))
    }

    func testDependencyCycleIsRejectedBeforeAnInstallationCanBegin() throws {
        assertPlanError(.dependencyCycle, try catalog([
            artifact("web", purposes: [purpose], dependencies: ["base"]),
            artifact("base", dependencies: ["web"])
        ]))
    }

    func testMissingDependencyIsReportedByItsArtifactID() throws {
        assertPlanError(.missingDependency("absent"), try catalog([
            artifact("web", purposes: [purpose], dependencies: ["absent"])
        ]))
    }

    func testWrongPlatformOrChannelCannotSatisfyPurposeOrDependency() throws {
        var wrong = try artifact("wrong", purposes: [purpose])
        wrong.platform = "linux-arm64"
        wrong.installation?.container_platform = "linux/arm64"
        assertPlanError(.purposeUnavailable(purpose), try catalog([wrong]))
        var beta = try artifact("beta", purposes: [purpose])
        beta.channel = "beta"
        assertPlanError(.purposeUnavailable(purpose), try catalog([beta]))
        assertPlanError(.unsupportedArtifact("wrong"), try catalog([
            artifact("web", purposes: [purpose], dependencies: ["wrong"]), wrong
        ]))
    }

    func testContainerArchitectureMustMatchDeclaredArtifactArchitecture() throws {
        var mismatch = try artifact("web", purposes: [purpose])
        mismatch.installation?.container_platform = "linux/arm64"
        assertPlanError(.unsupportedArtifact("web"), try catalog([mismatch]))
    }

    func testAValidSignatureDoesNotReplaceTheRequiredPublisherPin() throws {
        let signed = try catalog([artifact("web", purposes: [purpose])])
        XCTAssertThrowsError(try ScaffoldInstallationPlan.make(catalog: signed, domain: domain,
            publisherKeys: [], purposes: [purpose], platform: platform, now: now)) {
            XCTAssertEqual($0 as? ScaffoldInstallationError, .publisherPinRequired)
        }
        XCTAssertThrowsError(try ScaffoldInstallationPlan.make(catalog: signed, domain: domain,
            publisherKeys: [ResolverFixtureFactory.bridgeOwnerPublicKey()], purposes: [purpose], platform: platform, now: now)) {
            XCTAssertEqual($0 as? ScaffoldExecutableCatalogValidationError, .issuerNotTrusted(signed.issued_by))
        }
    }

    func testTamperingWithPurposeDependencyOrInstallMetadataBreaksTheSignature() throws {
        let signed = try catalog([artifact("web", purposes: [purpose])])
        var mutations: [ScaffoldExecutableCatalog] = []
        var modified = signed; modified.artifacts[0].purpose_ids = [secondaryPurpose]; mutations.append(modified)
        modified = signed; modified.artifacts[0].dependencies = ["injected"]; mutations.append(modified)
        modified = signed; modified.artifacts[0].installation?.image += "0"; mutations.append(modified)
        modified = signed; modified.artifacts[0].installation?.container_platform = "linux/arm64"; mutations.append(modified)
        for candidate in mutations {
            XCTAssertThrowsError(try plan(candidate)) {
                XCTAssertEqual($0 as? ScaffoldExecutableCatalogValidationError, .signatureInvalid)
            }
        }
    }

    func testSignedHashAndOCIManifestURLMustBindTheSameImageDigest() throws {
        var wrongHash = try artifact("web", purposes: [purpose])
        wrongHash.sha256_b64url = Hashing.sha256Base64URL(Data("different artifact".utf8))
        assertPlanError(.unsupportedArtifact("web"), try catalog([wrongHash]))
        var wrongURL = try artifact("web", purposes: [purpose])
        wrongURL.download_url = wrongURL.download_url.replacingOccurrences(of: "registry.example.test", with: "another.example.test")
        assertPlanError(.unsupportedArtifact("web"), try catalog([wrongURL]))
        var mutableTag = try artifact("web", purposes: [purpose])
        mutableTag.installation?.image = "registry.example.test/haven/web:latest"
        assertPlanError(.unsupportedArtifact("web"), try catalog([mutableTag]))
    }

    func testRegistryAddressCannotBeInterpretedAsADockerHubNamespace() throws {
        for registry in ["registry", "index.docker.io"] {
            var ambiguous = try artifact("web", purposes: [purpose])
            let image = ambiguous.installation!.image
            ambiguous.installation?.image = image.replacingOccurrences(of: "registry.example.test", with: registry)
            ambiguous.download_url = ambiguous.download_url.replacingOccurrences(of: "registry.example.test", with: registry)
            assertPlanError(.unsupportedArtifact("web"), try catalog([ambiguous]))
        }
        var missingLibrary = try artifact("web", purposes: [purpose])
        let digest = missingLibrary.installation!.image.split(separator: "@")[1]
        missingLibrary.installation?.image = "docker.io/ubuntu@" + digest
        missingLibrary.download_url = "https://docker.io/v2/ubuntu/manifests/" + digest
        assertPlanError(.unsupportedArtifact("web"), try catalog([missingLibrary]))
    }

    func testArtifactRequiresSupportedInstallationFormatAndPublisherBoundSigning() throws {
        var wrong = try artifact("web", purposes: [purpose])
        wrong.installation?.format = "shell-script"
        assertPlanError(.unsupportedArtifact("web"), try catalog([wrong]))
        wrong = try artifact("web", purposes: [purpose]); wrong.installation = nil
        assertPlanError(.unsupportedArtifact("web"), try catalog([wrong]))
        wrong = try artifact("web", purposes: [purpose])
        wrong.signing = [.init(type: "catalog-ed25519", identity: try ResolverFixtureFactory.bridgeOwnerPublicKey())]
        assertPlanError(.unsupportedArtifact("web"), try catalog([wrong]))
    }

    func testLegacyFutureExpiredAndDuplicateIDCatalogsCannotBeInstalled() throws {
        let web = try artifact("web", purposes: [purpose])
        var modified = try catalog([web]); modified.version = "1.0"
        assertPlanError(.invalidCatalog, try sign(modified))
        modified = try catalog([web]); modified.issued_at = "2027-01-01T00:00:00Z"
        assertPlanError(.invalidCatalog, try sign(modified))
        modified = try catalog([web]); modified.expires_at = "2026-10-13T11:59:59Z"
        XCTAssertThrowsError(try plan(sign(modified))) {
            XCTAssertEqual($0 as? ScaffoldExecutableCatalogValidationError, .expired)
        }
        assertPlanError(.invalidCatalog, try catalog([web, web]))
    }

    func testInstallerPullsExactDependencyDigestsAndPublishesPrivateReceipts() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RecordingScaffoldRuntime()
        let base = try artifact("base")
        let web = try artifact("web", purposes: [purpose], dependencies: ["base"])
        let signed = try catalog([web, base])
        let installer = ScaffoldInstaller(root: root, runtime: runtime)
        let receipts = try await install(installer, signed)
        let calls = await runtime.pulls
        XCTAssertEqual(calls, [try pull(base), try pull(web)])
        XCTAssertEqual(receipts.map(\.artifact_id), ["base", "web"])
        XCTAssertEqual(receipts.map(\.status), ["installed-not-started", "installed-not-started"])
        XCTAssertEqual(receipts.map(\.purposes), [[purpose], [purpose]])
        let files = try receiptFiles(root)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(try permissions(root), 0o700)
        XCTAssertEqual(try permissions(file), 0o600)
        let record = try JSONSerialization.jsonObject(with: PrivateStateFiles.read(file)) as? [String: Any]
        XCTAssertEqual((record?["receipts"] as? [Any])?.count, 2)
        let storedCatalog = try JSONDecoder().decode(ScaffoldExecutableCatalog.self,
            from: JSONSerialization.data(withJSONObject: try XCTUnwrap(record?["catalog"])))
        XCTAssertTrue(try storedCatalog.verifySignature())
        XCTAssertEqual(storedCatalog, signed)
        let inspected = try await installer.inspect()
        XCTAssertEqual(inspected, receipts)
    }

    func testFailedDependencyPullPublishesNoPartialReceiptAndCanResume() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RecordingScaffoldRuntime()
        let base = try artifact("base")
        let web = try artifact("web", purposes: [purpose], dependencies: ["base"])
        let signed = try catalog([web, base])
        let installer = ScaffoldInstaller(root: root, runtime: runtime)
        await runtime.failPull(of: try XCTUnwrap(web.installation).image)
        do { _ = try await install(installer, signed); XCTFail("A failed pull must not produce a successful installation") }
        catch { XCTAssertEqual(error as? ScaffoldInstallationError, .dockerFailed(42)) }
        XCTAssertEqual(try receiptFiles(root).count, 0)
        let pulledImages = await runtime.images
        XCTAssertTrue(pulledImages.contains(try XCTUnwrap(base.installation).image), "Downloaded dependencies remain available for retry")
        await runtime.failPull(of: nil)
        let receipts = try await install(installer, signed)
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(try receiptFiles(root).count, 1)
        let inspected = try await installer.inspect()
        XCTAssertEqual(inspected.map(\.status), ["installed-not-started", "installed-not-started"])
    }

    func testFailedReplacementPreservesTheEntirePreviouslyCommittedReceipt() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RecordingScaffoldRuntime()
        let installer = ScaffoldInstaller(root: root, runtime: runtime)
        let initial = try catalog([artifact("web-v1", purposes: [purpose])])
        _ = try await install(installer, initial)
        let receiptFile = try XCTUnwrap(receiptFiles(root).first)
        let previous = try Data(contentsOf: receiptFile)
        let next = try artifact("web-v2", purposes: [purpose], dependencies: ["base-v2"])
        let replacement = try catalog([next, artifact("base-v2")])
        await runtime.failPull(of: try XCTUnwrap(next.installation).image)
        do { _ = try await install(installer, replacement); XCTFail("Replacement should fail") }
        catch { XCTAssertEqual(error as? ScaffoldInstallationError, .dockerFailed(42)) }
        XCTAssertEqual(try Data(contentsOf: receiptFile), previous)
        XCTAssertEqual(try receiptFiles(root), [receiptFile])
        let inspected = try await installer.inspect()
        XCTAssertEqual(inspected.map(\.artifact_id), ["web-v1"])
    }

    func testSuccessfulPullWithoutTheRequestedInstalledDigestCannotPublishReceipt() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RecordingScaffoldRuntime()
        await runtime.setRetainPulledImages(false)
        do {
            _ = try await install(ScaffoldInstaller(root: root, runtime: runtime), catalog([artifact("web", purposes: [purpose])]))
            XCTFail("A pull exit code cannot replace installed digest verification")
        } catch { XCTAssertEqual(error as? ScaffoldInstallationError, .digestNotInstalled) }
        XCTAssertEqual(try receiptFiles(root).count, 0)
    }

    func testInstallerRevalidatesSignedCatalogBeforeAnyPullOrStateCreation() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RecordingScaffoldRuntime()
        var tampered = try catalog([artifact("web", purposes: [purpose])])
        tampered.artifacts[0].name = "forged"
        do { _ = try await install(ScaffoldInstaller(root: root, runtime: runtime), tampered); XCTFail("Tampered catalog must fail") }
        catch { XCTAssertEqual(error as? ScaffoldExecutableCatalogValidationError, .signatureInvalid) }
        let calls = await runtime.pulls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testReinstallUsesOneReceiptAndStatusDetectsMissingImage() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RecordingScaffoldRuntime()
        let web = try artifact("web", purposes: [purpose])
        let signed = try catalog([web])
        let installer = ScaffoldInstaller(root: root, runtime: runtime)
        _ = try await install(installer, signed)
        _ = try await install(installer, signed)
        XCTAssertEqual(try receiptFiles(root).count, 1)
        let installed = try await installer.inspect()
        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(installed.first?.status, "installed-not-started")
        await runtime.remove(image: try XCTUnwrap(web.installation).image)
        let missing = try await installer.inspect()
        XCTAssertEqual(missing.first?.status, "missing-image")
        let calls = await runtime.pulls
        XCTAssertEqual(calls.count, 2, "Inspection must not silently reinstall")
    }

    func testInspectionRejectsTamperedImageAndSignedCatalog() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RecordingScaffoldRuntime()
        let installer = ScaffoldInstaller(root: root, runtime: runtime)
        _ = try await install(installer, catalog([artifact("web", purposes: [purpose])]))
        let file = try XCTUnwrap(receiptFiles(root).first)
        let original = try Data(contentsOf: file)
        try editRecord(file) { record in
            var receipts = record["receipts"] as! [[String: Any]]
            receipts[0]["image"] = "registry.example.test/haven/forged@sha256:" + String(repeating: "a", count: 64)
            record["receipts"] = receipts
        }
        do { _ = try await installer.inspect(); XCTFail("Altered receipt image must fail") }
        catch { XCTAssertEqual(error as? ScaffoldInstallationError, .receiptMismatch) }
        try PrivateStateFiles.write(original, to: file)
        try editRecord(file) { record in
            var signed = record["catalog"] as! [String: Any]
            signed["catalog_id"] = "forged"
            record["catalog"] = signed
        }
        do { _ = try await installer.inspect(); XCTFail("Altered catalog must fail") }
        catch { XCTAssertEqual(error as? ScaffoldInstallationError, .receiptMismatch) }
    }

    func testInspectionRejectsReceiptPurposeAndPlatformThatDisagreeWithSignedArtifact() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RecordingScaffoldRuntime()
        let installer = ScaffoldInstaller(root: root, runtime: runtime)
        _ = try await install(installer, catalog([artifact("web", purposes: [purpose])]))
        let file = try XCTUnwrap(receiptFiles(root).first)
        let original = try Data(contentsOf: file)
        for field in ["purposes", "platform"] {
            try PrivateStateFiles.write(original, to: file)
            try editRecord(file) { record in
                var receipts = record["receipts"] as! [[String: Any]]
                if field == "purposes" { receipts[0][field] = [secondaryPurpose] }
                else { receipts[0][field] = "linux/arm64" }
                record["receipts"] = receipts
            }
            do { _ = try await installer.inspect(); XCTFail("Forged \(field) must not be presented as installed") }
            catch { XCTAssertEqual(error as? ScaffoldInstallationError, .receiptMismatch) }
        }
    }

    func testInstallationRefusesConcurrentWriterBeforePull() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RecordingScaffoldRuntime()
        let lock = try PrivateStateLock(directory: root)
        defer { withExtendedLifetime(lock) {} }
        do {
            _ = try await install(ScaffoldInstaller(root: root, runtime: runtime), catalog([artifact("web", purposes: [purpose])]))
            XCTFail("Concurrent installer must not pull or replace receipts")
        } catch { XCTAssertEqual(error as? PrivateStateError, .busy) }
        let calls = await runtime.pulls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(try receiptFiles(root).count, 0)
    }

    func testSignedServiceProfileSurvivesRoundTripAndAuthorizesExactImage() throws {
        var web = try artifact("web", purposes: [purpose, secondaryPurpose])
        web.installation?.service_profile = "cellscaffold-web-v1"
        let signed = try catalog([web])
        let decoded = try JSONDecoder().decode(ScaffoldExecutableCatalog.self, from: JSONEncoder().encode(signed))
        XCTAssertTrue(try decoded.verifySignature())
        let request = try ScaffoldServiceRequest.make(plan: plan(decoded, purposes: [purpose, secondaryPurpose]),
            instance: "acceptance", port: 9089, publicOrigin: "https://staging.example.test:8443")
        XCTAssertEqual(request.image, web.installation?.image)
        XCTAssertEqual(request.platform, "linux/amd64")
        XCTAssertEqual(request.profile, "cellscaffold-web-v1")
        XCTAssertEqual(request.root, "/var/lib/haven-sprout")
        XCTAssertEqual(try ScaffoldServiceRequest.status(instance: "test").root, request.root)
        XCTAssertEqual(request.public_origin, "https://staging.example.test:8443")
        XCTAssertEqual(try JSONDecoder().decode(ScaffoldServiceRequest.self, from: JSONEncoder().encode(request)), request)
        var modified = signed
        modified.artifacts[0].installation?.service_profile = "arbitrary-code"
        XCTAssertFalse(try modified.verifySignature(), "The activation profile must be covered by the catalog signature")
    }

    func testServiceRefusesUnsignedLegacyAndUnknownProfiles() throws {
        var web = try artifact("web", purposes: [purpose])
        for profile: String? in [nil, "arbitrary-code"] {
            web.installation?.service_profile = profile
            XCTAssertThrowsError(try ScaffoldServiceRequest.make(plan: plan(catalog([web])),
                instance: "acceptance", port: 9089, publicOrigin: "https://service.example.test")) {
                XCTAssertEqual($0 as? ScaffoldServiceError, .missingServiceProfile)
            }
        }
    }

    func testServiceDoesNotSilentlyDropAnotherRequestedPurpose() throws {
        var web = try artifact("web", purposes: [purpose])
        web.installation?.service_profile = "cellscaffold-web-v1"
        let other = try artifact("other", purposes: [secondaryPurpose])
        XCTAssertThrowsError(try ScaffoldServiceRequest.make(plan: plan(catalog([web, other]), purposes: [purpose, secondaryPurpose]),
            instance: "acceptance", port: 9089, publicOrigin: "https://service.example.test")) {
            XCTAssertEqual($0 as? ScaffoldServiceError, .missingServiceProfile)
        }
    }

    func testServiceRequiresSeparateInstancesForIndependentServices() throws {
        var web = try artifact("web", purposes: [purpose])
        var other = try artifact("other", purposes: [secondaryPurpose])
        web.installation?.service_profile = "cellscaffold-web-v1"
        other.installation?.service_profile = "cellscaffold-web-v1"
        XCTAssertThrowsError(try ScaffoldServiceRequest.make(plan: plan(catalog([web, other]), purposes: [purpose, secondaryPurpose]),
            instance: "acceptance", port: 9089, publicOrigin: "https://service.example.test")) {
            XCTAssertEqual($0 as? ScaffoldServiceError, .multipleServices)
        }
    }

    func testServiceRejectsUnsafeOriginAndInstanceBeforeAnyHostWork() throws {
        for origin in ["http://service.example.test", "https://user:pass@service.example.test", "https://service.example.test/path",
                       "https://service.example.test/", "https://service.example.test?x=1", "https://service.example.test#x",
                       "https://service.example.test:443", "https://service.example.test:0", "https://service.example.test:65536", "https://localhost", "https://127.0.0.1"] {
            XCTAssertFalse(ScaffoldServiceRequest.validOrigin(origin), origin)
        }
        XCTAssertTrue(ScaffoldServiceRequest.validOrigin("https://service.example.test"))
        XCTAssertTrue(ScaffoldServiceRequest.validOrigin("https://service.example.test:8443"))
        for name in ["../escape", "/tmp/escape", "-flag", "UPPER", "trailing-", String(repeating: "a", count: 41)] {
            XCTAssertThrowsError(try ScaffoldServiceRequest.status(instance: name), name)
        }
        let request = try ScaffoldServiceRequest.status(instance: "acceptance-1")
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertNil(record["image"])
        XCTAssertNil(record["public_origin"])
        XCTAssertEqual(record["operation"] as? String, "status")
    }

    private func artifact(_ id: String, purposes: [String] = [], dependencies: [String] = []) throws -> ScaffoldExecutableArtifact {
        let digest = Hashing.sha256(Data(id.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return ScaffoldExecutableArtifact(artifact_id: id, name: id, kind: "cellscaffold", platform: platform,
            semver: "1.0.0", channel: "stable",
            download_url: "https://registry.example.test/v2/haven/\(id)/manifests/sha256:\(hex)",
            sha256_b64url: Base64URL.encode(digest),
            signing: [.init(type: "catalog-ed25519", identity: try ResolverFixtureFactory.resolverPublicKey())],
            purpose_ids: purposes, dependencies: dependencies,
            installation: .init(image: "registry.example.test/haven/\(id)@sha256:\(hex)"))
    }

    private func catalog(_ artifacts: [ScaffoldExecutableArtifact]) throws -> ScaffoldExecutableCatalog {
        try sign(.init(version: "1.1", catalog_id: "test-installation-catalog", scaffold_domain: domain,
            issued_at: "2020-01-01T00:00:00Z", expires_at: "2099-01-01T00:00:00Z",
            issued_by: ResolverFixtureFactory.resolverPublicKey(), artifacts: artifacts,
            signature: .init(alg: "Ed25519", sig: "")))
    }

    private func sign(_ unsigned: ScaffoldExecutableCatalog) throws -> ScaffoldExecutableCatalog {
        var result = unsigned
        result.signature = .init(alg: "Ed25519", sig: try Ed25519.signBase64URL(
            data: unsigned.canonicalPayloadData(), seedBase64URL: ResolverFixtureFactory.resolverSeed))
        return result
    }

    private func plan(_ catalog: ScaffoldExecutableCatalog, purposes: [String]? = nil) throws -> ScaffoldInstallationPlan {
        try .make(catalog: catalog, domain: domain, publisherKeys: [ResolverFixtureFactory.resolverPublicKey()],
                  purposes: purposes ?? [purpose], platform: platform, now: now)
    }

    private func assertPlanError(_ expected: ScaffoldInstallationError, _ catalog: ScaffoldExecutableCatalog,
                                 purposes: [String]? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try plan(catalog, purposes: purposes), file: file, line: line) {
            XCTAssertEqual($0 as? ScaffoldInstallationError, expected, file: file, line: line)
        }
    }

    private func install(_ installer: ScaffoldInstaller, _ catalog: ScaffoldExecutableCatalog) async throws -> [ScaffoldInstallationReceipt] {
        try await installer.install(catalog: catalog, domain: domain,
            publisherKeys: [ResolverFixtureFactory.resolverPublicKey()], purposes: [purpose], platform: platform)
    }

    private func pull(_ artifact: ScaffoldExecutableArtifact) throws -> RecordingScaffoldRuntime.Pull {
        let spec = try XCTUnwrap(artifact.installation)
        return .init(image: spec.image, platform: spec.container_platform)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sprout-install-tests-\(UUID().uuidString)")
    }

    private func receiptFiles(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private func editRecord(_ url: URL, change: (inout [String: Any]) throws -> Void) throws {
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: PrivateStateFiles.read(url)) as? [String: Any])
        try change(&record)
        try PrivateStateFiles.write(JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), to: url)
    }
}

private actor RecordingScaffoldRuntime: ScaffoldImageRuntime {
    struct Pull: Equatable, Sendable {
        let image: String
        let platform: String
    }
    private(set) var pulls: [Pull] = []
    private(set) var images = Set<String>()
    private var failingImage: String?
    private var retainPulledImages = true

    func failPull(of image: String?) { failingImage = image }
    func setRetainPulledImages(_ enabled: Bool) { retainPulledImages = enabled }
    func remove(image: String) { images.remove(image) }

    func pull(image: String, platform: String) async throws {
        pulls.append(.init(image: image, platform: platform))
        if image == failingImage { throw ScaffoldInstallationError.dockerFailed(42) }
        if retainPulledImages { images.insert(image) }
    }

    func contains(image: String, platform: String) async throws -> Bool { images.contains(image) }
}
