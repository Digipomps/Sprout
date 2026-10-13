import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SproutCore
import SproutCrypto
import SproutResolverAdapter
import SproutStorage
import XCTest

final class OnboardingHTTPServiceTests: XCTestCase {
    func testRealClientCompositionSignsInMemoryAndVerifiesResolvedIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-http-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try ResolverFixtureFactory.makeScaffoldTrustRootDescriptor(expiresAt: "2099-01-01T00:00:00Z")
        let local = try await StarterIdentityStore(root: root.appendingPathComponent("local")).loadOrCreate(scaffoldDomain: OnboardingProfileStore.localRealm)
        var profile = OnboardingProfile(localIdentityPublicKey: local.identity_public_key)
        profile.entityIntent = .existing
        profile.domain = "example.haven.local"
        profile.purpose = "purpose://contact.communication"
        profile.goal = "Test channel"
        profile.interests = ["correspondence"]
        profile.trustedAdminKeys["example.haven.local"] = descriptor.scaffold_admin_public_key
        let handler = OnboardingHTTPFixture(descriptor: descriptor, localPublicKey: local.identity_public_key)
        OnboardingURLProtocol.fixture = handler
        defer { OnboardingURLProtocol.fixture = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnboardingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = OnboardingHTTPService(testSession: session)
        let fetched = try await service.discover(domain: "example.haven.local")
        XCTAssertEqual(fetched, descriptor)
        let outcome = try await service.resolve(profile: profile, descriptor: fetched, identityRoot: root.appendingPathComponent("scaffolds"))
        XCTAssertEqual(outcome, .identityVerified)
        XCTAssertEqual(handler.paths, [
            "/.well-known/haven-scaffold-admin-trust-root.json", "/v1/resolver/starter-auth/intent",
            "/v1/resolver/starter-auth/register", "/v1/resolver/entities/resolve"
        ])
        let files = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String])
        XCTAssertFalse(files.contains { $0.contains("proof") || $0.contains("starter.json") || $0.contains("transcript") })
        XCTAssertEqual(files.filter { $0.hasSuffix("identity.json") }.count, 2)
    }

    @MainActor
    func testExpiredDiscoveryStopsBeforeIdentityDisclosureAndPreservesLocalStateOnResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-expired-discovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try ResolverFixtureFactory.makeScaffoldTrustRootDescriptor(expiresAt: "2000-01-01T00:00:00Z")
        let handler = OnboardingHTTPFixture(descriptor: descriptor, localPublicKey: "not-disclosed")
        OnboardingURLProtocol.fixture = handler
        defer { OnboardingURLProtocol.fixture = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnboardingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = OnboardingHTTPService(testSession: session)
        var originalSeed: Data?
        for input in [["ja", "ny", "", "", "", "example.haven.local", "ja", "ja"], ["ja", "ja", "ja"]] {
            var answers = input
            let dialogue = OnboardingDialogue(root: root, service: service, ask: { _ in
                answers.isEmpty ? nil : answers.removeFirst()
            }, say: { _ in })
            do {
                try await dialogue.run()
                XCTFail("Expired trust must stop the real client composition")
            } catch {
                XCTAssertEqual(error as? OnboardingError, .trustDescriptorExpired)
            }
            XCTAssertTrue(answers.isEmpty)
            let profile = try JSONDecoder().decode(OnboardingProfile.self, from: PrivateStateFiles.read(root.appendingPathComponent("onboarding.json")))
            XCTAssertTrue(profile.trustedAdminKeys.isEmpty)
            XCTAssertEqual(profile.lastOutcome, .localOnly)
            XCTAssertFalse(PrivateStateFiles.exists(root.appendingPathComponent("scaffold-identities")))
            let seed = try PrivateStateFiles.read(root.appendingPathComponent("identities/local.sprout.invalid/keys/ed25519.seed"))
            if let originalSeed { XCTAssertEqual(seed, originalSeed) }
            else { originalSeed = seed }
        }
        XCTAssertEqual(handler.paths, Array(repeating: "/.well-known/haven-scaffold-admin-trust-root.json", count: 2))
    }

    func testForgedDiscoveryIsStillRejectedAsInvalidSignature() async throws {
        for expiry in ["2099-01-01T00:00:00Z", "2000-01-01T00:00:00Z", "invalid"] {
            var descriptor = try ResolverFixtureFactory.makeScaffoldTrustRootDescriptor(expiresAt: expiry)
            descriptor.signature.sig = Base64URL.encode(Data(repeating: 0, count: 64))
            try await assertRejectedDiscovery(descriptor, expected: .signatureInvalid)
        }
    }

    func testSignedMalformedExpiryIsNotReportedAsExpiredTrust() async throws {
        let descriptor = try ResolverFixtureFactory.makeScaffoldTrustRootDescriptor(expiresAt: "invalid")
        try await assertRejectedDiscovery(descriptor, expected: .invalidExpiry)
    }

    private func assertRejectedDiscovery(_ descriptor: ScaffoldAdminTrustRootDescriptor,
                                         expected: ScaffoldAdminTrustRootDescriptorValidationError) async throws {
        let handler = OnboardingHTTPFixture(descriptor: descriptor, localPublicKey: "not-disclosed")
        OnboardingURLProtocol.fixture = handler
        defer { OnboardingURLProtocol.fixture = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnboardingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await OnboardingHTTPService(testSession: session).discover(domain: "example.haven.local")
            XCTFail("Must reject invalid metadata")
        } catch {
            XCTAssertEqual(error as? ScaffoldAdminTrustRootDescriptorValidationError, expected)
        }
        XCTAssertEqual(handler.paths, ["/.well-known/haven-scaffold-admin-trust-root.json"])
    }

    func testRedirectDelegateAlwaysRejectsRedirectIncludingSameOrigin() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://example.haven.local/v1/resolver/starter-auth/register")!
        let task = session.dataTask(with: original)
        let delegate = NoOnboardingRedirects()
        for target in ["https://evil.test/capture", "https://example.haven.local/other", "http://example.haven.local/insecure"] {
            let response = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: ["Location": target]))
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                newRequest: URLRequest(url: URL(string: target)!)) { request in
                XCTAssertNil(request)
            }
        }
    }
}

private final class OnboardingHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var seenPaths: [String] = []
    private var registeredKey: String?
    private let descriptor: ScaffoldAdminTrustRootDescriptor
    private let localPublicKey: String
    var paths: [String] { lock.withLock { seenPaths } }

    init(descriptor: ScaffoldAdminTrustRootDescriptor, localPublicKey: String) {
        self.descriptor = descriptor
        self.localPublicKey = localPublicKey
    }

    func response(_ request: URLRequest) throws -> Data {
        try lock.withLock {
            let path = try XCTUnwrap(request.url?.path)
            seenPaths.append(path)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            switch path {
            case "/.well-known/haven-scaffold-admin-trust-root.json":
                XCTAssertEqual(request.httpMethod, "GET")
                return try JSONEncoder().encode(descriptor)
            case "/v1/resolver/starter-auth/intent":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try JSONDecoder().decode(StarterBootstrapIntentRequest.self, from: body(request))
                XCTAssertEqual(body.goal, "Test channel")
                XCTAssertEqual(body.purpose, "purpose://contact.communication")
                var intent = StarterBootstrapIntent(
                    version: "1.0", scaffold_domain: body.scaffold_domain, purpose: body.purpose,
                    goal: body.goal, interests: body.interests, runtime: body.runtime,
                    created_at: "2026-01-01T00:00:00Z", expires_at: "2099-01-01T00:00:00Z",
                    nonce: "single-use-test-challenge", issued_by: descriptor.resolver_public_keys[0],
                    signature: .init(alg: "Ed25519", sig: "")
                )
                intent.signature.sig = try Ed25519.signBase64URL(data: intent.canonicalPayloadData(), seedBase64URL: ResolverFixtureFactory.resolverSeed)
                return try JSONEncoder().encode(intent)
            case "/v1/resolver/starter-auth/register":
                let payload = try JSONDecoder().decode(StarterAuthPayload.self, from: body(request))
                XCTAssertTrue(try payload.verifySignature())
                XCTAssertNotEqual(payload.identity_public_key, localPublicKey)
                XCTAssertEqual(payload.nonce, "single-use-test-challenge")
                registeredKey = payload.identity_public_key
                return try JSONEncoder().encode(ResolverRegistrationResult(accepted: true, registration_id: "test-registration", reason: nil))
            case "/v1/resolver/entities/resolve":
                let body = try JSONDecoder().decode(EntityResolutionRequest.self, from: body(request))
                XCTAssertEqual(body.identity_public_key, registeredKey)
                XCTAssertNil(body.evidence)
                var proof = EntityInclusionProof(
                    proof_id: "test-proof", scaffold_domain: body.domain, entity_id: "test-entity",
                    subject_identity_public_key: body.identity_public_key, subject_domain: body.domain,
                    anchor_snapshot_id: "test-anchor", anchor_snapshot_sha256_b64url: "test-hash",
                    anchor_admin_public_key: descriptor.scaffold_admin_public_key,
                    issued_at: "2026-01-01T00:00:00Z", expires_at: "2099-01-01T00:00:00Z",
                    issued_by: descriptor.resolver_public_keys[0], signature: .init(alg: "Ed25519", sig: "")
                )
                proof.signature.sig = try Ed25519.signBase64URL(data: proof.canonicalPayloadData(), seedBase64URL: ResolverFixtureFactory.resolverSeed)
                return try JSONEncoder().encode(EntityResolutionDecision(status: .resolved, entity_id: "test-entity", inclusion_proof: proof))
            default: throw OnboardingError.invalidInput
            }
        }
    }

    private func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw OnboardingError.invalidInput }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

private final class OnboardingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var fixture: OnboardingHTTPFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try XCTUnwrap(Self.fixture).response(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
