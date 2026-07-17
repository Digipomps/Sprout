import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SproutCrypto
import SproutResolverAdapter
import XCTest

final class ScaffoldExecutableCatalogTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        ExecutableCatalogURLProtocol.reset()
    }

    override class func tearDown() {
        ExecutableCatalogURLProtocol.reset()
        super.tearDown()
    }

    func testValidatorAcceptsSignedExecutableCatalogFromTrustedPublisher() throws {
        let catalog = try ResolverFixtureFactory.makeScaffoldExecutableCatalog()

        XCTAssertNoThrow(
            try ScaffoldExecutableCatalogValidator().validate(
                catalog: catalog,
                context: ScaffoldExecutableCatalogValidationContext(
                    expectedDomain: "example.haven.local",
                    trustedPublisherPublicKeys: [try ResolverFixtureFactory.resolverPublicKey()],
                    now: ISO8601DateFormatter().date(from: "2026-02-26T08:30:00Z")!
                )
            )
        )
    }

    func testValidatorRejectsUntrustedPublisherWhenTrustRootKeyIsPinned() throws {
        let catalog = try ResolverFixtureFactory.makeScaffoldExecutableCatalog()

        XCTAssertThrowsError(
            try ScaffoldExecutableCatalogValidator().validate(
                catalog: catalog,
                context: ScaffoldExecutableCatalogValidationContext(
                    expectedDomain: "example.haven.local",
                    trustedPublisherPublicKeys: [try ResolverFixtureFactory.bridgeOwnerPublicKey()],
                    now: ISO8601DateFormatter().date(from: "2026-02-26T08:30:00Z")!
                )
            )
        ) { error in
            XCTAssertEqual(error as? ScaffoldExecutableCatalogValidationError, .issuerNotTrusted(catalog.issued_by))
        }
    }

    func testValidatorRejectsExecutableArtifactWithoutSigningEvidence() throws {
        let artifact = ScaffoldExecutableArtifact(
            artifact_id: "artifact_cellscaffold_linux_0001",
            name: "cellscaffold-linux-x86_64",
            kind: "cellscaffold",
            platform: "linux-x86_64",
            semver: "0.1.0",
            channel: "stable",
            download_url: "https://example.haven.local/downloads/cellscaffold-linux-x86_64",
            sha256_b64url: Hashing.sha256Base64URL(Data("cellscaffold-linux-x86_64".utf8)),
            signing: []
        )
        let catalog = try ResolverFixtureFactory.makeScaffoldExecutableCatalog(artifacts: [artifact])

        XCTAssertThrowsError(
            try ScaffoldExecutableCatalogValidator().validate(
                catalog: catalog,
                context: ScaffoldExecutableCatalogValidationContext(
                    expectedDomain: "example.haven.local",
                    trustedPublisherPublicKeys: [try ResolverFixtureFactory.resolverPublicKey()],
                    now: ISO8601DateFormatter().date(from: "2026-02-26T08:30:00Z")!
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ScaffoldExecutableCatalogValidationError,
                .missingSigning(artifactID: "artifact_cellscaffold_linux_0001")
            )
        }
    }

    func testCatalogSelectsMatchingArtifact() throws {
        let catalog = try ResolverFixtureFactory.makeScaffoldExecutableCatalog()
        let artifact = catalog.selectArtifact(kind: "cellscaffold", platform: "linux-x86_64", channel: "stable")

        XCTAssertEqual(artifact?.name, "cellscaffold-linux-x86_64")
        XCTAssertEqual(artifact?.semver, "0.1.0")
    }

    func testHTTPClientFetchesAndValidatesExecutableCatalog() async throws {
        let catalog = try ResolverFixtureFactory.makeScaffoldExecutableCatalog(scaffoldDomain: "staging.haven.digipomps.org")
        let session = makeSession()

        ExecutableCatalogURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/.well-known/haven-executable-catalog.json")
            return try Self.response(for: catalog, url: try XCTUnwrap(request.url))
        }

        let client = ScaffoldExecutableCatalogHTTPClient(
            endpoint: ScaffoldExecutableCatalogHTTPClient.defaultEndpoint(scaffoldDomain: "staging.haven.digipomps.org"),
            session: session,
            now: { ISO8601DateFormatter().date(from: "2026-02-26T08:30:00Z")! }
        )

        let fetched = try await client.fetch(
            expectedDomain: "staging.haven.digipomps.org",
            trustedPublisherPublicKeys: [try ResolverFixtureFactory.resolverPublicKey()]
        )
        XCTAssertEqual(fetched.catalog_id, catalog.catalog_id)
        XCTAssertEqual(fetched.artifacts.first?.kind, "cellscaffold")
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExecutableCatalogURLProtocol.self]
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

private final class ExecutableCatalogURLProtocol: URLProtocol {
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
