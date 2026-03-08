import Foundation

public struct UpdateArtifactGrant: Codable, Equatable, Sendable {
    public var name: String
    public var sha256_b64url: String
    public var semver: String

    public init(name: String, sha256_b64url: String, semver: String) {
        self.name = name
        self.sha256_b64url = sha256_b64url
        self.semver = semver
    }
}

public struct DeniedArtifactRule: Codable, Equatable, Sendable {
    public var name: String
    public var reason: String?

    public init(name: String, reason: String?) {
        self.name = name
        self.reason = reason
    }
}

public struct UpdateGrantPolicy: Codable, Equatable, Sendable {
    public var policy_id: String
    public var version: String
    public var allowed_artifacts: [UpdateArtifactGrant]
    public var denied_artifacts: [DeniedArtifactRule]?
    public var allowed_channels: [String]
    public var authorized_triggers: [String]
    public var auto_update_allowed: Bool
    public var revoked_triggers: [String]
    public var expires_at: String?

    public init(
        policy_id: String,
        version: String,
        allowed_artifacts: [UpdateArtifactGrant],
        denied_artifacts: [DeniedArtifactRule]? = nil,
        allowed_channels: [String],
        authorized_triggers: [String],
        auto_update_allowed: Bool,
        revoked_triggers: [String],
        expires_at: String?
    ) {
        self.policy_id = policy_id
        self.version = version
        self.allowed_artifacts = allowed_artifacts
        self.denied_artifacts = denied_artifacts
        self.allowed_channels = allowed_channels
        self.authorized_triggers = authorized_triggers
        self.auto_update_allowed = auto_update_allowed
        self.revoked_triggers = revoked_triggers
        self.expires_at = expires_at
    }
}

public struct UpdateRequest: Codable, Equatable, Sendable {
    public var artifact_name: String
    public var artifact_sha256_b64url: String
    public var artifact_semver: String
    public var channel: String
    public var trigger_identity: String
    public var is_automatic: Bool

    public init(
        artifact_name: String,
        artifact_sha256_b64url: String,
        artifact_semver: String,
        channel: String,
        trigger_identity: String,
        is_automatic: Bool
    ) {
        self.artifact_name = artifact_name
        self.artifact_sha256_b64url = artifact_sha256_b64url
        self.artifact_semver = artifact_semver
        self.channel = channel
        self.trigger_identity = trigger_identity
        self.is_automatic = is_automatic
    }
}

public enum UpdatePolicyDecision: Equatable, Sendable {
    case allow
    case deny(String)

    public var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

public enum UpdatePolicyEnforcer {
    public static func evaluate(
        request: UpdateRequest,
        policy: UpdateGrantPolicy,
        now: Date = Date()
    ) -> UpdatePolicyDecision {
        if let expires = policy.expires_at {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: expires), now >= date {
                return .deny("policy expired")
            }
        }

        if policy.revoked_triggers.contains(request.trigger_identity) {
            return .deny("trigger identity revoked")
        }

        if !policy.authorized_triggers.contains(request.trigger_identity) {
            return .deny("trigger identity is not explicitly authorized")
        }

        if !policy.allowed_channels.contains(request.channel) {
            return .deny("channel not granted")
        }

        if let deniedRule = policy.denied_artifacts?.first(where: { $0.name == request.artifact_name }) {
            return .deny(deniedRule.reason ?? "artifact explicitly denied")
        }

        if request.is_automatic && !policy.auto_update_allowed {
            return .deny("auto-update is not granted")
        }

        let match = policy.allowed_artifacts.contains { grant in
            grant.name == request.artifact_name &&
                grant.sha256_b64url == request.artifact_sha256_b64url &&
                grant.semver == request.artifact_semver
        }
        if !match {
            return .deny("artifact/hash/version not explicitly granted")
        }

        return .allow
    }
}
