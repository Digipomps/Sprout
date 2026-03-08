# Update Hardening Strategy

## Recommendation
Sprout should stay stripped down.

The safest distribution model is now implemented as:
- `sprout`: bootstrap/discovery/entity-resolution/porthole-handoff binary
- `sprout-updater`: separate policy-gated updater/verification binary

This reduces:
- attack surface in the bootstrap trust path
- privilege concentration
- updater abuse paths
- ambiguity around which binary is allowed to mutate installed artifacts

## Current implementation
Implemented now:
- `sprout update ...` only evaluates policy and never mutates binaries.
- `sprout-updater plan ...` produces an operator-applied install plan when policy allows it.
- `sprout-updater verify-bundle ...` verifies artifact hash against the selected `SHA256SUMS*.b64url` file.
- `Scripts/build_release_bundle.sh` and `Scripts/verify_release_bundle.sh` provide the local release/verification path.
- `Scripts/sign_release_bundle.sh` provides keyless cosign signing for release artifacts.
- CI builds both binaries separately and produces:
  - `release-manifest*.json`
  - `SHA256SUMS*.b64url`
  - `sprout*.spdx.json`
  - optional GitHub build provenance attestation
  - optional GitHub SBOM attestation
  - cosign keyless signatures
  - optional detached GPG signature for checksum file

## Preferred update policy by runtime

### CLI / server executable
Default:
- immutable signed artifact
- operator-managed replacement
- provenance + checksum verification
- no in-place self-update in `sprout`

If custom update is ever enabled:
- keep it in `sprout-updater` or installer path
- `UpdateGrantPolicy` stays default deny
- signed metadata + artifact verification are mandatory
- TUF in P2 before auto-update is considered

### iPhone app
- App Store only
- no custom updater
- `UpdateGrantPolicy` still exists for parity and audit reasoning

### macOS app
Preferred:
- App Store or notarized signed app bundle

If outside App Store:
- manual installer/update path in P1
- Sparkle only in P2 and only if grants explicitly allow it

### Linux CLI/server
Preferred:
- native Ubuntu 22.04 `x86_64` artifact
- operator-managed replacement after checksum/signature verification
- no Docker required for the baseline
- no claim of Linux WSS parity until transport support exists

## High-risk update failures to avoid
- bootstrap binary replaces itself without explicit grant
- updater shares same trust root as ordinary runtime traffic
- unsigned metadata chooses arbitrary artifact URL
- update channel broadens privileges implicitly
- rollback to vulnerable version

## Design rule
Treat updater as a separate trust boundary from bootstrap.

The bootstrap component should be able to say:
- who am I
- which domain am I in
- which scaffold admin key do I trust
- which entity do I resolve to
- which inclusion proof did I receive
- which porthole contract did I receive

It should not also hold broad authority to mutate itself unless an explicit, verifiable update policy says so.

## Practical operator flow
1. Build or download a release bundle.
2. Verify the checksum manifest and optional signature/provenance.
3. Run `sprout-updater verify-bundle`.
4. Run `sprout-updater plan` with the authoritative `UpdateGrantPolicy`.
5. Apply installation outside `sprout`.

## P2
See `docs/tuf_p2_plan.md` for the planned TUF metadata path.
