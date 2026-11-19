import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SproutAppSupport
import SproutCore
import SproutCrypto
import SproutResolverAdapter
import XCTest

final class NativePortholeContractPresenterTests: XCTestCase {
    override func tearDown() {
        PresentationStubProtocol.reset()
        super.tearDown()
    }

    func testRequestCarriesContractInBodyAndNothingInURL() throws {
        let descriptor = try makeDescriptor()
        let request = try URLSessionNativePortholeContractPresenter.makeRequest(for: descriptor)

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://bridge.example.haven.local/cell/contract")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONDecoder().decode(NativePortholeContractPresentation.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body, descriptor.contractPresentation)
        let payload = try Base64URL.decode(body.contract_payload_b64url)
        XCTAssertEqual(Hashing.sha256Base64URL(payload), body.contract_sha256_b64url)
    }

    func testRequestRefusesPlainHTTPOutsideLoopbackAndURLsWithQuery() throws {
        var descriptor = try makeDescriptor()
        descriptor.contract_presentation_url = "http://bridge.example.haven.local/cell/contract"
        XCTAssertThrowsError(try URLSessionNativePortholeContractPresenter.makeRequest(for: descriptor)) {
            XCTAssertEqual($0 as? NativePortholeContractPresentationError, .insecureTransport)
        }
        descriptor.contract_presentation_url = "https://bridge.example.haven.local/cell/contract?x=1"
        XCTAssertThrowsError(try URLSessionNativePortholeContractPresenter.makeRequest(for: descriptor)) {
            XCTAssertEqual($0 as? NativePortholeContractPresentationError, .invalidPresentationURL)
        }
        descriptor.contract_presentation_url = "http://127.0.0.1:8080/cell/contract"
        XCTAssertNoThrow(try URLSessionNativePortholeContractPresenter.makeRequest(for: descriptor))
    }

    func testPresenterSucceedsOn2xxAndFailsOnRejectionOrRedirect() async throws {
        let descriptor = try makeDescriptor()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PresentationStubProtocol.self]
        let presenter = URLSessionNativePortholeContractPresenter(sessionConfiguration: configuration)

        PresentationStubProtocol.configure(status: 204)
        try await presenter.present(descriptor)
        let seen = try XCTUnwrap(PresentationStubProtocol.lastRequest)
        XCTAssertEqual(seen.httpMethod, "POST")
        XCTAssertEqual(seen.url?.absoluteString, descriptor.contract_presentation_url)

        for status in [401, 400, 503, 307] {
            PresentationStubProtocol.configure(status: status)
            do {
                try await presenter.present(descriptor)
                XCTFail("status \(status) must fail presentation")
            } catch {
                XCTAssertEqual(error as? NativePortholeContractPresentationError, .rejected(status: status))
            }
        }
    }

    private func makeDescriptor() throws -> NativePortholeBindingDescriptor {
        let seed = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        let publicKey = try Ed25519.publicKeyBase64URL(fromSeedBase64URL: seed)
        var contract = PortholeAccessContract(
            contract_id: "pac_presenter_0001",
            scaffold_domain: "example.haven.local",
            entity_id: "entity_example_primary",
            identity_public_key: "m2J3MyPvQaEYNIJBlOVRZNMl65zcwQ3dp9EK3k-9j20",
            scaffold_admin_public_key: publicKey,
            bridge_descriptor_id: "bd_anchor_0001",
            bridge_endpoint: "wss://bridge.example.haven.local/cell",
            client_kind: .native,
            porthole_protocol: .cellprotocol,
            capability_grants: ["cap.join"],
            purpose: "bootstrap.join_scaffold",
            goal: "Join scaffold",
            interests: [],
            issued_at: "2026-02-26T08:01:00Z",
            expires_at: "2026-02-26T08:06:00Z",
            issued_by: publicKey,
            entity_evidence_contract_id: nil,
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )
        contract.signature = ResolverSignatureEnvelope(
            alg: "Ed25519",
            sig: try Ed25519.signBase64URL(data: try contract.canonicalPayloadData(), seedBase64URL: seed)
        )
        return try PortholeContractConsumer.makeNativeBindingDescriptor(
            contract: contract,
            now: ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")!
        )
    }
}

private final class PresentationStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 204
    nonisolated(unsafe) private static var seen: URLRequest?

    static func configure(status: Int) { lock.withLock { self.status = status; seen = nil } }
    static func reset() { configure(status: 204) }
    static var lastRequest: URLRequest? { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = Self.lock.withLock { () -> Int in Self.seen = request; return Self.status }
        guard let url = request.url else { return }
        if (300..<400).contains(status) {
            let redirect = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://elsewhere.invalid/collect"])!
            #if !canImport(FoundationNetworking)
            // Darwin: offer the redirect so the presenter's NoRedirectDelegate is exercised.
            // swift-corelibs-foundation traps on urlProtocol(_:wasRedirectedTo:)
            // ("doesn't currently handle redirects directly"), so on Linux the
            // stub only returns the 3xx, which must still fail presentation.
            var next = URLRequest(url: URL(string: "https://elsewhere.invalid/collect")!)
            next.httpMethod = "POST"
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
            #endif
            // The presenter's delegate refuses the redirect; finish with the 3xx.
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
