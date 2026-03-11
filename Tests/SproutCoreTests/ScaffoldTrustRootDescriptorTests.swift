import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SproutCrypto
import SproutResolverAdapter
import XCTest

final class ScaffoldTrustRootDescriptorTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TrustRootURLProtocol.reset()
    }

    override class func tearDown() {
        TrustRootURLProtocol.reset()
        super.tearDown()
    }

    func testValidatorAcceptsSignedDescriptor() throws {
        let descriptor = try ResolverFixtureFactory.makeScaffoldTrustRootDescriptor()

        XCTAssertNoThrow(
            try ScaffoldAdminTrustRootDescriptorValidator().validate(
                descriptor: descriptor,
                context: ScaffoldAdminTrustRootDescriptorValidationContext(
                    expectedDomain: "example.haven.local",
                    now: ISO8601DateFormatter().date(from: "2026-02-26T08:30:00Z")!
                )
            )
        )
    }

    func testHTTPClientFetchesAndValidatesTrustRootDescriptor() async throws {
        let descriptor = try ResolverFixtureFactory.makeScaffoldTrustRootDescriptor(scaffoldDomain: "staging.haven.digipomps.org")
        let session = makeSession()

        TrustRootURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/.well-known/haven-scaffold-admin-trust-root.json")
            return try Self.response(for: descriptor, url: try XCTUnwrap(request.url))
        }

        let client = try ScaffoldTrustRootHTTPClient(
            endpoint: URL(string: "https://staging.haven.digipomps.org/.well-known/haven-scaffold-admin-trust-root.json")!,
            session: session,
            now: { ISO8601DateFormatter().date(from: "2026-02-26T08:30:00Z")! }
        )

        let fetched = try await client.fetch(expectedDomain: "staging.haven.digipomps.org")
        XCTAssertEqual(fetched.descriptor_id, descriptor.descriptor_id)
        XCTAssertEqual(fetched.scaffold_admin_public_key, descriptor.scaffold_admin_public_key)
    }

    func testValidatorRejectsExpiredDescriptor() throws {
        let descriptor = try ResolverFixtureFactory.makeScaffoldTrustRootDescriptor(
            issuedAt: "2026-02-26T08:00:00Z",
            expiresAt: "2026-02-26T08:05:00Z"
        )

        XCTAssertThrowsError(
            try ScaffoldAdminTrustRootDescriptorValidator().validate(
                descriptor: descriptor,
                context: ScaffoldAdminTrustRootDescriptorValidationContext(
                    expectedDomain: "example.haven.local",
                    now: ISO8601DateFormatter().date(from: "2026-02-26T08:06:00Z")!
                )
            )
        ) { error in
            XCTAssertEqual(error as? ScaffoldAdminTrustRootDescriptorValidationError, .expired)
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrustRootURLProtocol.self]
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
}

private final class TrustRootURLProtocol: URLProtocol {
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
