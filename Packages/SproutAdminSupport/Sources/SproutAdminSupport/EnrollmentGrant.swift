import Foundation
import SproutCrypto

/// How an issued entity-link may later be revoked. Mirrors the
/// `revocation.mode` enum in `EntityLinkContract.schema.json`.
public enum RevocationMode: String, Codable, Equatable, Sendable {
    /// Both linked parties must agree to revoke.
    case mutual
    /// The owner (operator/scaffold) may revoke unilaterally. Default for
    /// pilots so the operator can pull an agent's access on its own.
    case ownerOnly = "owner-only"
}

/// An operator-side capability a single join code carries.
///
/// A code lets an agent self-enroll into a scaffold with minimal friction. The
/// grant is the cap the minted provisioning pack is clamped to: the agent's
/// `provisioning-request` may *narrow* purpose/interests, never widen them.
///
/// The code itself is never stored — only `codeHash` (SHA-256, base64url). The
/// operator sees the plaintext code once at issuance. A leaked grant store
/// therefore does not leak live codes.
///
/// Used identically by the `sprout-admin enroll-agent` CLI now and by the
/// enrollment HTTP endpoint later; only the trigger differs.
public struct EnrollmentGrant: Codable, Equatable, Sendable {

    // MARK: Code identity

    /// Stable id, e.g. `egr_<uuid>`.
    public var grantId: String
    /// SHA-256 of the normalized code, base64url. The plaintext code is never persisted.
    public var codeHash: String
    /// Human note, e.g. "Victoria laptop". Informational only.
    public var label: String?

    // MARK: Scaffold authority

    /// The scaffold this code may enroll into. Must equal the request's domain.
    public var scaffoldDomain: String

    // MARK: Capability cap (mint output is clamped to these)

    /// Authoritative purpose stamped into starter-auth + pack. The request's
    /// purpose is advisory; this always wins.
    public var purpose: String
    /// Allowed interests. The request's interests must be a subset of these.
    public var allowedInterests: [String]
    /// Free-form scope baked into the entity-link contract.
    public var entityLinkScope: String
    /// Revocation mode baked into the entity-link contract.
    public var revocationMode: RevocationMode

    // MARK: Handshake material (issued once, bound to this grant)

    /// High-entropy challenge the agent must echo (signed) in its pairing
    /// attestation. mint() rejects an attestation whose challenge differs.
    public var challenge: String
    /// Pairing id the operator approval is issued under.
    public var pairingID: String
    /// Entity-link `contract_id` both parties sign under.
    public var entityLinkContractId: String

    // MARK: Operator identity that mints/signs

    /// Vapor-vault identity-context whose admin key signs the operator half of
    /// the entity-link and the pairing artifact.
    public var operatorIdentityContext: String
    /// Informational issuer label → `pack.issuedBy`.
    public var issuedBy: String?

    // MARK: Lifetimes (deliberately separate)

    /// Lifetime of the *issued credential* (starter-auth), refreshable later.
    public var starterAuthTTLSeconds: Int

    // MARK: Code lifecycle

    public var maxUses: Int
    public var uses: Int
    public var issuedAt: String
    /// The *enrollment window* — short. Distinct from `starterAuthTTLSeconds`.
    public var codeExpiresAt: String
    /// Operator kill switch; a revoked grant never redeems.
    public var revoked: Bool

    // MARK: Optional tightening

    /// Lock the code to one known agent key. `nil` = open / trust-on-first-use:
    /// the first valid request within the window consumes the code.
    public var boundAgentPublicKeyBase64URL: String?

    public init(
        grantId: String,
        codeHash: String,
        label: String? = nil,
        scaffoldDomain: String,
        purpose: String,
        allowedInterests: [String],
        entityLinkScope: String,
        revocationMode: RevocationMode = .ownerOnly,
        challenge: String,
        pairingID: String,
        entityLinkContractId: String,
        operatorIdentityContext: String,
        issuedBy: String? = nil,
        starterAuthTTLSeconds: Int,
        maxUses: Int = 1,
        uses: Int = 0,
        issuedAt: String,
        codeExpiresAt: String,
        revoked: Bool = false,
        boundAgentPublicKeyBase64URL: String? = nil
    ) {
        self.grantId = grantId
        self.codeHash = codeHash
        self.label = label
        self.scaffoldDomain = scaffoldDomain
        self.purpose = purpose
        self.allowedInterests = allowedInterests
        self.entityLinkScope = entityLinkScope
        self.revocationMode = revocationMode
        self.challenge = challenge
        self.pairingID = pairingID
        self.entityLinkContractId = entityLinkContractId
        self.operatorIdentityContext = operatorIdentityContext
        self.issuedBy = issuedBy
        self.starterAuthTTLSeconds = starterAuthTTLSeconds
        self.maxUses = maxUses
        self.uses = uses
        self.issuedAt = issuedAt
        self.codeExpiresAt = codeExpiresAt
        self.revoked = revoked
        self.boundAgentPublicKeyBase64URL = boundAgentPublicKeyBase64URL
    }
}

// MARK: - Issuing

extension EnrollmentGrant {
    /// Issue a grant for a freshly generated (or supplied) plaintext code.
    /// Only the hash is retained; surface `code` to the operator once.
    public static func issue(
        code: String,
        scaffoldDomain: String,
        purpose: String,
        allowedInterests: [String],
        entityLinkScope: String,
        revocationMode: RevocationMode = .ownerOnly,
        operatorIdentityContext: String,
        issuedBy: String? = nil,
        starterAuthTTLSeconds: Int,
        codeTTLSeconds: Int,
        maxUses: Int = 1,
        boundAgentPublicKeyBase64URL: String? = nil,
        label: String? = nil,
        grantId: String = "egr_" + UUID().uuidString.lowercased(),
        challenge: String = randomToken(byteCount: 32),
        pairingID: String = "pair_" + UUID().uuidString.lowercased(),
        entityLinkContractId: String = "elc_" + UUID().uuidString.lowercased(),
        now: Date = Date()
    ) -> EnrollmentGrant {
        EnrollmentGrant(
            grantId: grantId,
            codeHash: codeHash(forPresented: code),
            label: label,
            scaffoldDomain: scaffoldDomain,
            purpose: purpose,
            allowedInterests: allowedInterests,
            entityLinkScope: entityLinkScope,
            revocationMode: revocationMode,
            challenge: challenge,
            pairingID: pairingID,
            entityLinkContractId: entityLinkContractId,
            operatorIdentityContext: operatorIdentityContext,
            issuedBy: issuedBy,
            starterAuthTTLSeconds: starterAuthTTLSeconds,
            maxUses: maxUses,
            uses: 0,
            issuedAt: iso8601(now),
            codeExpiresAt: iso8601(now.addingTimeInterval(TimeInterval(codeTTLSeconds))),
            revoked: false,
            boundAgentPublicKeyBase64URL: boundAgentPublicKeyBase64URL
        )
    }

    /// A high-entropy, human-typeable code: Crockford base32, grouped in fours.
    /// 15 bytes = 120 bits = 24 symbols (no padding), e.g. `K7QF-9M2X-...`.
    public static func generateCode(byteCount: Int = 15) -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        for _ in 0..<byteCount { bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &rng)) }

        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ") // Crockford: no I L O U
        var symbols = ""
        var buffer = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                symbols.append(alphabet[(buffer >> bits) & 0x1F])
            }
        }
        if bits > 0 {
            symbols.append(alphabet[(buffer << (5 - bits)) & 0x1F])
        }

        var grouped = ""
        for (i, ch) in symbols.enumerated() {
            if i > 0 && i % 4 == 0 { grouped.append("-") }
            grouped.append(ch)
        }
        return grouped
    }
}

// MARK: - Redemption

public enum EnrollmentGrantError: Error, Equatable, Sendable {
    case revoked
    case expired(codeExpiresAt: String)
    case exhausted(maxUses: Int)
    case codeMismatch
    case scaffoldDomainMismatch(grant: String, request: String)
    case interestsExceedGrant(extra: [String])
    case agentKeyMismatch(bound: String, request: String)
}

extension EnrollmentGrant {
    /// Validate a presented code + request against this grant. Throws on the
    /// first failure. On success the caller must `consume` the grant in the
    /// store (atomically) *before* minting, so single-use is real.
    ///
    /// Takes plain request fields rather than a request type so this module
    /// stays free of any cross-repo dependency on the agent's request shape.
    public func validateRedemption(
        presentedCode: String,
        requestScaffoldDomain: String,
        requestInterests: [String],
        requestAgentPublicKeyBase64URL: String,
        now: Date = Date()
    ) throws {
        guard !revoked else { throw EnrollmentGrantError.revoked }

        guard let expiry = Self.parseISO8601(codeExpiresAt) else {
            // Unparseable expiry is treated as expired — never fail open.
            throw EnrollmentGrantError.expired(codeExpiresAt: codeExpiresAt)
        }
        guard now < expiry else { throw EnrollmentGrantError.expired(codeExpiresAt: codeExpiresAt) }

        guard uses < maxUses else { throw EnrollmentGrantError.exhausted(maxUses: maxUses) }

        let presentedHash = Self.codeHash(forPresented: presentedCode)
        guard Self.constantTimeEquals(presentedHash, codeHash) else {
            throw EnrollmentGrantError.codeMismatch
        }

        guard requestScaffoldDomain == scaffoldDomain else {
            throw EnrollmentGrantError.scaffoldDomainMismatch(grant: scaffoldDomain, request: requestScaffoldDomain)
        }

        let extra = Set(requestInterests).subtracting(Set(allowedInterests))
        guard extra.isEmpty else {
            throw EnrollmentGrantError.interestsExceedGrant(extra: extra.sorted())
        }

        if let bound = boundAgentPublicKeyBase64URL {
            guard bound == requestAgentPublicKeyBase64URL else {
                throw EnrollmentGrantError.agentKeyMismatch(bound: bound, request: requestAgentPublicKeyBase64URL)
            }
        }
    }
}

// MARK: - Helpers

extension EnrollmentGrant {
    /// Hash of the *normalized* code, so display grouping/case never matters.
    public static func codeHash(forPresented code: String) -> String {
        Hashing.sha256Base64URL(Data(normalize(code).utf8))
    }

    /// High-entropy opaque token (base64url), e.g. for the pairing challenge.
    public static func randomToken(byteCount: Int = 32) -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        for _ in 0..<byteCount { bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &rng)) }
        return Base64URL.encode(Data(bytes))
    }

    /// Uppercase, strip everything that is not a base32 symbol (hyphens, spaces).
    static func normalize(_ code: String) -> String {
        String(code.uppercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    static func iso8601(_ date: Date) -> String {
        makeFormatter().string(from: date)
    }

    static func parseISO8601(_ string: String) -> Date? {
        makeFormatter().date(from: string)
    }

    // ISO8601DateFormatter is not Sendable, so make a fresh one per call
    // rather than sharing a mutable global.
    private static func makeFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    /// Constant-time string compare to avoid leaking the code via timing.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        var diff = ab.count ^ bb.count
        let n = Swift.max(ab.count, bb.count)
        var i = 0
        while i < n {
            let x = i < ab.count ? Int(ab[i]) : 0
            let y = i < bb.count ? Int(bb[i]) : 0
            diff |= (x ^ y)
            i += 1
        }
        return diff == 0
    }
}
