import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SproutResolverAdapter
import XCTest

final class BoundedHTTPResponseTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedTestProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testAcceptsExactlyBoundedChunkedResponse() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.boundedData(
            for: URLRequest(url: URL(string: "https://test.invalid/exact")!), maximumBytes: 32
        )
        XCTAssertEqual(data.count, 32)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testRejectsOversizedDeclaredLengthAndChunkedBody() async throws {
        for path in ["declared", "chunked"] {
            let session = session()
            defer { session.invalidateAndCancel() }
            do {
                _ = try await session.boundedData(
                    for: URLRequest(url: URL(string: "https://test.invalid/\(path)")!), maximumBytes: 32
                )
                XCTFail("Oversized response must fail without returning partial data")
            } catch {
                XCTAssertEqual(error as? BoundedHTTPResponseError, .responseTooLarge)
            }
        }
    }

    func testCancellationStopsAnUnfinishedResponse() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let started = expectation(description: "request started")
        BoundedTestProtocol.started = started
        defer { BoundedTestProtocol.started = nil }
        let task = Task {
            try await session.boundedData(for: URLRequest(url: URL(string: "https://test.invalid/wait")!))
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled response must not succeed") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }

    func testStreamingCollectorRejectsEveryRedirect() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://test.invalid/register")!
        let task = session.dataTask(with: original)
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), any Error>) in
                let collector = BoundedHTTPCollector(maximumBytes: 32, continuation: continuation)
                for destination in ["https://test.invalid/other", "https://other.invalid/capture", "http://test.invalid/insecure"] {
                    let response = HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil,
                                                   headerFields: ["Location": destination])!
                    collector.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                         newRequest: URLRequest(url: URL(string: destination)!)) { request in
                        XCTAssertNil(request)
                    }
                }
                collector.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
            }
            XCTFail("Synthetic cancelled collection must fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
    }
}

private final class BoundedTestProtocol: URLProtocol {
    nonisolated(unsafe) static var started: XCTestExpectation?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/wait" { Self.started?.fulfill(); return }
        let headers = url.path == "/declared" ? ["Content-Length": "100"] : [:]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 16))
        client?.urlProtocol(self, didLoad: Data(repeating: 2, count: 16))
        if url.path != "/exact" { client?.urlProtocol(self, didLoad: Data(repeating: 3, count: 16)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
