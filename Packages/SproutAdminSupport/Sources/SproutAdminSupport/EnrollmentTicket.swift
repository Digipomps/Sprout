import Foundation
import SproutCrypto

/// The operator → user → agent handoff for the enrollment-ticket flow.
///
/// It carries everything the agent needs to self-attest in ONE round during
/// `setup`: the operator's identity (which the agent must name in its pairing
/// attestation and entity-link half), the challenge, and the pinned entity-link
/// fields both parties sign under. The agent echoes `code` back so the operator
/// can locate and verify the matching `EnrollmentGrant`.
///
/// It is a bearer artifact (it contains the code), so treat it like the code:
/// single-use, short-lived, delivered over a channel the user controls.
public struct EnrollmentTicket: Codable, Equatable, Sendable {
    public static let kind = "haven-agentd-enrollment-ticket"
    public static let currentVersion = "1.0"

    public var version: String
    public var kind: String

    /// Lets the operator locate the grant directly; `code` then proves it.
    public var grantId: String
    /// The bearer secret. Echoed back by the agent; verified against codeHash.
    public var code: String

    public var scaffoldDomain: String
    public var purpose: String
    /// Cap the agent must stay within when asserting interests.
    public var allowedInterests: [String]

    // Handshake material the agent must reproduce verbatim.
    public var challenge: String
    public var pairingID: String
    public var entityLinkContractId: String
    public var entityLinkScope: String
    public var revocationMode: RevocationMode

    // Operator identity the agent names in its attestation + entity-link half.
    public var operatorIdentityUUID: String
    public var operatorDid: String
    public var operatorPublicKeyBase64URL: String

    // Optional scaffold connection, so `setup` can prefill config (less friction).
    public var resolverBaseURL: String?
    public var discoveryURL: String?

    /// Mirrors the grant's code window; informational on the agent side.
    public var expiresAt: String
    public var issuedBy: String?

    public init(
        version: String = EnrollmentTicket.currentVersion,
        kind: String = EnrollmentTicket.kind,
        grantId: String,
        code: String,
        scaffoldDomain: String,
        purpose: String,
        allowedInterests: [String],
        challenge: String,
        pairingID: String,
        entityLinkContractId: String,
        entityLinkScope: String,
        revocationMode: RevocationMode,
        operatorIdentityUUID: String,
        operatorDid: String,
        operatorPublicKeyBase64URL: String,
        resolverBaseURL: String? = nil,
        discoveryURL: String? = nil,
        expiresAt: String,
        issuedBy: String? = nil
    ) {
        self.version = version
        self.kind = kind
        self.grantId = grantId
        self.code = code
        self.scaffoldDomain = scaffoldDomain
        self.purpose = purpose
        self.allowedInterests = allowedInterests
        self.challenge = challenge
        self.pairingID = pairingID
        self.entityLinkContractId = entityLinkContractId
        self.entityLinkScope = entityLinkScope
        self.revocationMode = revocationMode
        self.operatorIdentityUUID = operatorIdentityUUID
        self.operatorDid = operatorDid
        self.operatorPublicKeyBase64URL = operatorPublicKeyBase64URL
        self.resolverBaseURL = resolverBaseURL
        self.discoveryURL = discoveryURL
        self.expiresAt = expiresAt
        self.issuedBy = issuedBy
    }
}

// MARK: - Building from a grant

extension EnrollmentTicket {
    /// Build the ticket for a freshly issued grant. Operator identity comes from
    /// the vault identity-context the grant mints under; `code` is the plaintext
    /// the operator surfaces once.
    public static func make(
        grant: EnrollmentGrant,
        code: String,
        operatorIdentityUUID: String,
        operatorDid: String,
        operatorPublicKeyBase64URL: String,
        resolverBaseURL: String? = nil,
        discoveryURL: String? = nil
    ) -> EnrollmentTicket {
        EnrollmentTicket(
            grantId: grant.grantId,
            code: code,
            scaffoldDomain: grant.scaffoldDomain,
            purpose: grant.purpose,
            allowedInterests: grant.allowedInterests,
            challenge: grant.challenge,
            pairingID: grant.pairingID,
            entityLinkContractId: grant.entityLinkContractId,
            entityLinkScope: grant.entityLinkScope,
            revocationMode: grant.revocationMode,
            operatorIdentityUUID: operatorIdentityUUID,
            operatorDid: operatorDid,
            operatorPublicKeyBase64URL: operatorPublicKeyBase64URL,
            resolverBaseURL: resolverBaseURL,
            discoveryURL: discoveryURL,
            expiresAt: grant.codeExpiresAt,
            issuedBy: grant.issuedBy
        )
    }
}

// MARK: - Compact single-string encoding

public enum EnrollmentTicketCodingError: Error, Equatable, Sendable {
    case malformed
    case unsupportedKind(String)
    case unsupportedVersion(String)
}

extension EnrollmentTicket {
    /// Base64url(JSON) so the whole ticket pastes as one opaque string.
    public func encodedString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Base64URL.encode(try encoder.encode(self))
    }

    public static func decode(_ string: String) throws -> EnrollmentTicket {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let data: Data
        if let decoded = try? Base64URL.decode(trimmed) {
            data = decoded
        } else if let raw = trimmed.data(using: .utf8),
                  (try? JSONDecoder().decode(EnrollmentTicket.self, from: raw)) != nil {
            data = raw // tolerate a raw JSON ticket too
        } else {
            throw EnrollmentTicketCodingError.malformed
        }
        let ticket = try JSONDecoder().decode(EnrollmentTicket.self, from: data)
        guard ticket.kind == EnrollmentTicket.kind else {
            throw EnrollmentTicketCodingError.unsupportedKind(ticket.kind)
        }
        guard ticket.version == EnrollmentTicket.currentVersion else {
            throw EnrollmentTicketCodingError.unsupportedVersion(ticket.version)
        }
        return ticket
    }
}
