import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SproutResolverAdapter
import XCTest

/// Real sockets are opt-in: Scripts/test_http_transport.py owns the loopback fixture.
/// URLProtocol mocks cannot reproduce FoundationNetworking/libcurl session teardown.
final class BoundedHTTPNetworkTests: XCTestCase {
    func testRepeatedAndConcurrentKeepAliveRequestsDoNotShareResponseStateOrCookies() async throws {
        let base = try HTTPNetworkFixture.baseURL()
        for index in 0..<32 {
            try await HTTPNetworkFixture.checkEcho(base: base, id: "sequential-\(index)")
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    try await HTTPNetworkFixture.checkEcho(base: base, id: "concurrent-\(index)")
                }
            }
            try await group.waitForAll()
        }
    }

    func testRejectsRealRedirectWithoutContactingDestination() async throws {
        let base = try HTTPNetworkFixture.baseURL()
        let token = UUID().uuidString
        let (_, response) = try await HTTPNetworkFixture.fetch(base: base, path: "redirect", token: token)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 307)
        let stats = try await HTTPNetworkFixture.stats(base: base, token: token)
        XCTAssertEqual(stats.captures, 0, "The redirect destination must never receive a request")
        try await HTTPNetworkFixture.checkEcho(base: base, id: "after-redirect")
        // This proves redirect rejection, not a memory cap on Foundation's internal 3xx buffer.
    }

    func testDeclaredAndChunkedOverflowActuallyCancelTheNetworkTransfer() async throws {
        let base = try HTTPNetworkFixture.baseURL()
        for path in ["declared", "chunked"] {
            let token = UUID().uuidString
            do {
                _ = try await HTTPNetworkFixture.fetch(base: base, path: path, token: token, maximumBytes: 32)
                XCTFail("\(path): oversized response returned successfully")
            } catch {
                XCTAssertEqual(error as? BoundedHTTPResponseError, .responseTooLarge, "\(path): \(error)")
            }
            let stats = try await HTTPNetworkFixture.waitForDisconnect(base: base, token: token)
            XCTAssertTrue(stats.disconnected, "\(path): fixture did not observe client disconnect")
            XCTAssertFalse(stats.completed, "\(path): entire oversized response was transmitted")
            XCTAssertLessThan(stats.chunks, 512, "\(path): cancellation did not stop the response promptly")
            try await HTTPNetworkFixture.checkEcho(base: base, id: "after-\(path)")
        }
    }

    func testCancellationStopsActiveRequestAndLeavesNextRequestUsable() async throws {
        let base = try HTTPNetworkFixture.baseURL()
        let token = UUID().uuidString
        let request = Task {
            try await HTTPNetworkFixture.fetch(base: base, path: "slow", token: token)
        }
        do {
            var started = false
            for _ in 0..<60 {
                if try await HTTPNetworkFixture.stats(base: base, token: token).chunks > 0 {
                    started = true
                    break
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(started, "Cancellation must exercise a request that reached the real server")
            request.cancel()
            do {
                _ = try await request.value
                XCTFail("Cancelled response returned successfully")
            } catch {
                XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled,
                              "Expected cancellation, received \(error)")
            }
        } catch {
            request.cancel()
            _ = try? await request.value
            throw error
        }
        let stats = try await HTTPNetworkFixture.waitForDisconnect(base: base, token: token)
        XCTAssertTrue(stats.disconnected, "Cancellation must close the active response")
        XCTAssertFalse(stats.completed)
        try await HTTPNetworkFixture.checkEcho(base: base, id: "after-task-cancellation")
    }
}

private enum HTTPNetworkFixture {
    struct Echo: Decodable {
        let id: String
        let cookie: String
    }

    struct Stats: Decodable {
        let chunks: Int
        let disconnected: Bool
        let completed: Bool
        let captures: Int
    }

    static func baseURL() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["SPROUT_HTTP_TEST_BASE_URL"] else {
            throw XCTSkip("Opt-in network fixture: run Scripts/test_http_transport.py -- <test command>")
        }
        guard let components = URLComponents(string: raw), components.scheme == "http",
              ["127.0.0.1", "::1", "[::1]"].contains(components.host ?? ""),
              let port = components.port, (1...65535).contains(port),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/", let url = components.url else {
            throw NSError(domain: "BoundedHTTPNetworkTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Fixture URL must be a plain HTTP loopback origin"])
        }
        return url
    }

    static func fetch(base: URL, path: String, token: String = "", maximumBytes: Int = 1_048_576)
        async throws -> (Data, URLResponse) {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        var request = URLRequest(url: components.url!, timeoutInterval: 3)
        request.httpMethod = "GET"
        return try await URLSession.shared.boundedData(for: request, maximumBytes: maximumBytes)
    }

    static func checkEcho(base: URL, id: String) async throws {
        let (data, response) = try await fetch(base: base, path: "echo", token: id, maximumBytes: 4096)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let echo = try JSONDecoder().decode(Echo.self, from: data)
        XCTAssertEqual(echo.id, id, "Concurrent tasks must receive their own response")
        XCTAssertEqual(echo.cookie, "", "Set-Cookie from an earlier response must not be replayed")
    }

    static func stats(base: URL, token: String) async throws -> Stats {
        let (data, response) = try await fetch(base: base, path: "stats", token: token, maximumBytes: 4096)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(Stats.self, from: data)
    }

    static func waitForDisconnect(base: URL, token: String) async throws -> Stats {
        var current = try await stats(base: base, token: token)
        for _ in 0..<60 {
            if current.disconnected || current.completed { return current }
            try await Task.sleep(nanoseconds: 20_000_000)
            current = try await stats(base: base, token: token)
        }
        return current
    }
}
