import Foundation
@testable import SproutCore
import SproutCrypto
import SproutResolverAdapter
import SproutStorage
import XCTest

@MainActor
final class OnboardingTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-onboarding-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func run(_ answers: [String], root: URL, service: TestOnboardingService,
                     enroll: OnboardingDialogue.EnrollmentHandler? = nil) async throws -> [String] {
        var pending = answers
        var output: [String] = []
        let dialogue = OnboardingDialogue(root: root, service: service, ask: { prompt in
            output.append(prompt)
            return pending.isEmpty ? nil : pending.removeFirst()
        }, say: { output.append($0) }, enroll: enroll)
        try await dialogue.run()
        XCTAssertTrue(pending.isEmpty, "Unexpected unused answers: \(pending)")
        return output
    }

    private func readProfile(_ root: URL) throws -> OnboardingProfile {
        try JSONDecoder().decode(OnboardingProfile.self, from: PrivateStateFiles.read(root.appendingPathComponent("onboarding.json")))
    }

    func testNoStorageOrNetworkWithoutConsentIncludingBlankAndEOF() async throws {
        for answers in [["nei"], ["", "nei"], []] as [[String]] {
            let root = root()
            let service = try TestOnboardingService()
            let output = try await run(answers, root: root, service: service)
            XCTAssertTrue(output.contains { $0.contains("Assistenten du selv bruker kan sende eller lagre") })
            XCTAssertFalse(output.contains { $0.contains("Ingen ekstern AI faar samtalen") })
            XCTAssertFalse(PrivateStateFiles.exists(root))
            let calls = await service.counts()
            XCTAssertEqual(calls, [0, 0])
        }
    }

    func testOfflineDraftDoesNotPretendToBeAnEntityAndResumesSameKey() async throws {
        let root = root()
        let service = try TestOnboardingService()
        let output = try await run(["ja", "ny", "", "", "", "senere", "ja"], root: root, service: service)
        let first = try readProfile(root)
        XCTAssertEqual(first.entityIntent, .newLocal)
        XCTAssertEqual(first.lastOutcome, .localOnly)
        XCTAssertTrue(output.contains { $0.contains("ikke en registrert Entity") })
        _ = try await run(["ja", "senere", "ja"], root: root, service: service)
        XCTAssertEqual(first.localIdentityPublicKey, try readProfile(root).localIdentityPublicKey)
        let calls = await service.counts()
        XCTAssertEqual(calls, [0, 0])
    }

    func testPauseResumesAtMissingAnswerAndCommandsDoNotBecomeAnswers() async throws {
        let root = root()
        let service = try TestOnboardingService()
        _ = try await run(["ja", "/help", "eksisterende", "/status", "/pause"], root: root, service: service)
        XCTAssertEqual(try readProfile(root).entityIntent, .existing)
        XCTAssertNil(try readProfile(root).goal)
        _ = try await run(["ja", "", "", "", "senere", "ja"], root: root, service: service)
        XCTAssertEqual(try readProfile(root).goal, "Koble denne maskinen til HAVEN og finne noedvendige scaffolds.")
        XCTAssertEqual(try readProfile(root).purpose, "bootstrap.join_scaffold")
        XCTAssertEqual(try readProfile(root).interests, ["haven.core.bootstrap"])
    }

    func testDecliningPublicDiscoveryPreventsEveryNetworkCall() async throws {
        let root = root()
        let service = try TestOnboardingService()
        _ = try await run(["ja", "ny", "", "", "", "example.haven.local", "ja", "nei"], root: root, service: service)
        let calls = await service.counts()
        XCTAssertEqual(calls, [0, 0])
        XCTAssertTrue(try readProfile(root).trustedAdminKeys.isEmpty)
    }

    func testMetadataConsentDoesNotAuthorizeIdentityDisclosure() async throws {
        let root = root()
        let service = try TestOnboardingService()
        _ = try await run(["ja", "ny", "", "", "", "example.haven.local", "ja", "ja", "ja", "nei"], root: root, service: service)
        let calls = await service.counts()
        XCTAssertEqual(calls, [1, 0])
        XCTAssertFalse(PrivateStateFiles.exists(root.appendingPathComponent("scaffold-identities")))
    }

    func testUnresolvedStateDoesNotRequestProofFilesAndNeedsFreshConsentOnResume() async throws {
        let root = root()
        let service = try TestOnboardingService()
        let output = try await run(["ja", "eksisterende", "", "", "", "example.haven.local", "ja", "ja", "ja", "ja"], root: root, service: service)
        XCTAssertEqual(try readProfile(root).lastOutcome, .awaitingApproval)
        XCTAssertTrue(output.contains { $0.contains("passkey-godkjenning") })
        _ = try await run(["ja", "ja", "nei"], root: root, service: service)
        let calls = await service.counts()
        XCTAssertEqual(calls, [1, 1])
        let json = try String(contentsOf: root.appendingPathComponent("onboarding.json"), encoding: .utf8)
        for forbidden in ["signature", "inclusion_proof", "seed", "nonce", "transcript", "bearer"] {
            XCTAssertFalse(json.contains(forbidden))
        }
    }

    func testEntityEnrollmentNeedsSeparateConsentAndRechecksResolution() async throws {
        for consent in ["nei", "ja"] {
            let root = root()
            let service = try TestOnboardingService(outcomes: [.awaitingApproval, .identityVerified])
            var enrolled = 0
            _ = try await run(["ja", "eksisterende", "", "", "", "example.haven.local", "ja", "ja", "ja", "ja", consent],
                root: root, service: service, enroll: { profile, descriptor, identityRoot in
                    enrolled += 1
                    XCTAssertEqual(profile.trustedAdminKeys[profile.domain!], descriptor.scaffold_admin_public_key)
                    XCTAssertEqual(identityRoot.lastPathComponent, "scaffold-identities")
                    return true
                })
            let calls = await service.counts()
            XCTAssertEqual(enrolled, consent == "ja" ? 1 : 0)
            XCTAssertEqual(calls, [1, consent == "ja" ? 2 : 1])
            XCTAssertEqual(try readProfile(root).lastOutcome, consent == "ja" ? .identityVerified : .awaitingApproval)
        }
    }

    func testIncompleteEnrollmentDoesNotClaimVerifiedIdentity() async throws {
        let root = root()
        let service = try TestOnboardingService(outcomes: [.awaitingApproval, .identityVerified])
        _ = try await run(["ja", "eksisterende", "", "", "", "example.haven.local", "ja", "ja", "ja", "ja", "ja"],
            root: root, service: service, enroll: { _, _, _ in false })
        let calls = await service.counts()
        XCTAssertEqual(calls, [1, 1])
        XCTAssertEqual(try readProfile(root).lastOutcome, .awaitingApproval)
    }

    func testPersonResolutionReceiptMustBindTheActualFreshRequest() throws {
        let descriptor = try ResolverFixtureFactory.makeScaffoldTrustRootDescriptor(expiresAt: "2099-01-01T00:00:00Z")
        let subject = try Ed25519.publicKeyBase64URL(fromSeedBase64URL: ResolverFixtureFactory.targetIdentitySeed)
        let entity = UUID().uuidString
        var sent = PersonLinkProof(evidenceReference: String(repeating: "a", count: 64), linkID: UUID().uuidString,
                                   challenge: Data("first-challenge".utf8), signature: Data("signature".utf8))
        let digest = Hashing.sha256Base64URL(try JCSCanonicalizer.canonicalize(JSONEncoder().encode(sent)))
        var proof = EntityInclusionProof(
            proof_id: "proof-person", scaffold_domain: "example.haven.local", entity_id: entity,
            subject_identity_public_key: subject, subject_domain: "example.haven.local",
            anchor_snapshot_id: "person-link-v1:\(sent.evidenceReference):\(sent.linkID):\(entity):\(digest)",
            anchor_snapshot_sha256_b64url: "snapshot-hash", anchor_admin_public_key: descriptor.scaffold_admin_public_key,
            issued_at: "2026-01-01T00:00:00Z", expires_at: "2099-01-01T00:00:00Z",
            issued_by: descriptor.resolver_public_keys[0], signature: .init(alg: "Ed25519", sig: ""))
        proof.signature.sig = try Ed25519.signBase64URL(data: proof.canonicalPayloadData(), seedBase64URL: ResolverFixtureFactory.resolverSeed)
        let result = EntityResolutionDecision(status: .resolved, entity_id: entity, inclusion_proof: proof)
        XCTAssertEqual(try OnboardingTrust.validateResolution(result, domain: "example.haven.local", publicKey: subject,
                        descriptor: descriptor, personLinkProof: sent), .identityVerified)
        XCTAssertThrowsError(try OnboardingTrust.validateResolution(result, domain: "example.haven.local", publicKey: subject,
                        descriptor: descriptor))
        sent.challenge = Data("second-challenge".utf8)
        XCTAssertThrowsError(try OnboardingTrust.validateResolution(result, domain: "example.haven.local", publicKey: subject,
                        descriptor: descriptor, personLinkProof: sent))
    }

    func testReviewCanEditAnswersWithoutReplacingIdentityOrTrust() async throws {
        let root = root()
        let service = try TestOnboardingService()
        _ = try await run(["ja", "ny", "", "", "", "example.haven.local", "ja", "ja", "ja", "nei"], root: root, service: service)
        let before = try readProfile(root)
        _ = try await run(["ja", "endre", "eksisterende", "Et annet maal", "", "", "senere", "ja"], root: root, service: service)
        let after = try readProfile(root)
        XCTAssertEqual(before.localIdentityPublicKey, after.localIdentityPublicKey)
        XCTAssertEqual(before.trustedAdminKeys, after.trustedAdminKeys)
        XCTAssertEqual(after.goal, "Et annet maal")
    }

    func testCorruptCheckpointIsNotTreatedAsFirstRun() async throws {
        let root = root()
        let service = try TestOnboardingService()
        _ = try await run(["ja", "/pause"], root: root, service: service)
        let seedURL = root.appendingPathComponent("identities/\(OnboardingProfileStore.localRealm)/keys/ed25519.seed")
        let seed = try Data(contentsOf: seedURL)
        try PrivateStateFiles.write(Data("corrupt".utf8), to: root.appendingPathComponent("onboarding.json"))
        do { _ = try await run(["ja"], root: root, service: service); XCTFail("Must fail closed") }
        catch { XCTAssertEqual(error as? OnboardingError, .recoveryRequired) }
        XCTAssertEqual(seed, try Data(contentsOf: seedURL))
    }

    func testDeletedCheckpointDoesNotRegenerateIdentity() async throws {
        let root = root()
        let service = try TestOnboardingService()
        _ = try await run(["ja", "/pause"], root: root, service: service)
        try FileManager.default.removeItem(at: root.appendingPathComponent("onboarding.json"))
        do { _ = try await run(["ja"], root: root, service: service); XCTFail("Missing checkpoint requires recovery") }
        catch { XCTAssertEqual(error as? OnboardingError, .recoveryRequired) }
    }

    func testKeyRotationAndCrossOriginEndpointsAreRejected() throws {
        let descriptor = try ResolverFixtureFactory.makeScaffoldTrustRootDescriptor(expiresAt: "2099-01-01T00:00:00Z")
        XCTAssertThrowsError(try OnboardingTrust.validate(descriptor, domain: "example.haven.local", pinnedKey: "old-key")) {
            XCTAssertEqual($0 as? OnboardingError, .trustChanged)
        }
        for url in ["http://example.haven.local/a", "https://evil.test/a", "https://example.haven.local:8443/a", "https://user:secret@example.haven.local/a", "https://example.haven.local/a?token=secret", "https://example.haven.local/a#token"] {
            XCTAssertThrowsError(try OnboardingTrust.endpoint(url, domain: "example.haven.local"))
        }
    }

    func testSignedProofMustMatchSubjectDomainEntityAndAnchor() throws {
        let descriptor = try ResolverFixtureFactory.makeScaffoldTrustRootDescriptor(expiresAt: "2099-01-01T00:00:00Z")
        let subject = try Ed25519.publicKeyBase64URL(fromSeedBase64URL: ResolverFixtureFactory.targetIdentitySeed)
        var proof = EntityInclusionProof(
            proof_id: "proof-1", scaffold_domain: "example.haven.local", entity_id: "entity-1",
            subject_identity_public_key: subject, subject_domain: "example.haven.local",
            anchor_snapshot_id: "snapshot-1", anchor_snapshot_sha256_b64url: "snapshot-hash",
            anchor_admin_public_key: descriptor.scaffold_admin_public_key,
            issued_at: "2026-01-01T00:00:00Z", expires_at: "2099-01-01T00:00:00Z",
            issued_by: descriptor.resolver_public_keys[0], signature: .init(alg: "Ed25519", sig: "")
        )
        let mutations: [(inout EntityInclusionProof) -> Void] = [
            { $0.subject_identity_public_key = "another-key" }, { $0.subject_domain = "other.test" },
            { $0.scaffold_domain = "other.test" }, { $0.entity_id = "entity-2" },
            { $0.anchor_admin_public_key = "other-admin" }, { $0.expires_at = "2000-01-01T00:00:00Z" },
            { $0.issued_at = "2098-01-01T00:00:00Z" }, { $0.evidence_contract_id = "unrequested-evidence" }
        ]
        for mutate in mutations {
            var invalid = proof
            mutate(&invalid)
            invalid.signature.sig = try Ed25519.signBase64URL(data: invalid.canonicalPayloadData(), seedBase64URL: ResolverFixtureFactory.resolverSeed)
            XCTAssertThrowsError(try OnboardingTrust.validateResolution(
                .init(status: .resolved, entity_id: "entity-1", inclusion_proof: invalid),
                domain: "example.haven.local", publicKey: subject, descriptor: descriptor
            ))
        }
        proof.signature.sig = try Ed25519.signBase64URL(data: proof.canonicalPayloadData(), seedBase64URL: ResolverFixtureFactory.resolverSeed)
        XCTAssertEqual(try OnboardingTrust.validateResolution(
            .init(status: .resolved, entity_id: "entity-1", inclusion_proof: proof),
            domain: "example.haven.local", publicKey: subject, descriptor: descriptor
        ), .identityVerified)
        proof.signature.sig = "forged"
        XCTAssertThrowsError(try OnboardingTrust.validateResolution(
            .init(status: .resolved, entity_id: "entity-1", inclusion_proof: proof),
            domain: "example.haven.local", publicKey: subject, descriptor: descriptor
        ))
    }
}

private actor TestOnboardingService: OnboardingService {
    private var discoveries = 0
    private var resolutions = 0
    private let descriptor: ScaffoldAdminTrustRootDescriptor
    private let outcomes: [OnboardingOutcome]

    init(outcomes: [OnboardingOutcome] = [.awaitingApproval]) throws {
        self.outcomes = outcomes
        descriptor = try ResolverFixtureFactory.makeScaffoldTrustRootDescriptor(expiresAt: "2099-01-01T00:00:00Z")
    }

    func counts() -> [Int] { [discoveries, resolutions] }

    func discover(domain: String) async throws -> ScaffoldAdminTrustRootDescriptor {
        discoveries += 1
        return descriptor
    }

    func resolve(profile: OnboardingProfile, descriptor: ScaffoldAdminTrustRootDescriptor,
                 identityRoot: URL) async throws -> OnboardingOutcome {
        resolutions += 1
        return outcomes[min(resolutions - 1, outcomes.count - 1)]
    }
}
