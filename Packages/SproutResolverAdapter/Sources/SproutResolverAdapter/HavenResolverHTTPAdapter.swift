import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SproutCrypto

public enum HavenResolverHTTPAdapterError: Error, Equatable, Sendable {
    case invalidBaseURL(String)
    case insecureBaseURLNotAllowed
    case invalidResponseStatus(Int)
    case missingTrustedResolverKey(String)
    case invalidResolverResponse(String)
}

public struct HavenResolverHTTPAdapterConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var pathPrefix: String
    public var bearerToken: String?
    public var additionalHeaders: [String: String]
    public var allowInsecureHTTP: Bool
    public var trustedResolverPublicKeys: Set<String>

    public init(
        baseURL: URL,
        pathPrefix: String = "/v1/resolver",
        bearerToken: String? = nil,
        additionalHeaders: [String: String] = [:],
        allowInsecureHTTP: Bool = false,
        trustedResolverPublicKeys: Set<String> = []
    ) {
        self.baseURL = baseURL
        self.pathPrefix = pathPrefix
        self.bearerToken = bearerToken
        self.additionalHeaders = additionalHeaders
        self.allowInsecureHTTP = allowInsecureHTTP
        self.trustedResolverPublicKeys = trustedResolverPublicKeys
    }
}

public struct MembershipCheckRequest: Codable, Equatable, Sendable {
    public var identity_public_key: String
    public var domain: String

    public init(identity_public_key: String, domain: String) {
        self.identity_public_key = identity_public_key
        self.domain = domain
    }
}

public actor HavenResolverHTTPAdapter: SproutResolverAdapter {
    private let configuration: HavenResolverHTTPAdapterConfiguration
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        configuration: HavenResolverHTTPAdapterConfiguration,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard let scheme = configuration.baseURL.scheme?.lowercased(), !scheme.isEmpty else {
            throw HavenResolverHTTPAdapterError.invalidBaseURL("missing URL scheme")
        }
        switch scheme {
        case "https":
            break
        case "http":
            guard configuration.allowInsecureHTTP else {
                throw HavenResolverHTTPAdapterError.insecureBaseURLNotAllowed
            }
        default:
            throw HavenResolverHTTPAdapterError.invalidBaseURL("unsupported scheme \(scheme)")
        }

        self.configuration = configuration
        self.session = session
        self.now = now
    }

    public func registerStarterAuth(payload: StarterAuthPayload) async throws -> ResolverRegistrationResult {
        try await postJSON(path: "starter-auth/register", body: payload)
    }

    public func requestCapabilities(_ request: CapabilityRequest) async throws -> CapabilityDecision {
        try await postJSON(path: "capabilities/request", body: request)
    }

    public func resolveEntity(_ request: EntityResolutionRequest) async throws -> EntityResolutionDecision {
        let decision: EntityResolutionDecision = try await postJSON(path: "entities/resolve", body: request)
        if decision.status == .resolved {
            guard let proof = decision.inclusion_proof else {
                throw HavenResolverHTTPAdapterError.invalidResolverResponse("resolved decision missing inclusion proof")
            }
            try validateTrustedResolverKey(proof.issued_by)
            guard try proof.verifySignature() else {
                throw HavenResolverHTTPAdapterError.invalidResolverResponse("entity inclusion proof signature invalid")
            }
            guard !proof.isExpired(now: now()) else {
                throw HavenResolverHTTPAdapterError.invalidResolverResponse("entity inclusion proof expired")
            }
            if let resolvedBy = decision.resolved_by, resolvedBy != proof.issued_by {
                throw HavenResolverHTTPAdapterError.invalidResolverResponse("resolved_by does not match inclusion proof issuer")
            }
        }
        return decision
    }

    public func performMembershipChecks(identityPublicKey: String, domain: String) async throws -> MembershipDecision {
        try await postJSON(
            path: "membership/checks",
            body: MembershipCheckRequest(identity_public_key: identityPublicKey, domain: domain)
        )
    }

    public func issuePortholeAccessContract(_ request: PortholeAccessRequest) async throws -> PortholeAccessDecision {
        let decision: PortholeAccessDecision = try await postJSON(path: "portholes/access", body: request)
        if decision.allowed {
            guard let contract = decision.contract else {
                throw HavenResolverHTTPAdapterError.invalidResolverResponse("allowed porthole decision missing contract")
            }
            try validateTrustedResolverKey(contract.issued_by)
            guard try contract.verifySignature() else {
                throw HavenResolverHTTPAdapterError.invalidResolverResponse("porthole access contract signature invalid")
            }
            guard !contract.isExpired(now: now()) else {
                throw HavenResolverHTTPAdapterError.invalidResolverResponse("porthole access contract expired")
            }
        }
        return decision
    }

    private func validateTrustedResolverKey(_ issuedBy: String) throws {
        if !configuration.trustedResolverPublicKeys.isEmpty,
           !configuration.trustedResolverPublicKeys.contains(issuedBy) {
            throw HavenResolverHTTPAdapterError.missingTrustedResolverKey(issuedBy)
        }
    }

    private func postJSON<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request
    ) async throws -> Response {
        let requestURL = try makeURL(path: path)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken = configuration.bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        for (header, value) in configuration.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.boundedData(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HavenResolverHTTPAdapterError.invalidResolverResponse("non-HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HavenResolverHTTPAdapterError.invalidResponseStatus(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func makeURL(path: String) throws -> URL {
        var url = configuration.baseURL
        let normalizedPrefix = configuration.pathPrefix
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        let normalizedPath = path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        for component in normalizedPrefix + normalizedPath {
            url.appendPathComponent(component)
        }
        return url
    }
}
