import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SproutBridge
import SproutCrypto
import SproutResolverAdapter
@testable import SproutCore
import XCTest

final class HavenResolverHTTPAdapterTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        ResolverURLProtocol.reset()
    }

    override class func tearDown() {
        ResolverURLProtocol.reset()
        super.tearDown()
    }

    func testRejectsHTTPResolverWithoutExplicitAllowFlag() {
        XCTAssertThrowsError(
            try HavenResolverHTTPAdapter(
                configuration: HavenResolverHTTPAdapterConfiguration(
                    baseURL: URL(string: "http://resolver.example.haven.local")!
                )
            )
        )
    }

    func testResolveEntityRejectsUntrustedResolverIssuer() async throws {
        let session = makeSession()
        let trustedKey = try Ed25519.publicKeyBase64URL(fromSeedBase64URL: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        let untrustedSeed = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"
        let proof = try makeInclusionProof(seed: untrustedSeed)
        let decision = EntityResolutionDecision(
            status: .resolved,
            entity_id: proof.entity_id,
            inclusion_proof: proof,
            resolved_by: proof.issued_by,
            resolved_at: "2026-02-26T08:01:10Z",
            evidence_contract_id: nil
        )

        ResolverURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/resolver/entities/resolve")
            return try Self.response(for: decision, url: try XCTUnwrap(request.url))
        }

        let adapter = try HavenResolverHTTPAdapter(
            configuration: HavenResolverHTTPAdapterConfiguration(
                baseURL: URL(string: "https://resolver.example.haven.local")!,
                trustedResolverPublicKeys: [trustedKey]
            ),
            session: session,
            now: { ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")! }
        )

        await XCTAssertThrowsErrorAsync(
            try await adapter.resolveEntity(
                EntityResolutionRequest(
                    identity_public_key: proof.subject_identity_public_key,
                    domain: proof.subject_domain,
                    scaffold_admin_public_key: proof.anchor_admin_public_key,
                    purpose: "bootstrap.join_scaffold",
                    goal: "Join scaffold and register identity",
                    interests: ["haven.core.bootstrap"],
                    evidence: nil
                )
            )
        )
    }

    func testBootstrapHappyPathWithLiveHTTPResolver() async throws {
        let starter = try loadStarterPayload()
        let descriptor = try ResolverFixtureFactory.makeSignedBridgeDescriptor()
        let session = makeSession()
        let resolverKey = try Ed25519.publicKeyBase64URL(fromSeedBase64URL: ResolverFixtureFactory.resolverSeed)
        let inclusionProof = try makeInclusionProof(seed: ResolverFixtureFactory.resolverSeed)
        let portholeContract = try ResolverFixtureFactory.makePortholeAccessContract(clientKind: .web, protocolKind: .web)

        ResolverURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            switch url.path {
            case "/v1/resolver/starter-auth/register":
                let payload = try JSONDecoder().decode(StarterAuthPayload.self, from: try Self.bodyData(for: request))
                XCTAssertEqual(payload.purpose_interest.purpose, "bootstrap.join_scaffold")
                return try Self.response(
                    for: ResolverRegistrationResult(accepted: true, registration_id: "reg_live_0001", reason: nil),
                    url: url
                )
            case "/v1/resolver/entities/resolve":
                let resolveRequest = try JSONDecoder().decode(EntityResolutionRequest.self, from: try Self.bodyData(for: request))
                XCTAssertEqual(resolveRequest.purpose, "bootstrap.join_scaffold")
                XCTAssertEqual(resolveRequest.goal, "Join scaffold and register identity")
                return try Self.response(
                    for: EntityResolutionDecision(
                        status: .resolved,
                        entity_id: inclusionProof.entity_id,
                        inclusion_proof: inclusionProof,
                        resolved_by: inclusionProof.issued_by,
                        resolved_at: "2026-02-26T08:01:10Z",
                        evidence_contract_id: nil
                    ),
                    url: url
                )
            case "/v1/resolver/capabilities/request":
                let capabilityRequest = try JSONDecoder().decode(CapabilityRequest.self, from: try Self.bodyData(for: request))
                XCTAssertEqual(capabilityRequest.purpose, "bootstrap.join_scaffold")
                return try Self.response(
                    for: CapabilityDecision(granted: ["cap.join", "cap.discover"], denied: []),
                    url: url
                )
            case "/v1/resolver/membership/checks":
                let membershipRequest = try JSONDecoder().decode(MembershipCheckRequest.self, from: try Self.bodyData(for: request))
                XCTAssertEqual(membershipRequest.domain, "example.haven.local")
                return try Self.response(for: MembershipDecision(allowed: true), url: url)
            case "/v1/resolver/portholes/access":
                let accessRequest = try JSONDecoder().decode(PortholeAccessRequest.self, from: try Self.bodyData(for: request))
                XCTAssertEqual(accessRequest.client_kind, .web)
                XCTAssertEqual(accessRequest.porthole_protocol, .web)
                return try Self.response(
                    for: PortholeAccessDecision(allowed: true, contract: portholeContract),
                    url: url
                )
            default:
                XCTFail("Unexpected resolver path: \(url.path)")
                return try Self.response(for: MembershipDecision(allowed: false, reason: "unexpected path"), url: url, status: 404)
            }
        }

        let adapter = try HavenResolverHTTPAdapter(
            configuration: HavenResolverHTTPAdapterConfiguration(
                baseURL: URL(string: "https://resolver.example.haven.local")!,
                trustedResolverPublicKeys: [resolverKey]
            ),
            session: session,
            now: { ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")! }
        )

        let dependencies = SproutBootstrapDependencies(
            identityProvider: { context in
                let payload = try XCTUnwrap(context.starterAuthPayload)
                return BootstrapIdentity(domain: payload.domain, identity_public_key: payload.identity_public_key)
            },
            entityEvidenceProvider: { _ in nil },
            environmentProbe: { _ in
                BootstrapEnvironmentReport(discovery_modes: ["offline-catalog", "live-resolver-http"], available_transports: ["https", "wss"])
            },
            bridgeDiscovery: { _ in [descriptor] },
            scaffoldAdminIdentityProvider: { descriptor, _ in
                ScaffoldAdminIdentity(
                    scaffold_domain: descriptor.scaffold_domain,
                    admin_public_key: descriptor.owner_pubkey,
                    source_descriptor_id: descriptor.descriptor_id,
                    trust_origin: "bridge_descriptor_signature"
                )
            },
            bridgeConnector: { _, _ in },
            resolver: adapter,
            persistence: { _ in }
        )

        let machine = SproutBootstrapStateMachine(
            dependencies: dependencies,
            now: { ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")! }
        )
        let result = await machine.run(
            initialContext: BootstrapExecutionContext(
                runtime: .cliService,
                domain: "example.haven.local",
                requestedPortholeKind: .web,
                purposeGoal: BootstrapPurposeGoal(
                    purpose: "bootstrap.join_scaffold",
                    goal: "Join scaffold and register identity",
                    interests: ["haven.core.bootstrap", "haven.core.bridge"]
                ),
                starterAuthPayload: starter
            )
        )

        XCTAssertEqual(result.finalState, .done)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.context.entityResolution?.inclusion_proof?.proof_id, inclusionProof.proof_id)
        XCTAssertEqual(result.context.portholeAccessContract?.contract_id, portholeContract.contract_id)
    }

    private static func response<T: Encodable>(for body: T, url: URL, status: Int = 200) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (response, try JSONEncoder().encode(body))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResolverURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func bodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        if let stream = request.httpBodyStream {
            return try readBodyData(from: stream)
        }
        return Data()
    }

    private static func readBodyData(from stream: InputStream) throws -> Data {
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeContentData)
            }
            if read == 0 {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }

    private func loadStarterPayload() throws -> StarterAuthPayload {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try JSONDecoder().decode(
            StarterAuthPayload.self,
            from: Data(contentsOf: rootURL.appendingPathComponent("TestVectors/starter_auth_payload.signed.json"))
        )
    }

    private func makeInclusionProof(seed: String) throws -> EntityInclusionProof {
        let publicKey = try Ed25519.publicKeyBase64URL(fromSeedBase64URL: seed)
        var proof = EntityInclusionProof(
            proof_id: "eip_live_0001",
            scaffold_domain: "example.haven.local",
            entity_id: "entity_example_primary",
            subject_identity_public_key: "m2J3MyPvQaEYNIJBlOVRZNMl65zcwQ3dp9EK3k-9j20",
            subject_domain: "example.haven.local",
            anchor_snapshot_id: "anchor_live_0001",
            anchor_snapshot_sha256_b64url: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            anchor_admin_public_key: publicKey,
            evidence_contract_id: nil,
            issued_at: "2026-02-26T08:01:00Z",
            expires_at: "2026-02-26T08:06:00Z",
            issued_by: publicKey,
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )
        proof.signature = ResolverSignatureEnvelope(
            alg: "Ed25519",
            sig: try Ed25519.signBase64URL(data: try proof.canonicalPayloadData(), seedBase64URL: seed)
        )
        return proof
    }
}

final class ResolverURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        handler = nil
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        XCTAssertTrue(true, file: file, line: line)
    }
}
