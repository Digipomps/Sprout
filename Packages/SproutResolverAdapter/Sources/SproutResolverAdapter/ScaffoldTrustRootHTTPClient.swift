import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ScaffoldTrustRootHTTPClientError: Error, Equatable, Sendable {
    case invalidEndpoint(String)
    case invalidResponseStatus(Int)
}

public actor ScaffoldTrustRootHTTPClient {
    private let endpoint: URL
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let validator: ScaffoldAdminTrustRootDescriptorValidator

    public init(
        endpoint: URL,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init,
        validator: ScaffoldAdminTrustRootDescriptorValidator = .init()
    ) throws {
        guard let scheme = endpoint.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw ScaffoldTrustRootHTTPClientError.invalidEndpoint(endpoint.absoluteString)
        }
        self.endpoint = endpoint
        self.session = session
        self.now = now
        self.validator = validator
    }

    public func fetch(expectedDomain: String) async throws -> ScaffoldAdminTrustRootDescriptor {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.boundedData(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ScaffoldTrustRootHTTPClientError.invalidResponseStatus(-1)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ScaffoldTrustRootHTTPClientError.invalidResponseStatus(httpResponse.statusCode)
        }

        let descriptor = try JSONDecoder().decode(ScaffoldAdminTrustRootDescriptor.self, from: data)
        try validator.validate(
            descriptor: descriptor,
            context: ScaffoldAdminTrustRootDescriptorValidationContext(expectedDomain: expectedDomain, now: now())
        )
        return descriptor
    }
}
