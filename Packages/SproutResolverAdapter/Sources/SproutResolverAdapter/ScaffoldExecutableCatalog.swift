import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SproutCrypto

public enum ScaffoldExecutableCatalogValidationError: Error, Equatable, Sendable {
    case wrongDomain(expected: String, got: String)
    case expired
    case unsupportedSignatureAlgorithm(String)
    case signatureInvalid
    case issuerNotTrusted(String)
    case missingArtifacts
    case invalidURL(String)
    case invalidHash(String)
    case invalidSizeBytes(artifactID: String)
    case missingSigning(artifactID: String)
    case invalidSigning(artifactID: String)
}

public enum ScaffoldExecutableCatalogHTTPClientError: Error, Equatable, Sendable {
    case nonHTTPResponse
    case statusCode(Int)
}

public struct ScaffoldExecutableCatalogValidationContext: Equatable, Sendable {
    public var expectedDomain: String
    public var trustedPublisherPublicKeys: [String]
    public var now: Date

    public init(
        expectedDomain: String,
        trustedPublisherPublicKeys: [String] = [],
        now: Date = Date()
    ) {
        self.expectedDomain = expectedDomain
        self.trustedPublisherPublicKeys = trustedPublisherPublicKeys
        self.now = now
    }
}

public struct ScaffoldExecutableSigning: Codable, Equatable, Sendable {
    public var type: String
    public var url: String?
    public var certificate_url: String?
    public var identity: String?

    public init(
        type: String,
        url: String? = nil,
        certificate_url: String? = nil,
        identity: String? = nil
    ) {
        self.type = type
        self.url = url
        self.certificate_url = certificate_url
        self.identity = identity
    }
}

public struct ScaffoldExecutableArtifact: Codable, Equatable, Sendable {
    public var artifact_id: String
    public var name: String
    public var kind: String
    public var platform: String
    public var semver: String
    public var channel: String
    public var download_url: String
    public var sha256_b64url: String
    public var size_bytes: Int?
    public var release_manifest_url: String?
    public var checksum_url: String?
    public var sbom_url: String?
    public var provenance_url: String?
    public var signing: [ScaffoldExecutableSigning]

    public init(
        artifact_id: String,
        name: String,
        kind: String,
        platform: String,
        semver: String,
        channel: String,
        download_url: String,
        sha256_b64url: String,
        size_bytes: Int? = nil,
        release_manifest_url: String? = nil,
        checksum_url: String? = nil,
        sbom_url: String? = nil,
        provenance_url: String? = nil,
        signing: [ScaffoldExecutableSigning]
    ) {
        self.artifact_id = artifact_id
        self.name = name
        self.kind = kind
        self.platform = platform
        self.semver = semver
        self.channel = channel
        self.download_url = download_url
        self.sha256_b64url = sha256_b64url
        self.size_bytes = size_bytes
        self.release_manifest_url = release_manifest_url
        self.checksum_url = checksum_url
        self.sbom_url = sbom_url
        self.provenance_url = provenance_url
        self.signing = signing
    }
}

public struct ScaffoldExecutableCatalog: Codable, Equatable, Sendable {
    public var version: String
    public var catalog_id: String
    public var scaffold_domain: String
    public var issued_at: String
    public var expires_at: String
    public var issued_by: String
    public var artifacts: [ScaffoldExecutableArtifact]
    public var signature: ResolverSignatureEnvelope

    public init(
        version: String,
        catalog_id: String,
        scaffold_domain: String,
        issued_at: String,
        expires_at: String,
        issued_by: String,
        artifacts: [ScaffoldExecutableArtifact],
        signature: ResolverSignatureEnvelope
    ) {
        self.version = version
        self.catalog_id = catalog_id
        self.scaffold_domain = scaffold_domain
        self.issued_at = issued_at
        self.expires_at = expires_at
        self.issued_by = issued_by
        self.artifacts = artifacts
        self.signature = signature
    }

    public func canonicalPayloadData() throws -> Data {
        let encoded = try JSONEncoder.sorted.encode(self)
        return try JCSCanonicalizer.canonicalizeRemovingTopLevelKeys(encoded, keys: ["signature"])
    }

    public func verifySignature() throws -> Bool {
        guard signature.alg == "Ed25519" else {
            return false
        }
        return Ed25519.verifyBase64URL(
            data: try canonicalPayloadData(),
            signatureBase64URL: signature.sig,
            publicKeyBase64URL: issued_by
        )
    }

    public func isExpired(now: Date = Date()) -> Bool {
        let formatter = ISO8601DateFormatter()
        guard let expiry = formatter.date(from: expires_at) else {
            return true
        }
        return now >= expiry
    }

    public func selectArtifact(
        kind: String,
        platform: String,
        channel: String,
        name: String? = nil
    ) -> ScaffoldExecutableArtifact? {
        artifacts.first { artifact in
            artifact.kind == kind &&
                artifact.platform == platform &&
                artifact.channel == channel &&
                (name == nil || artifact.name == name)
        }
    }
}

public struct ScaffoldExecutableCatalogValidator: Sendable {
    public init() {}

    public func validate(
        catalog: ScaffoldExecutableCatalog,
        context: ScaffoldExecutableCatalogValidationContext
    ) throws {
        guard catalog.scaffold_domain == context.expectedDomain else {
            throw ScaffoldExecutableCatalogValidationError.wrongDomain(
                expected: context.expectedDomain,
                got: catalog.scaffold_domain
            )
        }
        guard !catalog.isExpired(now: context.now) else {
            throw ScaffoldExecutableCatalogValidationError.expired
        }
        guard context.trustedPublisherPublicKeys.isEmpty ||
            context.trustedPublisherPublicKeys.contains(catalog.issued_by)
        else {
            throw ScaffoldExecutableCatalogValidationError.issuerNotTrusted(catalog.issued_by)
        }
        guard catalog.signature.alg == "Ed25519" else {
            throw ScaffoldExecutableCatalogValidationError.unsupportedSignatureAlgorithm(catalog.signature.alg)
        }
        guard try catalog.verifySignature() else {
            throw ScaffoldExecutableCatalogValidationError.signatureInvalid
        }
        guard !catalog.artifacts.isEmpty else {
            throw ScaffoldExecutableCatalogValidationError.missingArtifacts
        }

        for artifact in catalog.artifacts {
            try validateURLString(artifact.download_url)
            try validateOptionalURLString(artifact.release_manifest_url)
            try validateOptionalURLString(artifact.checksum_url)
            try validateOptionalURLString(artifact.sbom_url)
            try validateOptionalURLString(artifact.provenance_url)
            try validateHash(artifact.sha256_b64url)
            if let size = artifact.size_bytes, size <= 0 {
                throw ScaffoldExecutableCatalogValidationError.invalidSizeBytes(artifactID: artifact.artifact_id)
            }
            guard !artifact.signing.isEmpty else {
                throw ScaffoldExecutableCatalogValidationError.missingSigning(artifactID: artifact.artifact_id)
            }
            for signing in artifact.signing {
                let type = signing.type.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasProof = signing.url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
                    signing.certificate_url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
                    signing.identity?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                guard !type.isEmpty, hasProof else {
                    throw ScaffoldExecutableCatalogValidationError.invalidSigning(artifactID: artifact.artifact_id)
                }
                try validateOptionalURLString(signing.url)
                try validateOptionalURLString(signing.certificate_url)
            }
        }
    }

    private func validateHash(_ value: String) throws {
        guard (try? Base64URL.decode(value)).map({ $0.count == 32 }) == true else {
            throw ScaffoldExecutableCatalogValidationError.invalidHash(value)
        }
    }

    private func validateOptionalURLString(_ value: String?) throws {
        guard let value else {
            return
        }
        try validateURLString(value)
    }

    private func validateURLString(_ value: String) throws {
        guard
            let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            scheme == "https"
        else {
            throw ScaffoldExecutableCatalogValidationError.invalidURL(value)
        }
    }
}

public final class ScaffoldExecutableCatalogHTTPClient: @unchecked Sendable {
    private let endpoint: URL
    private let session: URLSession
    private let validator: ScaffoldExecutableCatalogValidator
    private let now: @Sendable () -> Date

    public init(
        endpoint: URL,
        session: URLSession = .shared,
        validator: ScaffoldExecutableCatalogValidator = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.endpoint = endpoint
        self.session = session
        self.validator = validator
        self.now = now
    }

    public func fetch(
        expectedDomain: String,
        trustedPublisherPublicKeys: [String] = []
    ) async throws -> ScaffoldExecutableCatalog {
        let (data, response) = try await session.data(from: endpoint)
        guard let http = response as? HTTPURLResponse else {
            throw ScaffoldExecutableCatalogHTTPClientError.nonHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ScaffoldExecutableCatalogHTTPClientError.statusCode(http.statusCode)
        }

        let catalog = try JSONDecoder().decode(ScaffoldExecutableCatalog.self, from: data)
        try validator.validate(
            catalog: catalog,
            context: ScaffoldExecutableCatalogValidationContext(
                expectedDomain: expectedDomain,
                trustedPublisherPublicKeys: trustedPublisherPublicKeys,
                now: now()
            )
        )
        return catalog
    }

    public static func defaultEndpoint(scaffoldDomain: String) -> URL {
        URL(string: "https://\(scaffoldDomain)/.well-known/haven-executable-catalog.json")!
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        if #available(macOS 10.13, iOS 11.0, *) {
            encoder.outputFormatting = [.sortedKeys]
        }
        return encoder
    }
}
