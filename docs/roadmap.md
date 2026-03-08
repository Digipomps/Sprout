# Iterative Roadmap with Exit Criteria

## Direction
Sprout should remain a narrow bootstrap and distribution component. The implementation path assumes:
- no synthetic entity IDs
- no implicit linkage between identities
- no hidden porthole privilege transfer
- no broad self-updater in the bootstrap binary

## P0 (Implemented)
Scope:
- Contracts + schemas + OpenAPI + golden vectors.
- Crypto profile (JCS subset, Ed25519 verify/sign, strict base64url).
- Deterministic bootstrap state machine with explicit `ResolveEntity` and `IssuePortholeAccess`.
- Explicit `ScaffoldAdminIdentity`, `EntityLinkEvidence`, `EntityResolutionDecision`, `PortholeAccessContract`.
- Mock resolver/discovery integration.
- CLI commands + core docs.

Exit criteria:
- `swift test` green.
- Golden vectors hash/signature checks pass bit-for-bit.
- Negative bootstrap tests pass: signature failure, wrong domain, expired payload, missing bridge route, capability denial, unresolved entity, invalid entity evidence.
- No porthole contract issued without explicit entity resolution.
- No update action allowed without explicit policy grant.

## P1 (Implemented bridge / active next phase)
Scope:
- File-backed `EntityAnchorResolverAdapter`.
- Feature-flagged live `HavenResolverHTTPAdapter`.
- Resolver-signed `EntityInclusionProof`.
- Web/native porthole consumer descriptors.
- Actual `sprout-macos` client consuming web/native handoff.
- Separate `sprout-updater` binary.
- CI release bundle generation, checksum manifest, SPDX SBOM, optional GitHub attestation wiring and cosign keyless signing.
- Native Linux baseline for `sprout` + `sprout-updater` on Ubuntu 22.04 `x86_64`.

Exit criteria:
- Anchor-backed entity resolution tests pass.
- Live resolver HTTP integration tests pass.
- Web/native consumer tests pass.
- `sprout-macos` builds and consumes signed contracts.
- Release bundle can be built and verified locally.
- Linux CLI/updater bundle can be built and verified locally without Docker.
- `sprout` remains non-mutating; update actions stay in `sprout-updater`.

## P1 Next
Scope:
- Cross-device QR link invitation/response plus authoritative inclusion proof.
- Authoritative HAVEN resolver server implementation behind the existing client contract.
- Real iOS wrapper flows from `SproutCore`.
- Published signed artifacts for macOS + Linux CLI.
- Linux WSS transport parity if CLI/server runtime needs streaming bridge traffic.

Exit criteria:
- Interop tests pass across CLI <-> iOS <-> macOS for bootstrap and link flows.
- Resolver can consume authoritative HAVEN entity anchor state and return explicit inclusion decisions.
- Published signed artifacts verifiable from documented trust policy.
- Resolver integration tests pass against live/staging API.
- Linux transport parity status is explicit: either implemented or formally excluded from supported workflows.

## P2 (Planned)
Scope:
- TUF metadata and updater hardening.
- gRPC/HTTP2 and QUIC/HTTP3 adapter maturation.
- Optional hosted discovery service hardening and privacy controls.
- Full runtime interop matrix (desktop/tablet extensions).

Exit criteria:
- Updater enforces TUF metadata and rollback protections.
- Transport interop matrix complete for supported runtimes.
- Security validation completed for update/revocation incident scenarios.
