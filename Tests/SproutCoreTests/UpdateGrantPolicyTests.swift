import XCTest
@testable import SproutCore

final class UpdateGrantPolicyTests: XCTestCase {
    func testDenyWhenArtifactIsNotGranted() {
        let policy = UpdateGrantPolicy(
            policy_id: "p1",
            version: "1.0",
            allowed_artifacts: [
                UpdateArtifactGrant(name: "sprout-cli", sha256_b64url: "abc", semver: "1.0.0")
            ],
            allowed_channels: ["stable"],
            authorized_triggers: ["key1"],
            auto_update_allowed: false,
            revoked_triggers: [],
            expires_at: nil
        )

        let request = UpdateRequest(
            artifact_name: "sprout-cli",
            artifact_sha256_b64url: "zzz",
            artifact_semver: "1.0.0",
            channel: "stable",
            trigger_identity: "key1",
            is_automatic: false
        )

        let decision = UpdatePolicyEnforcer.evaluate(request: request, policy: policy)
        XCTAssertEqual(decision, .deny("artifact/hash/version not explicitly granted"))
    }

    func testDenyWhenExplicitlyDenied() {
        let policy = UpdateGrantPolicy(
            policy_id: "p1",
            version: "1.0",
            allowed_artifacts: [
                UpdateArtifactGrant(name: "sprout-cli", sha256_b64url: "abc", semver: "1.0.0")
            ],
            denied_artifacts: [DeniedArtifactRule(name: "sprout-cli", reason: "incident freeze")],
            allowed_channels: ["stable"],
            authorized_triggers: ["key1"],
            auto_update_allowed: false,
            revoked_triggers: [],
            expires_at: nil
        )

        let request = UpdateRequest(
            artifact_name: "sprout-cli",
            artifact_sha256_b64url: "abc",
            artifact_semver: "1.0.0",
            channel: "stable",
            trigger_identity: "key1",
            is_automatic: false
        )

        let decision = UpdatePolicyEnforcer.evaluate(request: request, policy: policy)
        XCTAssertEqual(decision, .deny("incident freeze"))
    }

    func testAllowWhenAllGrantsMatch() {
        let policy = UpdateGrantPolicy(
            policy_id: "p1",
            version: "1.0",
            allowed_artifacts: [
                UpdateArtifactGrant(name: "sprout-cli", sha256_b64url: "abc", semver: "1.0.0")
            ],
            allowed_channels: ["stable"],
            authorized_triggers: ["key1"],
            auto_update_allowed: false,
            revoked_triggers: [],
            expires_at: nil
        )

        let request = UpdateRequest(
            artifact_name: "sprout-cli",
            artifact_sha256_b64url: "abc",
            artifact_semver: "1.0.0",
            channel: "stable",
            trigger_identity: "key1",
            is_automatic: false
        )

        let decision = UpdatePolicyEnforcer.evaluate(request: request, policy: policy)
        XCTAssertEqual(decision, .allow)
    }
}
