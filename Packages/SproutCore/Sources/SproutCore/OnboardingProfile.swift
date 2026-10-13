import Foundation
import SproutStorage

public enum OnboardingError: Error, Equatable {
    case invalidInput
    case recoveryRequired
    case trustChanged
    case unsafeEndpoint
    case invalidProof
    case trustDescriptorExpired
    case serviceUnavailable
    case paused
}

public enum OnboardingEntityIntent: String, Codable, Sendable {
    case newLocal = "new"
    case existing
}

public enum OnboardingOutcome: String, Codable, Sendable {
    case localOnly
    case awaitingApproval
    case identityVerified
}

/// Preferences and public references only. Never store invitations, proofs, tokens or a chat transcript here.
public struct OnboardingProfile: Codable, Equatable, Sendable {
    public var version = 1
    public var localIdentityPublicKey: String
    public var entityIntent: OnboardingEntityIntent?
    public var purpose: String?
    public var goal: String?
    public var interests: [String]?
    public var domain: String?
    public var trustedAdminKeys: [String: String] = [:]
    public var lastOutcome: OnboardingOutcome = .localOnly

    public var localDraftReference: String { "local-draft:\(localIdentityPublicKey)" }

    public init(localIdentityPublicKey: String) {
        self.localIdentityPublicKey = localIdentityPublicKey
    }

    public func validate() throws {
        guard version == 1, !localIdentityPublicKey.isEmpty,
              purpose.map(Self.validAnswer) ?? true, goal.map(Self.validAnswer) ?? true,
              interests.map({ !$0.isEmpty && $0.count <= 16 && $0.allSatisfy(Self.validAnswer) }) ?? true,
              domain.map({ (try? StarterIdentityStore.validateDomain($0)) == $0 }) ?? true,
              trustedAdminKeys.count <= 32,
              trustedAdminKeys.allSatisfy({ (try? StarterIdentityStore.validateDomain($0.key)) == $0.key && Self.validAnswer($0.value) }) else {
            throw OnboardingError.recoveryRequired
        }
    }

    public static func validAnswer(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 512 && !text.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}

public struct OnboardingProfileStore: Sendable {
    public static let localRealm = "local.sprout.invalid"
    public let root: URL
    public var identityRoot: URL { root.appendingPathComponent("identities", isDirectory: true) }
    private var profileURL: URL { root.appendingPathComponent("onboarding.json") }

    public init(root: URL) { self.root = root }

    /// Caller must hold PrivateStateLock(root) for the whole dialogue, including network requests.
    public func loadOrCreate() async throws -> OnboardingProfile {
        try PrivateStateFiles.validateDirectory(root)
        let identities = StarterIdentityStore(root: identityRoot)
        if PrivateStateFiles.exists(profileURL) {
            do {
                let profile = try JSONDecoder().decode(OnboardingProfile.self, from: PrivateStateFiles.read(profileURL))
                try profile.validate()
                let local = try await identities.load(scaffoldDomain: Self.localRealm)
                guard profile.localIdentityPublicKey == local.identity_public_key else { throw OnboardingError.recoveryRequired }
                return profile
            } catch {
                throw OnboardingError.recoveryRequired
            }
        }
        guard !PrivateStateFiles.exists(identityRoot),
              !PrivateStateFiles.exists(root.appendingPathComponent("scaffold-identities")) else {
            throw OnboardingError.recoveryRequired
        }
        let local = try await identities.loadOrCreate(scaffoldDomain: Self.localRealm)
        let profile = OnboardingProfile(localIdentityPublicKey: local.identity_public_key)
        try save(profile)
        return profile
    }

    public func save(_ profile: OnboardingProfile) throws {
        try profile.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try PrivateStateFiles.write(encoder.encode(profile), to: profileURL)
    }
}
