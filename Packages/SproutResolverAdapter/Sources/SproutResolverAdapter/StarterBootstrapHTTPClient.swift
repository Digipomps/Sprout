import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum StarterBootstrapHTTPClientError: Error, Equatable, Sendable {
    case invalidEndpoint(String)
    case invalidResponseStatus(Int)
    case invalidIntent(String)
}

public actor StarterBootstrapHTTPClient {
    private let endpoint: URL
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        endpoint: URL,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard let scheme = endpoint.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw StarterBootstrapHTTPClientError.invalidEndpoint(endpoint.absoluteString)
        }
        self.endpoint = endpoint
        self.session = session
        self.now = now
    }

    public func issueIntent(_ requestBody: StarterBootstrapIntentRequest) async throws -> StarterBootstrapIntent {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StarterBootstrapHTTPClientError.invalidIntent("non-HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw StarterBootstrapHTTPClientError.invalidResponseStatus(httpResponse.statusCode)
        }

        let intent = try JSONDecoder().decode(StarterBootstrapIntent.self, from: data)
        guard intent.scaffold_domain == requestBody.scaffold_domain else {
            throw StarterBootstrapHTTPClientError.invalidIntent("scaffold domain mismatch")
        }
        guard intent.purpose == requestBody.purpose else {
            throw StarterBootstrapHTTPClientError.invalidIntent("purpose mismatch")
        }
        guard intent.goal == requestBody.goal else {
            throw StarterBootstrapHTTPClientError.invalidIntent("goal mismatch")
        }
        guard intent.interests.sorted() == requestBody.interests.sorted() else {
            throw StarterBootstrapHTTPClientError.invalidIntent("interests mismatch")
        }
        guard !intent.isExpired(now: now()) else {
            throw StarterBootstrapHTTPClientError.invalidIntent("starter bootstrap intent expired")
        }
        guard try intent.verifySignature() else {
            throw StarterBootstrapHTTPClientError.invalidIntent("starter bootstrap intent signature invalid")
        }
        return intent
    }
}
