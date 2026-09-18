import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SproutCrypto
import SproutResolverAdapter
import SproutStorage

public protocol OnboardingService: Sendable {
    func discover(domain: String) async throws -> ScaffoldAdminTrustRootDescriptor
    func resolve(profile: OnboardingProfile, descriptor: ScaffoldAdminTrustRootDescriptor,
                 identityRoot: URL) async throws -> OnboardingOutcome
}

public enum OnboardingTrust {
    public static func validate(_ descriptor: ScaffoldAdminTrustRootDescriptor, domain: String,
                                pinnedKey: String?, now: Date = Date()) throws {
        try ScaffoldAdminTrustRootDescriptorValidator().validate(
            descriptor: descriptor,
            context: .init(expectedDomain: domain, now: now)
        )
        guard descriptor.version == "1.0",
              let issued = ISO8601DateFormatter().date(from: descriptor.issued_at), issued <= now else {
            throw OnboardingError.invalidProof
        }
        if let pinnedKey, pinnedKey != descriptor.scaffold_admin_public_key {
            throw OnboardingError.trustChanged
        }
        _ = try endpoint(descriptor.starter_bootstrap_url, domain: domain)
        let resolver = try endpoint(descriptor.resolver_base_url, domain: domain)
        guard resolver.path.isEmpty || resolver.path == "/" else { throw OnboardingError.unsafeEndpoint }
    }

    public static func endpoint(_ value: String, domain: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https", url.host?.lowercased() == domain,
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw OnboardingError.unsafeEndpoint }
        return url
    }

    public static func validateResolution(_ decision: EntityResolutionDecision, domain: String,
                                          publicKey: String, descriptor: ScaffoldAdminTrustRootDescriptor,
                                          now: Date = Date()) throws -> OnboardingOutcome {
        guard decision.status == .resolved else { return .awaitingApproval }
        guard let entity = decision.entity_id, !entity.isEmpty, let proof = decision.inclusion_proof,
              proof.entity_id == entity, proof.scaffold_domain == domain, proof.subject_domain == domain,
              proof.subject_identity_public_key == publicKey,
              proof.anchor_admin_public_key == descriptor.scaffold_admin_public_key,
              proof.evidence_contract_id == nil, decision.evidence_contract_id == nil,
              descriptor.trustsResolver(proof.issued_by),
              decision.resolved_by == nil || decision.resolved_by == proof.issued_by,
              let issued = ISO8601DateFormatter().date(from: proof.issued_at), issued <= now,
              !proof.isExpired(now: now), try proof.verifySignature() else {
            throw OnboardingError.invalidProof
        }
        return .identityVerified
    }
}

final class NoOnboardingRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Uses deployed API contracts, not the mock resolver or file-based CLI bootstrap defaults.
public actor OnboardingHTTPService: OnboardingService {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoOnboardingRedirects(), delegateQueue: nil)
    }

    init(testSession: URLSession) { session = testSession }

    deinit { session.invalidateAndCancel() }

    public func discover(domain: String) async throws -> ScaffoldAdminTrustRootDescriptor {
        let canonicalDomain = try StarterIdentityStore.validateDomain(domain)
        let url = try OnboardingTrust.endpoint(
            "https://\(canonicalDomain)/.well-known/haven-scaffold-admin-trust-root.json", domain: canonicalDomain
        )
        return try await ScaffoldTrustRootHTTPClient(endpoint: url, session: session).fetch(expectedDomain: canonicalDomain)
    }

    public func resolve(profile: OnboardingProfile, descriptor: ScaffoldAdminTrustRootDescriptor,
                        identityRoot: URL) async throws -> OnboardingOutcome {
        try profile.validate()
        guard let domain = profile.domain, let purpose = profile.purpose, let goal = profile.goal,
              let interests = profile.interests, let pin = profile.trustedAdminKeys[domain] else {
            throw OnboardingError.invalidInput
        }
        try OnboardingTrust.validate(descriptor, domain: domain, pinnedKey: pin)
        let endpoint = try OnboardingTrust.endpoint(descriptor.starter_bootstrap_url, domain: domain)
        let client = try StarterBootstrapHTTPClient(endpoint: endpoint, session: session)
        let intent = try await client.issueIntent(.init(
            scaffold_domain: domain, purpose: purpose, goal: goal, interests: interests, runtime: "cli-service"
        ))
        guard descriptor.trustsResolver(intent.issued_by), intent.version == "1.0", !intent.nonce.isEmpty,
              intent.runtime == "cli-service",
              let created = ISO8601DateFormatter().date(from: intent.created_at), created <= Date() else {
            throw OnboardingError.invalidProof
        }
        // The local draft key never leaves this machine. Each scaffold gets a separate key.
        let store = StarterIdentityStore(root: identityRoot)
        let identity = try await store.loadOrCreate(scaffoldDomain: domain)
        var payload = StarterAuthPayload(
            version: "1.0", domain: domain, identity_public_key: identity.identity_public_key,
            created_at: intent.created_at, expires_at: intent.expires_at, nonce: intent.nonce,
            purpose_interest: .init(purpose: purpose, interests: interests),
            signature: .init(alg: "Ed25519", sig: "")
        )
        payload.signature.sig = try Ed25519.signBase64URL(
            data: payload.canonicalPayloadData(), seedBase64URL: await store.seedBase64URL(scaffoldDomain: domain)
        )
        let resolver = try HavenResolverHTTPAdapter(configuration: .init(
            baseURL: OnboardingTrust.endpoint(descriptor.resolver_base_url, domain: domain),
            trustedResolverPublicKeys: Set(descriptor.resolver_public_keys)
        ), session: session)
        let registration = try await resolver.registerStarterAuth(payload: payload)
        guard registration.accepted else { throw OnboardingError.invalidProof }
        let resolution = try await resolver.resolveEntity(.init(
            identity_public_key: identity.identity_public_key, domain: domain,
            scaffold_admin_public_key: descriptor.scaffold_admin_public_key,
            purpose: purpose, goal: goal, interests: interests, evidence: nil
        ))
        return try OnboardingTrust.validateResolution(
            resolution, domain: domain, publicKey: identity.identity_public_key, descriptor: descriptor
        )
    }
}
