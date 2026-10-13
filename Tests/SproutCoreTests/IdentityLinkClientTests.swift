import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import SproutCore
import SproutCrypto
import SproutResolverAdapter
import SproutStorage
import XCTest

final class IdentityLinkClientTests: XCTestCase {
    func testIndependentPythonFixtureMatchesCellProtocolSigningBytesAndVerifies() throws {
        let fixture = try LinkFixture.load()
        let pending = fixture.pending
        XCTAssertEqual(String(decoding: try pending.request.canonicalPayloadData(), as: UTF8.self), String(decoding: Data(base64Encoded: fixture.requestCanonicalBase64)!, as: UTF8.self))
        XCTAssertEqual(Hashing.sha256Base64URL(try pending.request.canonicalPayloadData()), fixture.requestHash)
        XCTAssertEqual(String(decoding: try IdentityLinkEncoding.unsignedVC(fixture.envelope.presentation), as: UTF8.self), String(decoding: Data(base64Encoded: fixture.presentationCanonicalBase64)!, as: UTF8.self))
        try IdentityLinkClient.validatePending(pending, now: fixture.date)
        try IdentityLinkClient.validate(package: fixture.package, pending: pending, now: fixture.date)
        XCTAssertEqual(try IdentityLinkClient.did(fixture.request.newIdentity), fixture.envelope.presentation.holder)
        let proof = try IdentityLinkProof.makeResolveProof(request: fixture.resolutionRequest, receipt: fixture.receipt,
                                                          seedBase64URL: fixture.seedBase64URL, now: fixture.date,
                                                          nonce: Data(repeating: 0x47, count: 32))
        XCTAssertEqual(proof.challenge, Data(base64Encoded: fixture.challengeCanonicalBase64))
        XCTAssertTrue(Ed25519.verify(data: proof.challenge, signature: fixture.resolveProof.signature, publicKey: fixture.receipt.identity.publicKey))
        XCTAssertTrue(Ed25519.verify(data: proof.challenge, signature: proof.signature, publicKey: fixture.receipt.identity.publicKey))
        let completion = try IdentityLinkClient.makeCompletion(pending: pending, package: fixture.package,
                                                               seedBase64URL: fixture.seedBase64URL, now: fixture.date)
        XCTAssertTrue(Ed25519.verify(data: try IdentityLinkEncoding.unsignedVC(completion.presentation),
                                    signature: completion.presentation.proof.signatureData,
                                    publicKey: pending.request.newIdentity.publicKey))
    }

    func testResolutionProofBindsEachRequestFieldAndCannotUseAnotherKey() throws {
        let fixture = try LinkFixture.load()
        let original = fixture.resolveProof.challenge
        var requests = [EntityResolutionRequest]()
        var request = fixture.resolutionRequest; request.goal += " changed"; requests.append(request)
        request = fixture.resolutionRequest; request.purpose += " changed"; requests.append(request)
        request = fixture.resolutionRequest; request.interests.append("another"); requests.append(request)
        request = fixture.resolutionRequest; request.scaffold_admin_public_key = "another"; requests.append(request)
        for request in requests {
            let proof = try IdentityLinkProof.makeResolveProof(request: request, receipt: fixture.receipt,
                                                              seedBase64URL: fixture.seedBase64URL, now: fixture.date,
                                                              nonce: Data(repeating: 0x47, count: 32))
            XCTAssertNotEqual(proof.challenge, original)
        }
        XCTAssertThrowsError(try IdentityLinkProof.makeResolveProof(request: fixture.resolutionRequest, receipt: fixture.receipt,
                                                                     seedBase64URL: fixture.issuerSeedBase64URL, now: fixture.date))
        var crossDomain = fixture.resolutionRequest; crossDomain.domain = "evil.example"
        XCTAssertThrowsError(try IdentityLinkProof.makeResolveProof(request: crossDomain, receipt: fixture.receipt,
                                                                     seedBase64URL: fixture.seedBase64URL, now: fixture.date))
    }

    func testTicketRejectsExpiryCrossOriginAndMalformedInvitationBeforeKeyOrNetwork() async throws {
        let fixture = try LinkFixture.load()
        XCTAssertEqual(try IdentityLinkTicket.decode(deepLink: fixture.deepLink, domain: fixture.ticket.audience, now: fixture.date), fixture.ticket)
        XCTAssertThrowsError(try IdentityLinkTicket.decode(deepLink: fixture.deepLink, domain: "other.example", now: fixture.date))
        XCTAssertThrowsError(try IdentityLinkTicket.decode(deepLink: fixture.deepLink + "&t=duplicate", domain: fixture.ticket.audience, now: fixture.date))
        XCTAssertThrowsError(try IdentityLinkTicket.decode(deepLink: fixture.deepLink, domain: fixture.ticket.audience, now: fixture.date.addingTimeInterval(601)))
        var malicious = fixture.ticket; malicious.rendezvousURL = "https://evil.example/link/api"
        XCTAssertThrowsError(try malicious.validate(domain: fixture.ticket.audience, now: fixture.date))
        malicious = fixture.ticket; malicious.origin = "http://" + fixture.ticket.audience
        XCTAssertThrowsError(try malicious.validate(domain: fixture.ticket.audience, now: fixture.date))
        malicious = fixture.ticket; malicious.entityBinding.entityAnchorReference = "cell:///OtherPerson"
        XCTAssertThrowsError(try malicious.validate(domain: fixture.ticket.audience, now: fixture.date))
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try fixture.descriptor()
        let client = IdentityLinkClient(now: { fixture.date })
        do {
            _ = try await client.prepare(deepLink: fixture.deepLink, domain: fixture.ticket.audience, identityRoot: root,
                                         descriptor: descriptor, pinnedKey: "wrong")
            XCTFail("Wrong trust pin must fail")
        } catch { XCTAssertEqual(error as? OnboardingError, .trustChanged) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testTamperedApprovalCredentialAndVerifierContextAreRejected() throws {
        let fixture = try LinkFixture.load()
        var packages = [IdentityLinkCompletionPackage]()
        var package = fixture.package; package.approval.proof?.signature = Data(repeating: 0, count: 64); packages.append(package)
        package = fixture.package; package.sameEntityCredential.proof.signatureData = Data(repeating: 0, count: 64); packages.append(package)
        package = fixture.package; package.presentationChallenge = Data(repeating: 1, count: 32); packages.append(package)
        package = fixture.package; package.presentationDomain = "https://evil.example"; packages.append(package)
        package = fixture.package; package.completeURL = "https://evil.example/link/api/complete"; packages.append(package)
        package = fixture.package; package.approval.freshAuthEvidence = nil; packages.append(package)
        package = fixture.package; package.approval.approvedScopes = ["same_entity", "admin"]; packages.append(package)
        package = fixture.package; package.issuerIdentity.publicKey = fixture.request.newIdentity.publicKey; packages.append(package)
        package = fixture.package; package.approval.expiresAt = "2000-01-01T00:00:00Z"; packages.append(package)
        for package in packages {
            XCTAssertThrowsError(try IdentityLinkClient.validate(package: package, pending: fixture.pending, now: fixture.date))
        }
    }

    func testP256IssuerSupportsBothCompressedAndX963KeysWithoutAlgorithmConfusion() throws {
        let fixture = try LinkFixture.load()
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 3, count: 32))
        for publicKey in [key.publicKey.compressedRepresentation, key.publicKey.x963Representation] {
            var package = fixture.package
            package.issuerIdentity.algorithm = .ECDSA; package.issuerIdentity.curveType = .P256
            package.issuerIdentity.publicKey = publicKey
            package.approval.proof?.algorithm = .ECDSA; package.approval.proof?.curveType = .P256
            let approvalSignature = try key.signature(for: package.approval.canonicalPayloadData()).derRepresentation
            package.approval.proof?.signature = approvalSignature
            package.sameEntityCredential.issuer = try IdentityLinkClient.did(package.issuerIdentity)
            package.sameEntityCredential.proof.type = "EcdsaSecp256r1Signature2019"
            package.sameEntityCredential.proof.signatureData = try key.signature(for: IdentityLinkEncoding.unsignedVC(package.sameEntityCredential)).derRepresentation
            try IdentityLinkClient.validate(package: package, pending: fixture.pending, now: fixture.date)
            package.issuerIdentity.algorithm = .EdDSA
            XCTAssertThrowsError(try IdentityLinkClient.validate(package: package, pending: fixture.pending, now: fixture.date))
        }
    }

    func testHTTPFlowWithSyntheticOwnerApprovalPersistsSameKeyReceiptAndResolveProof() async throws {
        let fixture = try LinkFixture.load()
        let server = LinkHTTPFixture(fixture: fixture)
        LinkURLProtocol.server = server
        defer { LinkURLProtocol.server = nil }
        let session = testSession(); defer { session.invalidateAndCancel() }
        let client = IdentityLinkClient(testSession: session, now: { fixture.date })
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try fixture.descriptor()
        let starter = try await StarterIdentityStore(root: root).loadOrCreate(scaffoldDomain: fixture.ticket.audience)
        let pending = try await client.prepare(deepLink: fixture.deepLink, domain: fixture.ticket.audience, identityRoot: root,
                                               descriptor: descriptor, pinnedKey: descriptor.scaffold_admin_public_key)
        XCTAssertEqual(Base64URL.encode(pending.request.newIdentity.publicKey), starter.identity_public_key)
        let repeated = try await client.prepare(deepLink: fixture.deepLink, domain: fixture.ticket.audience, identityRoot: root,
                                                descriptor: descriptor, pinnedKey: descriptor.scaffold_admin_public_key)
        XCTAssertEqual(pending, repeated)
        let saved = try await client.loadProgress(domain: fixture.ticket.audience, identityRoot: root)
        XCTAssertEqual(saved?.pending, pending); XCTAssertEqual(saved?.hasCompletion, false)
        try await client.submit(pending)
        let firstPoll = try await client.poll(pending); XCTAssertNil(firstPoll)
        let secondPoll = try await client.poll(pending)
        let package = try XCTUnwrap(secondPoll)
        let receipt = try await client.complete(pending, package: package, identityRoot: root)
        let reload = try await IdentityLinkClient(now: { fixture.date }).loadReceipt(domain: fixture.ticket.audience, identityRoot: root)
        XCTAssertEqual(receipt, reload)
        var resolve = fixture.resolutionRequest; resolve.identity_public_key = starter.identity_public_key
        let proof = try await client.makeResolveProof(request: resolve, identityRoot: root)
        XCTAssertNotNil(proof)
        let finished = try await client.loadProgress(domain: fixture.ticket.audience, identityRoot: root)
        XCTAssertNil(finished)
        XCTAssertEqual(server.paths, ["/link/api/request", "/link/api/completion/" + pending.requestHash,
                                     "/link/api/completion/" + pending.requestHash, "/link/api/complete"])
        let persisted = try PrivateStateFiles.read(root.appendingPathComponent(fixture.ticket.audience + "/identity-link.json"))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("authenticatorData"))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("presentationChallenge"))
    }

    func testLostCompletionReplyRetriesExactPresentationWithoutNewKeyOrApproval() async throws {
        let fixture = try LinkFixture.load()
        let server = LinkHTTPFixture(fixture: fixture); server.failFirstCompletion = true
        LinkURLProtocol.server = server; defer { LinkURLProtocol.server = nil }
        let session = testSession(); defer { session.invalidateAndCancel() }
        let client = IdentityLinkClient(testSession: session, now: { fixture.date })
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try fixture.descriptor()
        let pending = try await client.prepare(deepLink: fixture.deepLink, domain: fixture.ticket.audience, identityRoot: root,
                                               descriptor: descriptor, pinnedKey: descriptor.scaffold_admin_public_key)
        try await client.submit(pending)
        _ = try await client.poll(pending)
        let ready = try await client.poll(pending); let package = try XCTUnwrap(ready)
        do { _ = try await client.complete(pending, package: package, identityRoot: root); XCTFail("Fixture must lose reply") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let progress = try await client.loadProgress(domain: fixture.ticket.audience, identityRoot: root)
        XCTAssertEqual(progress?.hasCompletion, true)
        let receipt = try await client.retryCompletion(domain: fixture.ticket.audience, identityRoot: root)
        XCTAssertEqual(receipt.identity, pending.request.newIdentity)
        XCTAssertEqual(server.completedBodies.count, 2)
        XCTAssertEqual(server.completedBodies[0], server.completedBodies[1])
    }

    func testLostSubmitReplyResubmitsIdenticalRequestAndResumesApproval() async throws {
        let fixture = try LinkFixture.load()
        let server = LinkHTTPFixture(fixture: fixture); server.failFirstSubmission = true
        LinkURLProtocol.server = server; defer { LinkURLProtocol.server = nil }
        let session = testSession(); defer { session.invalidateAndCancel() }
        let client = IdentityLinkClient(testSession: session, now: { fixture.date })
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try fixture.descriptor()
        let pending = try await client.prepare(deepLink: fixture.deepLink, domain: fixture.ticket.audience, identityRoot: root,
                                               descriptor: descriptor, pinnedKey: descriptor.scaffold_admin_public_key)
        do { try await client.submit(pending); XCTFail("Fixture must lose submit reply") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let progress = try await client.loadProgress(domain: fixture.ticket.audience, identityRoot: root)
        let retained = try XCTUnwrap(progress?.pending)
        try await client.submit(retained)
        XCTAssertEqual(server.submittedBodies.count, 2)
        XCTAssertEqual(server.submittedBodies[0], server.submittedBodies[1])
        _ = try await client.poll(retained)
        let package = try await client.poll(retained)
        XCTAssertNotNil(package)
    }

    func testRetainedCompletionCanRecoverAfterExpiryButCannotChangeVerifierOrHolder() throws {
        let fixture = try LinkFixture.load()
        try IdentityLinkClient.validateRetainedCompletion(fixture.envelope, pending: fixture.pending,
                                                          now: fixture.date.addingTimeInterval(900))
        var envelope = fixture.envelope; envelope.presentation.domain = "https://evil.example"
        XCTAssertThrowsError(try IdentityLinkClient.validateRetainedCompletion(envelope, pending: fixture.pending, now: fixture.date))
        envelope = fixture.envelope; envelope.expectedOrigin = "https://evil.example"
        XCTAssertThrowsError(try IdentityLinkClient.validateRetainedCompletion(envelope, pending: fixture.pending, now: fixture.date))
        envelope = fixture.envelope; envelope.presentation.proof.signatureData = Data(repeating: 0, count: 64)
        XCTAssertThrowsError(try IdentityLinkClient.validateRetainedCompletion(envelope, pending: fixture.pending, now: fixture.date))
    }

    func testCorruptPersistentIdentityNeverRegeneratesDomainSeed() async throws {
        let fixture = try LinkFixture.load()
        let client = IdentityLinkClient(now: { fixture.date })
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try fixture.descriptor()
        _ = try await client.prepare(deepLink: fixture.deepLink, domain: fixture.ticket.audience, identityRoot: root,
                                     descriptor: descriptor, pinnedKey: descriptor.scaffold_admin_public_key)
        let seedURL = root.appendingPathComponent(fixture.ticket.audience + "/keys/ed25519.seed")
        let original = try PrivateStateFiles.read(seedURL)
        let recordURL = root.appendingPathComponent(fixture.ticket.audience + "/identity-link.json")
        try PrivateStateFiles.write(Data("{}".utf8), to: recordURL)
        do {
            _ = try await client.prepare(deepLink: fixture.deepLink, domain: fixture.ticket.audience, identityRoot: root,
                                         descriptor: descriptor, pinnedKey: descriptor.scaffold_admin_public_key)
            XCTFail("Corrupt identity must stop")
        } catch { XCTAssertEqual(error as? IdentityLinkError, .recoveryRequired) }
        XCTAssertEqual(try PrivateStateFiles.read(seedURL), original)
    }

    func testReceiveTimeHTTPBodyLimitAndHTTPRedirectRejection() async throws {
        let fixture = try LinkFixture.load()
        let server = LinkHTTPFixture(fixture: fixture)
        LinkURLProtocol.server = server; defer { LinkURLProtocol.server = nil }
        let session = testSession(); defer { session.invalidateAndCancel() }
        let client = IdentityLinkClient(testSession: session, now: { fixture.date })
        server.overrideStatus = 302
        do { try await client.submit(fixture.pending); XCTFail("Redirect rejected") }
        catch { XCTAssertEqual(error as? IdentityLinkError, .httpStatus(302)) }
        server.overrideStatus = nil; server.oversized = true
        do { try await client.submit(fixture.pending); XCTFail("Oversized response rejected") }
        catch { XCTAssertEqual(error as? BoundedHTTPResponseError, .responseTooLarge) }
    }

    func testExplicitRestartArchivesExactExpiredCompletionAfter404Or410AndKeepsKeyAndUUID() async throws {
        for status in [404, 410] {
            let fixture = try LinkFixture.load()
            let clock = LinkTestClock(fixture.date)
            let server = LinkHTTPFixture(fixture: fixture); server.failFirstCompletion = true
            LinkURLProtocol.server = server
            defer { LinkURLProtocol.server = nil }
            let session = testSession(); defer { session.invalidateAndCancel() }
            let client = IdentityLinkClient(testSession: session, now: { clock.date })
            let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let pending = try await prepareAmbiguousCompletion(fixture: fixture, client: client, root: root)
            let stateURL = root.appendingPathComponent(fixture.ticket.audience + "/identity-link.json")
            let oldBytes = try PrivateStateFiles.read(stateURL)
            let seedURL = root.appendingPathComponent(fixture.ticket.audience + "/keys/ed25519.seed")
            let oldSeed = try PrivateStateFiles.read(seedURL)
            clock.date = fixture.date.addingTimeInterval(900)
            server.overrideStatus = status
            do { _ = try await client.retryCompletion(domain: fixture.ticket.audience, identityRoot: root); XCTFail("Expired missing attempt must offer explicit restart") }
            catch { XCTAssertEqual(error as? IdentityLinkError, .expiredCompletionUnavailable) }
            // A missing response does not automatically clear evidence or claim no effect.
            XCTAssertEqual(try PrivateStateFiles.read(stateURL), oldBytes)
            let archive = try await client.archiveExpiredCompletionForNewInvitation(domain: fixture.ticket.audience, identityRoot: root)
            XCTAssertEqual(try PrivateStateFiles.read(archive), oldBytes)
            XCTAssertEqual(archive.lastPathComponent, pending.requestHash + ".json")
            let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(try PrivateStateFiles.read(seedURL), oldSeed)
            let remaining = try await client.loadProgress(domain: fixture.ticket.audience, identityRoot: root)
            let receipt = try await client.loadReceipt(domain: fixture.ticket.audience, identityRoot: root)
            XCTAssertNil(remaining); XCTAssertNil(receipt)
            var newTicket = fixture.ticket
            newTicket.ticketID = "lt-" + UUID().uuidString.lowercased()
            newTicket.nonce = Data(repeating: 0x55, count: 32)
            newTicket.expiresAt = ISO8601DateFormatter().string(from: clock.date.addingTimeInterval(600))
            let invitation = "haven://identity-link?t=" + Base64URL.encode(try IdentityLinkEncoding.encode(newTicket))
            let descriptor = try fixture.descriptor()
            let callCount = server.paths.count
            let fresh = try await client.prepare(deepLink: invitation, domain: fixture.ticket.audience, identityRoot: root,
                                                 descriptor: descriptor, pinnedKey: descriptor.scaffold_admin_public_key)
            XCTAssertEqual(fresh.request.newIdentity, pending.request.newIdentity)
            XCTAssertEqual(try PrivateStateFiles.read(seedURL), oldSeed)
            XCTAssertNotEqual(fresh.requestHash, pending.requestHash)
            XCTAssertEqual(server.paths.count, callCount, "New preparation must not implicitly submit or approve")
            let freshProgress = try await client.loadProgress(domain: fixture.ticket.audience, identityRoot: root)
            XCTAssertEqual(freshProgress?.hasCompletion, false)
            let stillUnapproved = try await client.loadReceipt(domain: fixture.ticket.audience, identityRoot: root)
            XCTAssertNil(stillUnapproved)
            XCTAssertEqual(try PrivateStateFiles.read(archive), oldBytes)
            do { _ = try await client.archiveExpiredCompletionForNewInvitation(domain: fixture.ticket.audience, identityRoot: root); XCTFail("Permit must be one use") }
            catch { XCTAssertEqual(error as? IdentityLinkError, .recoveryRequired) }
        }
    }

    func testRestartRefusesAmbiguousServerFailureTimeoutAndFreshTicket() async throws {
        let fixture = try LinkFixture.load()
        let clock = LinkTestClock(fixture.date)
        let server = LinkHTTPFixture(fixture: fixture); server.failFirstCompletion = true
        LinkURLProtocol.server = server; defer { LinkURLProtocol.server = nil }
        let session = testSession(); defer { session.invalidateAndCancel() }
        let client = IdentityLinkClient(testSession: session, now: { clock.date })
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await prepareAmbiguousCompletion(fixture: fixture, client: client, root: root)
        let stateURL = root.appendingPathComponent(fixture.ticket.audience + "/identity-link.json")
        let before = try PrivateStateFiles.read(stateURL)
        clock.date = fixture.date.addingTimeInterval(900)
        server.overrideStatus = 503
        do { _ = try await client.retryCompletion(domain: fixture.ticket.audience, identityRoot: root); XCTFail("Fixture503") }
        catch { XCTAssertEqual(error as? IdentityLinkError, .httpStatus(503)) }
        do { _ = try await client.archiveExpiredCompletionForNewInvitation(domain: fixture.ticket.audience, identityRoot: root); XCTFail("503 cannot authorize restart") }
        catch { XCTAssertEqual(error as? IdentityLinkError, .recoveryRequired) }
        server.overrideStatus = nil; server.alwaysTimeoutCompletion = true
        do { _ = try await client.retryCompletion(domain: fixture.ticket.audience, identityRoot: root); XCTFail("Fixture timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        do { _ = try await client.archiveExpiredCompletionForNewInvitation(domain: fixture.ticket.audience, identityRoot: root); XCTFail("Timeout cannot authorize restart") }
        catch { XCTAssertEqual(error as? IdentityLinkError, .recoveryRequired) }
        clock.date = fixture.date.addingTimeInterval(100)
        server.overrideStatus = 404
        do { _ = try await client.retryCompletion(domain: fixture.ticket.audience, identityRoot: root); XCTFail("Fixture404 with fresh ticket") }
        catch { XCTAssertEqual(error as? IdentityLinkError, .httpStatus(404)) }
        do { _ = try await client.archiveExpiredCompletionForNewInvitation(domain: fixture.ticket.audience, identityRoot: root); XCTFail("Fresh ticket cannot authorize restart") }
        catch { XCTAssertEqual(error as? IdentityLinkError, .recoveryRequired) }
        XCTAssertEqual(try PrivateStateFiles.read(stateURL), before)
        XCTAssertFalse(PrivateStateFiles.exists(stateURL.deletingLastPathComponent().appendingPathComponent("identity-link-recovery")))
    }

    func testRestartPermitCannotBeInventedTransferredOrEraseChangedCompletedReceipt() async throws {
        let fixture = try LinkFixture.load()
        let clock = LinkTestClock(fixture.date)
        let server = LinkHTTPFixture(fixture: fixture); server.failFirstCompletion = true
        LinkURLProtocol.server = server; defer { LinkURLProtocol.server = nil }
        let session = testSession(); defer { session.invalidateAndCancel() }
        let client = IdentityLinkClient(testSession: session, now: { clock.date })
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let pending = try await prepareAmbiguousCompletion(fixture: fixture, client: client, root: root)
        clock.date = fixture.date.addingTimeInterval(900)
        do { _ = try await client.archiveExpiredCompletionForNewInvitation(domain: fixture.ticket.audience, identityRoot: root); XCTFail("No observed404/410") }
        catch { XCTAssertEqual(error as? IdentityLinkError, .recoveryRequired) }
        server.overrideStatus = 404
        do { _ = try await client.retryCompletion(domain: fixture.ticket.audience, identityRoot: root); XCTFail("Fixture404") }
        catch { XCTAssertEqual(error as? IdentityLinkError, .expiredCompletionUnavailable) }
        let another = IdentityLinkClient(testSession: session, now: { clock.date })
        do { _ = try await another.archiveExpiredCompletionForNewInvitation(domain: fixture.ticket.audience, identityRoot: root); XCTFail("Another client did not observe404/410") }
        catch { XCTAssertEqual(error as? IdentityLinkError, .recoveryRequired) }
        server.overrideStatus = 503
        do { _ = try await client.retryCompletion(domain: fixture.ticket.audience, identityRoot: root); XCTFail("Later ambiguous response invalidates old restart permit") }
        catch { XCTAssertEqual(error as? IdentityLinkError, .httpStatus(503)) }
        do { _ = try await client.archiveExpiredCompletionForNewInvitation(domain: fixture.ticket.audience, identityRoot: root); XCTFail("Stale permit must not survive a later retry") }
        catch { XCTAssertEqual(error as? IdentityLinkError, .recoveryRequired) }
        server.overrideStatus = 404
        do { _ = try await client.retryCompletion(domain: fixture.ticket.audience, identityRoot: root); XCTFail("Fixture404") }
        catch { XCTAssertEqual(error as? IdentityLinkError, .expiredCompletionUnavailable) }
        let stateURL = root.appendingPathComponent(fixture.ticket.audience + "/identity-link.json")
        var record = try JSONDecoder().decode(IdentityLinkLocalRecord.self, from: PrivateStateFiles.read(stateURL))
        record.receipt = IdentityLinkReceipt(domain: fixture.ticket.audience, identity: pending.request.newIdentity,
                                             evidenceReference: String(repeating: "a", count: 64), linkID: fixture.package.approval.approvalID)
        let changed = try IdentityLinkEncoding.encode(record)
        try PrivateStateFiles.write(changed, to: stateURL)
        do { _ = try await client.archiveExpiredCompletionForNewInvitation(domain: fixture.ticket.audience, identityRoot: root); XCTFail("A receipt arriving after failure must survive") }
        catch { XCTAssertEqual(error as? IdentityLinkError, .recoveryRequired) }
        XCTAssertEqual(try PrivateStateFiles.read(stateURL), changed)
        XCTAssertFalse(PrivateStateFiles.exists(stateURL.deletingLastPathComponent().appendingPathComponent("identity-link-recovery")))
    }

    private func prepareAmbiguousCompletion(fixture: LinkFixture, client: IdentityLinkClient,
                                            root: URL) async throws -> IdentityLinkPending {
        let descriptor = try fixture.descriptor()
        let pending = try await client.prepare(deepLink: fixture.deepLink, domain: fixture.ticket.audience, identityRoot: root,
                                               descriptor: descriptor, pinnedKey: descriptor.scaffold_admin_public_key)
        try await client.submit(pending)
        _ = try await client.poll(pending)
        let ready = try await client.poll(pending)
        let package = try XCTUnwrap(ready)
        do { _ = try await client.complete(pending, package: package, identityRoot: root); XCTFail("Fixture must lose first completion reply") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        return pending
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sprout-link-test-" + UUID().uuidString) }
    private func testSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LinkURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private struct LinkFixture: Decodable, Sendable {
    var now: TimeInterval
    var seedBase64URL: String
    var issuerSeedBase64URL: String
    var ticket: IdentityLinkTicket
    var deepLink: String
    var requestCanonicalBase64: String
    var request: IdentityLinkWire.IdentityEnrollmentRequest
    var requestHash: String
    var package: IdentityLinkCompletionPackage
    var presentationCanonicalBase64: String
    var envelope: IdentityLinkCompletionEnvelope
    var receipt: IdentityLinkReceipt
    var resolutionRequest: EntityResolutionRequest
    var resolveProof: PersonLinkProof
    var challengeCanonicalBase64: String
    var date: Date { Date(timeIntervalSince1970: now) }
    var pending: IdentityLinkPending {
        IdentityLinkPending(ticket: ticket, request: request, requestHash: requestHash,
                            controlWords: IdentityLinkWire.IdentityLinkSAS.words(requestHash: try! Base64URL.decode(requestHash)))
    }
    static func load() throws -> Self {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IdentityLink/identity-link-v1.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    func descriptor() throws -> ScaffoldAdminTrustRootDescriptor {
        try ResolverFixtureFactory.makeScaffoldTrustRootDescriptor(scaffoldDomain: ticket.audience,
            issuedAt: "2026-09-29T11:00:00Z", expiresAt: "2026-09-30T12:00:00Z")
    }
    func approvalPackage(request: IdentityLinkWire.IdentityEnrollmentRequest) throws -> IdentityLinkCompletionPackage {
        var package = self.package
        let hash = Hashing.sha256(try request.canonicalPayloadData())
        package.requestHash = Base64URL.encode(hash)
        package.approval.requestHash = hash
        package.approval.subjectIdentity = request.newIdentity
        package.approval.freshAuthEvidence?.challenge = hash
        let approvalSignature = try Base64URL.decode(Ed25519.signBase64URL(
            data: package.approval.canonicalPayloadData(), seedBase64URL: issuerSeedBase64URL))
        package.approval.proof?.signature = approvalSignature
        package.sameEntityCredential.credentialSubject.id = try IdentityLinkClient.did(request.newIdentity)
        package.sameEntityCredential.credentialSubject.linkedIdentity = request.newIdentity
        package.sameEntityCredential.credentialSubject.enrollmentRequestHash = hash
        package.sameEntityCredential.proof.signatureData = try Base64URL.decode(Ed25519.signBase64URL(
            data: IdentityLinkEncoding.unsignedVC(package.sameEntityCredential), seedBase64URL: issuerSeedBase64URL))
        return package
    }
}

private final class LinkHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    let fixture: LinkFixture
    private var request: IdentityLinkWire.IdentityEnrollmentRequest?
    private var polls = 0
    private var seen: [String] = []
    private var completions: [Data] = []
    private var submissions: [Data] = []
    var failFirstCompletion = false
    var alwaysTimeoutCompletion = false
    var failFirstSubmission = false
    var overrideStatus: Int?
    var oversized = false
    var paths: [String] { lock.withLock { seen } }
    var completedBodies: [Data] { lock.withLock { completions } }
    var submittedBodies: [Data] { lock.withLock { submissions } }
    init(fixture: LinkFixture) { self.fixture = fixture }
    func response(_ request: URLRequest) throws -> (Data, Int) {
        try lock.withLock {
            let path = try XCTUnwrap(request.url?.path); seen.append(path)
            XCTAssertEqual(request.url?.scheme, "https"); XCTAssertEqual(request.url?.host, fixture.ticket.audience)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie")); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if let overrideStatus { return (Data(), overrideStatus) }
            if oversized { return (Data(repeating: 0, count: 65_537), 200) }
            switch path {
            case "/link/api/request":
                struct Body: Decodable { let ticketID: String; let request: IdentityLinkWire.IdentityEnrollmentRequest }
                let body = try readBody(request)
                submissions.append(body)
                let submitted = try JSONDecoder().decode(Body.self, from: body)
                XCTAssertEqual(submitted.ticketID, fixture.ticket.ticketID)
                let hash = Hashing.sha256(try submitted.request.canonicalPayloadData())
                let pending = IdentityLinkPending(ticket: fixture.ticket, request: submitted.request,
                    requestHash: Base64URL.encode(hash), controlWords: IdentityLinkWire.IdentityLinkSAS.words(requestHash: hash))
                try IdentityLinkClient.validatePending(pending, now: fixture.date)
                if let original = self.request { XCTAssertEqual(original, submitted.request) }
                self.request = submitted.request
                if failFirstSubmission && submissions.count == 1 { throw URLError(.timedOut) }
                return (try JSONSerialization.data(withJSONObject: ["requestHash": pending.requestHash,
                    "sas": pending.controlWords, "completionURL": pending.completionURL]), 200)
            case let value where value.hasPrefix("/link/api/completion/"):
                polls += 1
                if polls == 1 { return (Data(), 202) }
                return (try IdentityLinkEncoding.encode(fixture.approvalPackage(request: XCTUnwrap(self.request))), 200)
            case "/link/api/complete":
                let data = try readBody(request); completions.append(data)
                let envelope = try JSONDecoder().decode(IdentityLinkCompletionEnvelope.self, from: data)
                XCTAssertEqual(envelope.request, self.request)
                XCTAssertTrue(envelope.requireFreshAuthEvidence)
                XCTAssertTrue(Ed25519.verify(data: try IdentityLinkEncoding.unsignedVC(envelope.presentation),
                    signature: envelope.presentation.proof.signatureData, publicKey: envelope.request.newIdentity.publicKey))
                if alwaysTimeoutCompletion || (failFirstCompletion && completions.count == 1) { throw URLError(.timedOut) }
                let approval = envelope.approval
                let record = IdentityLinkWire.IdentityLinkRecord(linkID: approval.approvalID,
                    entityBinding: approval.entityBinding, linkedIdentity: envelope.request.newIdentity,
                    approvedDomains: approval.approvedDomains, approvedIdentityContexts: approval.approvedIdentityContexts,
                    approvedScopes: approval.approvedScopes, issuerIdentityUUID: approval.issuerIdentityUUID,
                    issuerType: approval.issuerType, linkedAt: approval.createdAt)
                struct Reply: Encodable { var status = "completed"; let record: IdentityLinkWire.IdentityLinkRecord; let evidenceReference: String; let linkID: String }
                return (try IdentityLinkEncoding.encode(Reply(record: record, evidenceReference: String(repeating: "a", count: 64), linkID: record.linkID)), 200)
            default: throw URLError(.badURL)
            }
        }
    }
    private func readBody(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream); stream.open(); defer { stream.close() }
        var result = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count < 0 { throw URLError(.cannotDecodeContentData) }; if count == 0 { break }
            result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }
}

private final class LinkURLProtocol: URLProtocol {
    nonisolated(unsafe) static var server: LinkHTTPFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (data, status) = try XCTUnwrap(Self.server).response(request)
            let headers = ["Content-Type": "application/json", "Content-Length": String(data.count)]
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: headers))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class LinkTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var date: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
