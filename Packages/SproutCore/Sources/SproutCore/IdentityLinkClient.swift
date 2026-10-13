// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import SproutCrypto
import SproutStorage
import SproutResolverAdapter

public enum IdentityLinkError: Error, Equatable {
    case invalidTicket, expired, unsafeEndpoint, invalidProof, invalidResponse
    case httpStatus(Int), recoveryRequired, alreadyLinked, approvalPending
    case expiredCompletionUnavailable
}

public enum IdentityLinkEncoding {
    /// CellProtocol CanonicalPayloadEncoder, deliberately distinct from Sprout JCS.
    static func canonicalPayload<T: Encodable>(for value: T, excludingTopLevelKeys keys: Set<String> = []) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw IdentityLinkError.invalidProof
        }
        for key in keys { object.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func encode<T: Encodable>(_ value: T, escapingSlashes: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = escapingSlashes ? [.sortedKeys] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func unsignedVC<T: Encodable>(_ value: T) throws -> Data {
        // VCClaim/VCPresentation sign JSONEncoder.sortedKeys.withoutEscapingSlashes.
        // JSONSerialization.sortedKeys is case-insensitive; JSONEncoder.sortedKeys
        // is lexical. All VC model keys are ASCII and values are strings/arrays/
        // objects, so JCS removal preserves the exact JSONEncoder byte ordering.
        try JCSCanonicalizer.canonicalizeRemovingTopLevelKeys(encode(value), keys: ["proof"])
    }
}

public struct IdentityLinkTicket: Codable, Equatable, Sendable {
    public var schema: String
    public var ticketID: String
    public var audience: String
    public var origin: String
    public var entityBinding: IdentityLinkWire.EntityBindingDescriptor
    public var rendezvousURL: String
    public var nonce: Data
    public var expiresAt: String
    public var presentationChallenge: Data
    public var presentationDomain: String
    public var ownerDisplayName: String
    public var approverLabel: String

    public static func decode(deepLink: String, domain: String, now: Date = Date()) throws -> Self {
        guard deepLink.utf8.count <= 16_384,
              let url = URLComponents(string: deepLink), url.scheme == "haven", url.host == "identity-link",
              url.path.isEmpty, url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              url.queryItems?.count == 1, let item = url.queryItems?.first, item.name == "t", let value = item.value,
              let data = try? Base64URL.decode(value), data.count <= 8_192,
              let ticket = try? JSONDecoder().decode(Self.self, from: data) else {
            throw IdentityLinkError.invalidTicket
        }
        try ticket.validate(domain: domain, now: now)
        return ticket
    }

    public func validate(domain: String, now: Date = Date()) throws {
        let canonicalDomain = try StarterIdentityStore.validateDomain(domain)
        let expectedOrigin = "https://\(canonicalDomain)"
        guard schema == "haven.identity-link.ticket.v1", ticketID.hasPrefix("lt-"),
              UUID(uuidString: String(ticketID.dropFirst(3))) != nil,
              audience == canonicalDomain, origin == expectedOrigin,
              rendezvousURL == expectedOrigin + "/link/api", presentationDomain == expectedOrigin,
              entityBinding.mode == .localEntityAnchor,
              entityBinding.entityAnchorReference == "cell:///EntityAnchor",
              entityBinding.audience == canonicalDomain, entityBinding.bindingID == nil,
              nonce.count == 32, presentationChallenge.count == 32,
              ownerDisplayName.utf8.count <= 512, approverLabel.utf8.count <= 512 else {
            throw IdentityLinkError.invalidTicket
        }
        guard let expiry = ISO8601DateFormatter().date(from: expiresAt), expiry > now,
              expiry <= now.addingTimeInterval(605) else { throw IdentityLinkError.expired }
    }
}

public struct IdentityLinkVCProof: Codable, Equatable, Sendable {
    public var type: String
    public var created: String
    public var proofPurpose: String
    public var verificationMethod: String
    public var signatureData: Data
}

public struct IdentityLinkCredential: Codable, Equatable, Sendable {
    public var context: [String]?
    public var id: String
    public var type: [String]
    public var issuer: String
    public var issuanceDate: String
    public var credentialSubject: IdentityLinkWire.SameEntityIdentityLinkCredentialSubject
    public var proof: IdentityLinkVCProof
    enum CodingKeys: String, CodingKey {
        case context = "@context"
        case id, type, issuer, issuanceDate, credentialSubject, proof
    }
}

public struct IdentityLinkPresentation: Codable, Equatable, Sendable {
    public var context: [String]?
    public var id: String
    public var type: [String]
    public var holder: String
    public var challenge: Data
    public var domain: String
    public var holderBinding: IdentityLinkWire.IdentityPublicKeyDescriptor
    public var verifiableCredential: [IdentityLinkCredential]
    public var proof: IdentityLinkVCProof
    enum CodingKeys: String, CodingKey {
        case context = "@context"
        case id, type, holder, challenge, domain, holderBinding, verifiableCredential, proof
    }
}

public struct IdentityLinkCompletionPackage: Codable, Equatable, Sendable {
    public var requestHash: String
    public var approval: IdentityLinkWire.IdentityEnrollmentApproval
    public var sameEntityCredential: IdentityLinkCredential
    public var issuerIdentity: IdentityLinkWire.IdentityPublicKeyDescriptor
    public var presentationChallenge: Data
    public var presentationDomain: String
    public var audience: String
    public var origin: String
    public var completeURL: String
}

public struct IdentityLinkCompletionEnvelope: Codable, Equatable, Sendable {
    public var request: IdentityLinkWire.IdentityEnrollmentRequest
    public var approval: IdentityLinkWire.IdentityEnrollmentApproval
    public var sameEntityCredential: IdentityLinkCredential
    public var presentation: IdentityLinkPresentation
    public var issuerIdentity: IdentityLinkWire.IdentityPublicKeyDescriptor
    public var expectedAudience: String
    public var expectedOrigin: String
    public var expectedPresentationChallenge: Data
    public var expectedPresentationDomain: String
    public var requireFreshAuthEvidence: Bool = true
}

public struct IdentityLinkPending: Codable, Equatable, Sendable {
    public var ticket: IdentityLinkTicket
    public var request: IdentityLinkWire.IdentityEnrollmentRequest
    public var requestHash: String
    public var controlWords: [String]
    public var completionURL: String { ticket.rendezvousURL + "/completion/" + requestHash }
}

public struct IdentityLinkSavedProgress: Sendable {
    public let pending: IdentityLinkPending
    public let hasCompletion: Bool
}

public struct IdentityLinkReceipt: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var domain: String
    public var identity: IdentityLinkWire.IdentityPublicKeyDescriptor
    public var evidenceReference: String
    public var linkID: String
}

struct IdentityLinkLocalRecord: Codable, Sendable {
    var version = 1
    var domain: String
    var identity: IdentityLinkWire.IdentityPublicKeyDescriptor
    var pending: IdentityLinkPending?
    var completion: IdentityLinkCompletionEnvelope?
    var receipt: IdentityLinkReceipt?
}

/// No browser cookies or passkeys are read by this client. The logged-in owner
/// independently approves the signed request in HAVEN's existing /link ceremony.
public actor IdentityLinkClient {
    private let session: URLSession
    private let now: @Sendable () -> Date
    // A failed network response is not proof that the earlier request had no
    // effect. This permit authorizes only an explicit local archive, not access.
    private struct RestartPermit {
        let id = UUID()
        let domain: String
        let identityRootPath: String
        let requestHash: String
        let stateDigest: Data
    }
    private var restartPermit: RestartPermit?

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
        session = BoundedHTTPSessions.identityLink
    }

    init(testSession: URLSession, now: @escaping @Sendable () -> Date) {
        self.session = testSession; self.now = now
    }

    /// Call only after consent and a verified, pinned trust descriptor.
    public func prepare(deepLink: String, domain: String, identityRoot: URL,
                        descriptor: ScaffoldAdminTrustRootDescriptor, pinnedKey: String,
                        deviceLabel: String = "Sprout CLI") async throws -> IdentityLinkPending {
        try OnboardingTrust.validate(descriptor, domain: domain, pinnedKey: pinnedKey, now: now())
        let ticket = try IdentityLinkTicket.decode(deepLink: deepLink, domain: domain, now: now())
        guard !deviceLabel.isEmpty, deviceLabel.utf8.count <= 120,
              deviceLabel.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw IdentityLinkError.invalidTicket
        }
        let starterStore = StarterIdentityStore(root: identityRoot)
        let starter = try await starterStore.loadOrCreate(scaffoldDomain: domain)
        let seed = try await starterStore.seedBase64URL(scaffoldDomain: domain)
        let lock = try PrivateStateLock(directory: identityRoot)
        defer { withExtendedLifetime(lock) {} }
        var record = try Self.loadRecord(domain: domain, publicKey: starter.identity_public_key, root: identityRoot)
        if let receipt = record?.receipt {
            try Self.validateReceipt(receipt, domain: domain, publicKey: starter.identity_public_key)
            throw IdentityLinkError.alreadyLinked
        }
        if let pending = record?.pending, pending.ticket == ticket {
            return pending
        }
        if record?.completion != nil { throw IdentityLinkError.recoveryRequired }
        let identity = try record?.identity ?? IdentityLinkWire.IdentityPublicKeyDescriptor(
            uuid: UUID().uuidString, displayName: deviceLabel,
            publicKey: Base64URL.decode(starter.identity_public_key), algorithm: .EdDSA, curveType: .Curve25519)
        var request = IdentityLinkWire.IdentityEnrollmentRequest(
            requestID: "request-" + UUID().uuidString.lowercased(), entityBinding: ticket.entityBinding,
            newIdentity: identity, requestedDomains: ["private", "scaffold"],
            requestedIdentityContexts: ["sprout-cli"], requestedScopes: ["same_entity"],
            audience: ticket.audience, origin: ticket.origin,
            createdAt: ISO8601DateFormatter().string(from: now()), expiresAt: ticket.expiresAt,
            nonce: ticket.nonce, platform: Self.platform, deviceLabel: deviceLabel)
        let bytes = try request.canonicalPayloadData()
        let signature = try Base64URL.decode(Ed25519.signBase64URL(data: bytes, seedBase64URL: seed))
        request.proof = .init(byIdentityUUID: identity.uuid, algorithm: .EdDSA, curveType: .Curve25519, signature: signature)
        let hash = Hashing.sha256(bytes)
        let pending = IdentityLinkPending(ticket: ticket, request: request, requestHash: Base64URL.encode(hash),
                                          controlWords: IdentityLinkWire.IdentityLinkSAS.words(requestHash: hash))
        record = .init(domain: domain, identity: identity, pending: pending)
        try Self.write(record!, root: identityRoot)
        return pending
    }

    public func submit(_ pending: IdentityLinkPending) async throws {
        try Self.validatePending(pending, now: now())
        struct Body: Encodable { let ticketID: String; let request: IdentityLinkWire.IdentityEnrollmentRequest }
        struct Reply: Decodable { let requestHash: String; let sas: [String]; let completionURL: String }
        let (data, _) = try await send(path: "/link/api/request", domain: pending.ticket.audience,
                                      body: IdentityLinkEncoding.encode(Body(ticketID: pending.ticket.ticketID, request: pending.request)))
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.requestHash == pending.requestHash, reply.sas == pending.controlWords,
              reply.completionURL == pending.completionURL else { throw IdentityLinkError.invalidResponse }
    }

    /// One bounded HTTP request; the caller decides whether and when to poll again.
    public func poll(_ pending: IdentityLinkPending) async throws -> IdentityLinkCompletionPackage? {
        try Self.validatePending(pending, now: now())
        let (data, status) = try await send(path: "/link/api/completion/" + pending.requestHash,
                                          domain: pending.ticket.audience, body: nil, allowPending: true)
        if status == 202 { return nil }
        let package = try JSONDecoder().decode(IdentityLinkCompletionPackage.self, from: data)
        try Self.validate(package: package, pending: pending, now: now())
        return package
    }

    public func complete(_ pending: IdentityLinkPending, package: IdentityLinkCompletionPackage,
                         identityRoot: URL) async throws -> IdentityLinkReceipt {
        try Self.validate(package: package, pending: pending, now: now())
        let store = StarterIdentityStore(root: identityRoot)
        let starter = try await store.load(scaffoldDomain: pending.ticket.audience)
        let seed = try await store.seedBase64URL(scaffoldDomain: pending.ticket.audience)
        let lock = try PrivateStateLock(directory: identityRoot)
        defer { withExtendedLifetime(lock) {} }
        var record = try Self.requiredRecord(domain: pending.ticket.audience, publicKey: starter.identity_public_key, root: identityRoot)
        guard record.identity == pending.request.newIdentity, record.pending == pending else {
            throw IdentityLinkError.recoveryRequired
        }
        let envelope: IdentityLinkCompletionEnvelope
        if let saved = record.completion { envelope = saved }
        else {
            envelope = try Self.makeCompletion(pending: pending, package: package, seedBase64URL: seed, now: now())
            record.completion = envelope
            // Retain exact bytes for an identical retry after an ambiguous response.
            try Self.write(record, root: identityRoot)
        }
        return try await finish(envelope: envelope, record: record, root: identityRoot)
    }

    /// Recover an ambiguous completion using the original signed presentation.
    public func retryCompletion(domain: String, identityRoot: URL) async throws -> IdentityLinkReceipt {
        let starter = try await StarterIdentityStore(root: identityRoot).load(scaffoldDomain: domain)
        let lock = try PrivateStateLock(directory: identityRoot)
        defer { withExtendedLifetime(lock) {} }
        let record = try Self.requiredRecord(domain: domain, publicKey: starter.identity_public_key, root: identityRoot)
        guard let envelope = record.completion else { throw IdentityLinkError.recoveryRequired }
        restartPermit = nil
        do {
            return try await finish(envelope: envelope, record: record, root: identityRoot)
        } catch IdentityLinkError.httpStatus(let status) where status == 404 || status == 410 {
            guard record.receipt == nil, let pending = record.pending,
                  let expiry = ISO8601DateFormatter().date(from: pending.ticket.expiresAt), expiry <= now() else {
                throw IdentityLinkError.httpStatus(status)
            }
            let state = try PrivateStateFiles.read(Self.recordURL(domain: domain, root: identityRoot))
            restartPermit = RestartPermit(domain: domain, identityRootPath: identityRoot.standardizedFileURL.path,
                requestHash: pending.requestHash, stateDigest: Hashing.sha256(state))
            throw IdentityLinkError.expiredCompletionUnavailable
        }
    }

    /// Call only after the user explicitly chooses a new invitation following
    /// expiredCompletionUnavailable on this client instance. The previous signed
    /// state is retained verbatim; it may still represent a completed server link.
    /// No timeout/5xx, fresh ticket or completed receipt enables this operation.
    @discardableResult
    public func archiveExpiredCompletionForNewInvitation(domain: String, identityRoot: URL) async throws -> URL {
        guard let permit = restartPermit, permit.domain == domain,
              permit.identityRootPath == identityRoot.standardizedFileURL.path else {
            throw IdentityLinkError.recoveryRequired
        }
        let starter = try await StarterIdentityStore(root: identityRoot).load(scaffoldDomain: domain)
        let lock = try PrivateStateLock(directory: identityRoot)
        defer { withExtendedLifetime(lock) {} }
        var record = try Self.requiredRecord(domain: domain, publicKey: starter.identity_public_key, root: identityRoot)
        let currentURL = try Self.recordURL(domain: domain, root: identityRoot)
        let state = try PrivateStateFiles.read(currentURL)
        guard restartPermit?.id == permit.id,
              Hashing.sha256(state) == permit.stateDigest, record.receipt == nil,
              let pending = record.pending, pending.requestHash == permit.requestHash,
              let envelope = record.completion,
              let expiry = ISO8601DateFormatter().date(from: pending.ticket.expiresAt), expiry <= now() else {
            throw IdentityLinkError.recoveryRequired
        }
        try Self.validateRetainedCompletion(envelope, pending: pending, now: now())
        let archiveDirectory = currentURL.deletingLastPathComponent()
            .appendingPathComponent("identity-link-recovery", isDirectory: true)
        try PrivateStateFiles.ensureDirectory(archiveDirectory)
        let archiveURL = archiveDirectory.appendingPathComponent(pending.requestHash + ".json")
        if PrivateStateFiles.exists(archiveURL) {
            guard try PrivateStateFiles.read(archiveURL) == state else { throw IdentityLinkError.recoveryRequired }
        } else {
            try PrivateStateFiles.write(state, to: archiveURL)
        }
        // Archive first. A failed second write leaves the original attempt intact
        // and an identical retry can reuse the already written archive.
        record.pending = nil
        record.completion = nil
        try Self.write(record, root: identityRoot)
        restartPermit = nil
        return archiveURL
    }

    /// The CLI may resume polling, or retry the retained completion after a lost
    /// response. An expired pending request remains visible so the CLI can explain
    /// why a fresh invitation is needed; poll/complete still enforce live expiry.
    public func loadProgress(domain: String, identityRoot: URL) async throws -> IdentityLinkSavedProgress? {
        let starter = try await StarterIdentityStore(root: identityRoot).load(scaffoldDomain: domain)
        guard let record = try Self.loadRecord(domain: domain, publicKey: starter.identity_public_key, root: identityRoot),
              let pending = record.pending else { return nil }
        guard let created = ISO8601DateFormatter().date(from: pending.request.createdAt), created <= now(),
              pending.request.newIdentity == record.identity else { throw IdentityLinkError.recoveryRequired }
        try Self.validatePending(pending, now: created)
        if let envelope = record.completion {
            try Self.validateRetainedCompletion(envelope, pending: pending, now: now())
        }
        return IdentityLinkSavedProgress(pending: pending, hasCompletion: record.completion != nil)
    }

    public func loadReceipt(domain: String, identityRoot: URL) async throws -> IdentityLinkReceipt? {
        let starter = try await StarterIdentityStore(root: identityRoot).load(scaffoldDomain: domain)
        guard let record = try Self.loadRecord(domain: domain, publicKey: starter.identity_public_key, root: identityRoot),
              let receipt = record.receipt else { return nil }
        try Self.validateReceipt(receipt, domain: domain, publicKey: starter.identity_public_key)
        return receipt
    }

    public func makeResolveProof(request: EntityResolutionRequest, identityRoot: URL) async throws -> PersonLinkProof? {
        guard let receipt = try await loadReceipt(domain: request.domain, identityRoot: identityRoot) else { return nil }
        let seed = try await StarterIdentityStore(root: identityRoot).seedBase64URL(scaffoldDomain: request.domain)
        return try IdentityLinkProof.makeResolveProof(request: request, receipt: receipt,
                                                      seedBase64URL: seed, now: now())
    }

    private func finish(envelope: IdentityLinkCompletionEnvelope, record: IdentityLinkLocalRecord,
                        root: URL) async throws -> IdentityLinkReceipt {
        struct Reply: Decodable {
            var status: String
            var record: IdentityLinkWire.IdentityLinkRecord
            var evidenceReference: String
            var linkID: String
        }
        guard let pending = record.pending, pending.request.newIdentity == record.identity else {
            throw IdentityLinkError.recoveryRequired
        }
        try Self.validateRetainedCompletion(envelope, pending: pending, now: now())
        let (data, _) = try await send(path: "/link/api/complete", domain: record.domain,
                                      body: IdentityLinkEncoding.encode(envelope))
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let approved = envelope.approval
        guard reply.status == "completed", reply.record.status == .active,
              reply.record.linkedIdentity == record.identity,
              reply.linkID == reply.record.linkID, reply.linkID == approved.approvalID,
              reply.record.entityBinding == approved.entityBinding,
              reply.record.approvedDomains == approved.approvedDomains,
              reply.record.approvedIdentityContexts == approved.approvedIdentityContexts,
              reply.record.approvedScopes == approved.approvedScopes,
              reply.record.issuerIdentityUUID == approved.issuerIdentityUUID,
              reply.record.issuerType == approved.issuerType else { throw IdentityLinkError.invalidResponse }
        let receipt = IdentityLinkReceipt(domain: record.domain, identity: record.identity,
                                          evidenceReference: reply.evidenceReference, linkID: reply.linkID)
        try Self.validateReceipt(receipt, domain: record.domain, publicKey: Base64URL.encode(record.identity.publicKey))
        var finished = record
        finished.receipt = receipt; finished.pending = nil; finished.completion = nil
        try Self.write(finished, root: root)
        return receipt
    }

    private func send(path: String, domain: String, body: Data?, allowPending: Bool = false) async throws -> (Data, Int) {
        let url = try OnboardingTrust.endpoint("https://\(domain)\(path)", domain: domain)
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            guard body.count <= 65_536 else { throw IdentityLinkError.invalidProof }
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await PersonLinkHTTP.data(for: request, session: session)
        guard let response = response as? HTTPURLResponse, response.url == url, data.count <= 65_536 else {
            throw IdentityLinkError.invalidResponse
        }
        guard response.statusCode == 200 || (allowPending && response.statusCode == 202) else {
            throw IdentityLinkError.httpStatus(response.statusCode)
        }
        return (data, response.statusCode)
    }

    static func validatePending(_ pending: IdentityLinkPending, now: Date) throws {
        try pending.ticket.validate(domain: pending.ticket.audience, now: now)
        let request = pending.request
        let bytes = try request.canonicalPayloadData()
        let hash = Hashing.sha256(bytes)
        guard pending.requestHash == Base64URL.encode(hash),
              pending.controlWords == IdentityLinkWire.IdentityLinkSAS.words(requestHash: hash),
              request.version == 1, request.purpose == "link_identity", request.audience == pending.ticket.audience,
              request.origin == pending.ticket.origin, request.entityBinding == pending.ticket.entityBinding,
              request.nonce == pending.ticket.nonce, request.requestedDomains == ["private", "scaffold"],
              request.requestedIdentityContexts == ["sprout-cli"], request.requestedScopes == ["same_entity"],
              request.expiresAt == pending.ticket.expiresAt,
              let created = ISO8601DateFormatter().date(from: request.createdAt), created <= now,
              request.newIdentity.algorithm == .EdDSA, request.newIdentity.curveType == .Curve25519,
              let proof = request.proof, proof.type == "signature", proof.byIdentityUUID == request.newIdentity.uuid,
              proof.algorithm == .EdDSA, proof.curveType == .Curve25519,
              let signature = proof.signature,
              Ed25519.verify(data: bytes, signature: signature, publicKey: request.newIdentity.publicKey) else {
            throw IdentityLinkError.invalidProof
        }
    }

    static func validate(package: IdentityLinkCompletionPackage, pending: IdentityLinkPending, now: Date) throws {
        try validatePending(pending, now: now)
        let approval = package.approval, request = pending.request, ticket = pending.ticket
        let issuer = package.issuerIdentity
        let hash = try Base64URL.decode(pending.requestHash)
        let credential = package.sameEntityCredential, subject = credential.credentialSubject
        guard package.requestHash == pending.requestHash, package.audience == ticket.audience,
              package.origin == ticket.origin, package.presentationChallenge == ticket.presentationChallenge,
              package.presentationDomain == ticket.presentationDomain, package.completeURL == ticket.rendezvousURL + "/complete",
              approval.version == 1, approval.purpose == "approve_link_identity", approval.requestHash == hash,
              approval.entityBinding == request.entityBinding, approval.subjectIdentity == request.newIdentity,
              approval.audience == ticket.audience, approval.origin == ticket.origin,
              approval.issuerIdentityUUID == issuer.uuid, approval.issuerType == .existingDevice,
              issuer.publicKey != request.newIdentity.publicKey,
              approval.approvedScopes == ["same_entity"], approval.approvedDomains == request.requestedDomains,
              approval.approvedIdentityContexts == request.requestedIdentityContexts,
              UUID(uuidString: approval.approvalID) != nil, !approval.jti.isEmpty,
              let expiry = ISO8601DateFormatter().date(from: approval.expiresAt), expiry > now,
              let created = ISO8601DateFormatter().date(from: approval.createdAt), created <= now,
              approval.freshAuthRequired, approval.freshAuthPerformedAt != nil,
              let fresh = approval.freshAuthEvidence, fresh.method == "webauthn", fresh.challenge == hash,
              fresh.performedAt == approval.freshAuthPerformedAt,
              fresh.authenticatorData?.isEmpty == false, fresh.clientDataJSON?.isEmpty == false,
              fresh.credentialID?.isEmpty == false, fresh.signature?.isEmpty == false,
              let proof = approval.proof, proof.type == "signature", proof.issuerIdentityUUID == issuer.uuid,
              proof.issuerType == approval.issuerType, proof.algorithm == issuer.algorithm, proof.curveType == issuer.curveType,
              let signature = proof.signature,
              Self.verify(signature: signature, data: try approval.canonicalPayloadData(), identity: issuer),
              credential.type.contains("SameEntityIdentityLinkCredential"), credential.issuer == (try did(issuer)),
              credential.proof.proofPurpose == "assertionMethod", credential.proof.verificationMethod == issuer.uuid,
              credential.proof.type == Self.proofType(issuer),
              Self.verify(signature: credential.proof.signatureData, data: try IdentityLinkEncoding.unsignedVC(credential), identity: issuer),
              subject.id == (try did(request.newIdentity)), subject.linkType == "same_entity",
              subject.linkedIdentity == request.newIdentity, subject.entityBinding == approval.entityBinding,
              subject.approvedDomains == approval.approvedDomains, subject.approvedIdentityContexts == approval.approvedIdentityContexts,
              subject.approvedScopes == approval.approvedScopes, subject.enrollmentRequestHash == hash,
              let validUntil = ISO8601DateFormatter().date(from: subject.validUntil), validUntil > now else {
            throw IdentityLinkError.invalidProof
        }
        // The server independently verifies WebAuthn RP/origin/challenge/signature
        // against the owner's credential store before committing this link.
    }

    static func makeCompletion(pending: IdentityLinkPending, package: IdentityLinkCompletionPackage,
                               seedBase64URL: String, now: Date) throws -> IdentityLinkCompletionEnvelope {
        try validate(package: package, pending: pending, now: now)
        let identity = pending.request.newIdentity
        guard try Ed25519.publicKeyBase64URL(fromSeedBase64URL: seedBase64URL) == Base64URL.encode(identity.publicKey) else {
            throw IdentityLinkError.invalidProof
        }
        var presentation = IdentityLinkPresentation(
            context: ["https://www.w3.org/2018/credentials/v1", "https://www.w3.org/2018/credentials/examples/v1"],
            id: "cell:///identity/\(identity.uuid)/claims/\(UUID().uuidString)",
            type: ["VerifiableCredential", "SameEntityIdentityLinkPresentation"], holder: try did(identity),
            challenge: pending.ticket.presentationChallenge, domain: pending.ticket.presentationDomain,
            holderBinding: identity, verifiableCredential: [package.sameEntityCredential],
            proof: .init(type: "Ed25519Signature2020", created: ISO8601DateFormatter().string(from: now),
                         proofPurpose: "authentication", verificationMethod: identity.uuid, signatureData: Data()))
        presentation.proof.signatureData = try Base64URL.decode(Ed25519.signBase64URL(
            data: IdentityLinkEncoding.unsignedVC(presentation), seedBase64URL: seedBase64URL))
        return IdentityLinkCompletionEnvelope(request: pending.request, approval: package.approval,
                                               sameEntityCredential: package.sameEntityCredential, presentation: presentation,
                                               issuerIdentity: package.issuerIdentity, expectedAudience: pending.ticket.audience,
                                               expectedOrigin: pending.ticket.origin, expectedPresentationChallenge: pending.ticket.presentationChallenge,
                                               expectedPresentationDomain: pending.ticket.presentationDomain)
    }

    /// A retry may occur after approval expiry when the server already prepared
    /// durable evidence. Verify the original package at its signed approval time;
    /// only the server can decide whether recovery is still authorized now.
    static func validateRetainedCompletion(_ envelope: IdentityLinkCompletionEnvelope,
                                           pending: IdentityLinkPending, now: Date) throws {
        guard envelope.request == pending.request, envelope.requireFreshAuthEvidence,
              envelope.expectedAudience == pending.ticket.audience,
              envelope.expectedOrigin == pending.ticket.origin,
              envelope.expectedPresentationChallenge == pending.ticket.presentationChallenge,
              envelope.expectedPresentationDomain == pending.ticket.presentationDomain,
              let approvalTime = ISO8601DateFormatter().date(from: envelope.approval.createdAt),
              approvalTime <= now else { throw IdentityLinkError.recoveryRequired }
        let package = IdentityLinkCompletionPackage(requestHash: pending.requestHash,
            approval: envelope.approval, sameEntityCredential: envelope.sameEntityCredential,
            issuerIdentity: envelope.issuerIdentity, presentationChallenge: pending.ticket.presentationChallenge,
            presentationDomain: pending.ticket.presentationDomain, audience: pending.ticket.audience,
            origin: pending.ticket.origin, completeURL: pending.ticket.rendezvousURL + "/complete")
        try validate(package: package, pending: pending, now: approvalTime)
        let presentation = envelope.presentation, identity = pending.request.newIdentity
        guard presentation.challenge == pending.ticket.presentationChallenge,
              presentation.domain == pending.ticket.presentationDomain,
              presentation.holderBinding == identity, presentation.holder == (try did(identity)),
              presentation.type == ["VerifiableCredential", "SameEntityIdentityLinkPresentation"],
              presentation.verifiableCredential == [envelope.sameEntityCredential],
              presentation.proof.proofPurpose == "authentication",
              presentation.proof.verificationMethod == identity.uuid,
              presentation.proof.type == "Ed25519Signature2020",
              verify(signature: presentation.proof.signatureData,
                     data: try IdentityLinkEncoding.unsignedVC(presentation), identity: identity) else {
            throw IdentityLinkError.recoveryRequired
        }
    }

    static func proofType(_ identity: IdentityLinkWire.IdentityPublicKeyDescriptor) -> String {
        identity.algorithm == .EdDSA && identity.curveType == .Curve25519 ? "Ed25519Signature2020" : "EcdsaSecp256r1Signature2019"
    }

    static func verify(signature: Data, data: Data, identity: IdentityLinkWire.IdentityPublicKeyDescriptor) -> Bool {
        switch (identity.algorithm, identity.curveType) {
        case (.EdDSA, .Curve25519): return Ed25519.verify(data: data, signature: signature, publicKey: identity.publicKey)
        case (.ECDSA, .P256):
            let key: P256.Signing.PublicKey?
            if identity.publicKey.count == 65 { key = try? P256.Signing.PublicKey(x963Representation: identity.publicKey) }
            else if identity.publicKey.count == 33 { key = try? P256.Signing.PublicKey(compressedRepresentation: identity.publicKey) }
            else { key = nil }
            guard let key, let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
            return key.isValidSignature(sig, for: data)
        default: return false
        }
    }

    static func did(_ identity: IdentityLinkWire.IdentityPublicKeyDescriptor) throws -> String {
        let prefix: [UInt8]
        switch (identity.algorithm, identity.curveType) {
        case (.EdDSA, .Curve25519): guard identity.publicKey.count == 32 else { throw IdentityLinkError.invalidProof }; prefix = [0xed, 0x01]
        case (.ECDSA, .P256): guard [33, 65].contains(identity.publicKey.count) else { throw IdentityLinkError.invalidProof }; prefix = [0x80, 0x24]
        default: throw IdentityLinkError.invalidProof
        }
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        let bytes = prefix + identity.publicKey
        var digits: [Int] = [0]
        for byte in bytes {
            var carry = Int(byte)
            for index in digits.indices { carry += digits[index] * 256; digits[index] = carry % 58; carry /= 58 }
            while carry > 0 { digits.append(carry % 58); carry /= 58 }
        }
        let encoded = String(repeating: "1", count: bytes.prefix(while: { $0 == 0 }).count)
            + String(digits.reversed().map { alphabet[$0] })
        return "did:key:z" + encoded
    }

    static func validateReceipt(_ receipt: IdentityLinkReceipt, domain: String, publicKey: String) throws {
        guard receipt.version == 1, receipt.domain == domain,
              receipt.identity.algorithm == .EdDSA, receipt.identity.curveType == .Curve25519,
              UUID(uuidString: receipt.identity.uuid) != nil, receipt.identity.publicKey.count == 32,
              Base64URL.encode(receipt.identity.publicKey) == publicKey,
              receipt.evidenceReference.utf8.count == 64,
              receipt.evidenceReference.allSatisfy({ "0123456789abcdef".contains($0) }),
              UUID(uuidString: receipt.linkID) != nil, receipt.linkID.utf8.count == 36 else {
            throw IdentityLinkError.recoveryRequired
        }
    }

    private static func recordURL(domain: String, root: URL) throws -> URL {
        let canonicalDomain = try StarterIdentityStore.validateDomain(domain)
        guard canonicalDomain == domain else { throw IdentityLinkError.recoveryRequired }
        try PrivateStateFiles.validateDirectory(root)
        let directory = root.appendingPathComponent(domain, isDirectory: true)
        try PrivateStateFiles.validateDirectory(directory)
        return directory.appendingPathComponent("identity-link.json")
    }

    private static func loadRecord(domain: String, publicKey: String, root: URL) throws -> IdentityLinkLocalRecord? {
        let url = try recordURL(domain: domain, root: root)
        guard PrivateStateFiles.exists(url) else { return nil }
        do {
            let record = try JSONDecoder().decode(IdentityLinkLocalRecord.self, from: PrivateStateFiles.read(url))
            guard record.version == 1, record.domain == domain,
                  UUID(uuidString: record.identity.uuid) != nil, record.identity.algorithm == .EdDSA,
                  record.identity.curveType == .Curve25519, record.identity.publicKey.count == 32,
                  Base64URL.encode(record.identity.publicKey) == publicKey else { throw IdentityLinkError.recoveryRequired }
            return record
        } catch { throw IdentityLinkError.recoveryRequired }
    }

    private static func requiredRecord(domain: String, publicKey: String, root: URL) throws -> IdentityLinkLocalRecord {
        guard let record = try loadRecord(domain: domain, publicKey: publicKey, root: root) else { throw IdentityLinkError.recoveryRequired }
        return record
    }
    private static func write(_ record: IdentityLinkLocalRecord, root: URL) throws {
        try PrivateStateFiles.write(IdentityLinkEncoding.encode(record), to: recordURL(domain: record.domain, root: root))
    }
    private static var platform: String {
        #if os(Linux)
        "linux"
        #elseif os(macOS)
        "macos"
        #else
        "cli"
        #endif
    }
}

public enum IdentityLinkProof {
    public struct Challenge: Codable, Equatable, Sendable {
        public var type = "org.haven.cellprotocol.identity-signing-challenge"
        public var version = 1
        public var purpose = "identity-origin-proof"
        public var identityUUID: String
        public var publicKeyFingerprint: String
        public var domain: String
        public var resource: String
        public var action: String
        public var audience: String
        public var nonce: Data
        public var issuedAt: TimeInterval
        public var expiresAt: TimeInterval
    }

    public static func makeResolveProof(request: EntityResolutionRequest, receipt: IdentityLinkReceipt,
                                         seedBase64URL: String, now: Date = Date(), nonce: Data? = nil) throws -> PersonLinkProof {
        try IdentityLinkClient.validateReceipt(receipt, domain: request.domain, publicKey: request.identity_public_key)
        guard try Ed25519.publicKeyBase64URL(fromSeedBase64URL: seedBase64URL) == request.identity_public_key else {
            throw IdentityLinkError.invalidProof
        }
        struct Binding: Encodable {
            let schema = "haven.sprout-person-entity-resolution.v1"
            let identity_public_key: String
            let domain: String
            let scaffold_admin_public_key: String
            let purpose: String
            let goal: String
            let interests: [String]
            let evidence_reference: String
            let link_id: String
            let evidence: EntityEvidenceSummary?
        }
        let binding = Binding(identity_public_key: request.identity_public_key, domain: request.domain,
                              scaffold_admin_public_key: request.scaffold_admin_public_key, purpose: request.purpose,
                              goal: request.goal, interests: request.interests, evidence_reference: receipt.evidenceReference,
                              link_id: receipt.linkID, evidence: request.evidence)
        let resource = "sprout-entity-resolution:" + Hashing.sha256Base64URL(
            try JCSCanonicalizer.canonicalize(JSONEncoder().encode(binding)))
        let random = nonce ?? Ed25519.generateSeed()
        guard random.count >= 32, random.count <= 128 else { throw IdentityLinkError.invalidProof }
        let challenge = Challenge(identityUUID: receipt.identity.uuid,
                                  publicKeyFingerprint: "EdDSA:Curve25519:" + receipt.identity.publicKey.base64EncodedString(),
                                  domain: "private", resource: resource, action: "sprout.entity.resolve.v1",
                                  audience: "https://" + request.domain, nonce: random,
                                  issuedAt: now.timeIntervalSince1970, expiresAt: now.addingTimeInterval(60).timeIntervalSince1970)
        let data = try IdentityLinkEncoding.encode(challenge, escapingSlashes: true)
        return PersonLinkProof(evidenceReference: receipt.evidenceReference, linkID: receipt.linkID, challenge: data,
                               signature: try Base64URL.decode(Ed25519.signBase64URL(data: data, seedBase64URL: seedBase64URL)))
    }
}
