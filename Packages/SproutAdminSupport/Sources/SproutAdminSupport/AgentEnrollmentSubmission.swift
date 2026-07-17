import Foundation
import SproutCore
import SproutResolverAdapter

/// What the agent sends back after consuming an `EnrollmentTicket`: the
/// artifacts only it can produce (it holds its private key), for the operator
/// to co-sign into a provisioning pack.
///
/// This is the agent → operator wire contract. The HavenAgentD side
/// (`provisioning-request`, extended for the ticket flow) must emit exactly
/// this shape; a golden-fixture parity test keeps the two in sync.
public struct AgentEnrollmentSubmission: Codable, Equatable, Sendable {
    public static let kind = "haven-agentd-enrollment-submission"
    public static let currentVersion = "1.0"

    public var version: String
    public var kind: String

    /// Locates the grant; `code` then proves it.
    public var grantId: String
    public var code: String

    public var boundAgent: EnrollmentBoundAgent

    /// Agent-signed pairing attestation naming the operator + challenge.
    public var attestation: EnrollmentAttestation
    /// Agent-self-signed starter-auth (operator cannot mint this).
    public var starterAuth: StarterAuthPayload
    /// Agent's half of the entity-link: the full contract body with exactly the
    /// agent's signature. The operator appends its signature to complete it.
    public var entityLink: EntityLinkContract

    public init(
        version: String = AgentEnrollmentSubmission.currentVersion,
        kind: String = AgentEnrollmentSubmission.kind,
        grantId: String,
        code: String,
        boundAgent: EnrollmentBoundAgent,
        attestation: EnrollmentAttestation,
        starterAuth: StarterAuthPayload,
        entityLink: EntityLinkContract
    ) {
        self.version = version
        self.kind = kind
        self.grantId = grantId
        self.code = code
        self.boundAgent = boundAgent
        self.attestation = attestation
        self.starterAuth = starterAuth
        self.entityLink = entityLink
    }
}

public struct EnrollmentBoundAgent: Codable, Equatable, Sendable {
    public var agentIdentityUUID: String
    public var agentPublicKeyBase64URL: String

    public init(agentIdentityUUID: String, agentPublicKeyBase64URL: String) {
        self.agentIdentityUUID = agentIdentityUUID
        self.agentPublicKeyBase64URL = agentPublicKeyBase64URL
    }
}

/// Mirror of HavenAgentD's pairing `agentAttestation`. Canonicalization is
/// `JSONEncoder.sortedKeys` over `payload` (NOT JCS) and the signature is
/// base64url over that — matching the agent-side verifier exactly.
public struct EnrollmentAttestation: Codable, Equatable, Sendable {
    public struct Payload: Codable, Equatable, Sendable {
        public var version: String
        public var instanceName: String
        public var agentIdentityUUID: String
        public var agentDisplayName: String
        public var agentDid: String
        public var agentPublicKeyBase64URL: String
        public var operatorIdentityUUID: String
        public var operatorDid: String
        public var operatorPublicKeyBase64URL: String
        public var purposeRef: String
        public var scaffoldDomain: String
        public var challenge: String
        public var issuedAt: String

        public init(
            version: String,
            instanceName: String,
            agentIdentityUUID: String,
            agentDisplayName: String,
            agentDid: String,
            agentPublicKeyBase64URL: String,
            operatorIdentityUUID: String,
            operatorDid: String,
            operatorPublicKeyBase64URL: String,
            purposeRef: String,
            scaffoldDomain: String,
            challenge: String,
            issuedAt: String
        ) {
            self.version = version
            self.instanceName = instanceName
            self.agentIdentityUUID = agentIdentityUUID
            self.agentDisplayName = agentDisplayName
            self.agentDid = agentDid
            self.agentPublicKeyBase64URL = agentPublicKeyBase64URL
            self.operatorIdentityUUID = operatorIdentityUUID
            self.operatorDid = operatorDid
            self.operatorPublicKeyBase64URL = operatorPublicKeyBase64URL
            self.purposeRef = purposeRef
            self.scaffoldDomain = scaffoldDomain
            self.challenge = challenge
            self.issuedAt = issuedAt
        }
    }

    public var payload: Payload
    public var signatureAlgorithm: String
    public var signatureBase64URL: String

    public init(payload: Payload, signatureAlgorithm: String, signatureBase64URL: String) {
        self.payload = payload
        self.signatureAlgorithm = signatureAlgorithm
        self.signatureBase64URL = signatureBase64URL
    }

    /// Sorted-keys JSON of `payload` — the bytes the agent signed.
    public func canonicalPayloadData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }
}
