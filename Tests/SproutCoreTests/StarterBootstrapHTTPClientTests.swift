import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SproutResolverAdapter
import SproutCrypto
import XCTest

final class StarterBootstrapHTTPClientTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        ResolverURLProtocol.reset()
    }

    override class func tearDown() {
        ResolverURLProtocol.reset()
        super.tearDown()
    }

    func testIssueIntentPostsExplicitPurposeGoalAndInterests() async throws {
        let seed = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        let publicKey = try Ed25519.publicKeyBase64URL(fromSeedBase64URL: seed)
        let session = makeSession()

        ResolverURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/resolver/starter-auth/intent")
            let body = try Self.bodyData(for: request)
            let decoded = try JSONDecoder().decode(StarterBootstrapIntentRequest.self, from: body)
            XCTAssertEqual(decoded.scaffold_domain, "staging.haven.digipomps.org")
            XCTAssertEqual(decoded.purpose, "bootstrap.join_scaffold")
            XCTAssertEqual(decoded.goal, "Connect to scaffold and request CLI help")
            XCTAssertEqual(decoded.interests, ["haven.core.bootstrap", "haven.core.bridge"])

            var intent = StarterBootstrapIntent(
                version: "1.0",
                scaffold_domain: decoded.scaffold_domain,
                purpose: decoded.purpose,
                goal: decoded.goal,
                interests: decoded.interests,
                runtime: decoded.runtime,
                created_at: "2026-03-10T21:10:00Z",
                expires_at: "2026-03-10T21:15:00Z",
                nonce: "8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PA",
                issued_by: publicKey,
                signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
            )
            intent.signature = ResolverSignatureEnvelope(
                alg: "Ed25519",
                sig: try Ed25519.signBase64URL(data: intent.canonicalPayloadData(), seedBase64URL: seed)
            )
            return try Self.response(for: intent, url: try XCTUnwrap(request.url))
        }

        let client = try StarterBootstrapHTTPClient(
            endpoint: URL(string: "https://staging.haven.digipomps.org/v1/resolver/starter-auth/intent")!,
            session: session,
            now: { ISO8601DateFormatter().date(from: "2026-03-10T21:10:01Z")! }
        )

        let intent = try await client.issueIntent(
            StarterBootstrapIntentRequest(
                scaffold_domain: "staging.haven.digipomps.org",
                purpose: "bootstrap.join_scaffold",
                goal: "Connect to scaffold and request CLI help",
                interests: ["haven.core.bootstrap", "haven.core.bridge"],
                runtime: "cliService"
            )
        )

        XCTAssertEqual(intent.issued_by, publicKey)
        XCTAssertTrue(try intent.verifySignature())
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResolverURLProtocol.self]
        return URLSession(configuration: configuration)
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
}
