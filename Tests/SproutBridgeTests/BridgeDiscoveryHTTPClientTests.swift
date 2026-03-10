import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SproutBridge
import XCTest

final class BridgeDiscoveryHTTPClientTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        DiscoveryURLProtocol.reset()
    }

    override class func tearDown() {
        DiscoveryURLProtocol.reset()
        super.tearDown()
    }

    func testQueryBridgesPostsExplicitPurposeAndInterests() async throws {
        let session = makeSession()
        let expectedDescriptor = BridgeDescriptor(
            descriptor_id: "bd_discovery_0001",
            bridge_endpoint: "wss://staging.haven.digipomps.org/bridgehead/Porthole/CloudBridge",
            scaffold_domain: "staging.haven.digipomps.org",
            owner_pubkey: "QwRr_kCSs-lJlOraFdzCDYqqB7ZY_TlU644O-4vcpd4",
            capability_requirements: ["cap.join", "cap.discover"],
            purpose_constraints: ["bootstrap.join_scaffold"],
            expires_at: "2099-02-26T09:00:00Z",
            signature: SignatureEnvelope(alg: "Ed25519", sig: "AVJkuvlnZ-PIRtuxjvKu5OggmLOoHWvVQhBM2hgG5Ofxn4kjzwLenwHJVpoM7xADXT8hw_EH8XSfIeRfFj3qCA")
        )

        DiscoveryURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/bridges/query")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try Self.bodyData(for: request)
            let query = try JSONDecoder().decode(BridgeDiscoveryQuery.self, from: body)
            XCTAssertEqual(query.scaffold_domain, "staging.haven.digipomps.org")
            XCTAssertEqual(query.purpose, "bootstrap.join_scaffold")
            XCTAssertEqual(query.interests, ["haven.core.bootstrap", "haven.core.bridge"])
            return try Self.response(
                for: BridgeDiscoveryResponse(bridges: [expectedDescriptor]),
                url: try XCTUnwrap(request.url)
            )
        }

        let client = BridgeDiscoveryHTTPClient(
            endpoint: URL(string: "https://staging.haven.digipomps.org/v1/bridges/query")!,
            session: session
        )

        let bridges = try await client.queryBridges(
            BridgeDiscoveryQuery(
                scaffold_domain: "staging.haven.digipomps.org",
                purpose: "bootstrap.join_scaffold",
                interests: ["haven.core.bootstrap", "haven.core.bridge"]
            )
        )

        XCTAssertEqual(bridges, [expectedDescriptor])
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryURLProtocol.self]
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

private final class DiscoveryURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() {
        handler = nil
    }

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
}
