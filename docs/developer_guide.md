# Developer Guide

## Repository layout
- `Packages/SproutCore`: bootstrap state machine, entity-link evidence model, porthole consumers, schema validator, update policy.
- `Packages/SproutCrypto`: JCS, Ed25519, base64url, hashing.
- `Packages/SproutStorage`: audit log, local key store, sqlite cache.
- `Packages/SproutTransport`: channel interfaces + HTTPS/WSS adapters + gRPC/QUIC stubs.
- `Packages/SproutBridge`: descriptor validation, bridge manager, discovery client/mock server.
- `Packages/SproutResolverAdapter`: resolver protocol, entity anchor snapshot, inclusion proof, scaffold admin identity, porthole access contract, mock and file-backed resolver adapters.
- `Packages/SproutAppSupport`: reusable porthole client session logic and native runtime adapter/fallbacks for app consumers.
- `Apps/sprout-cli`: reference bootstrap executable.
- `Apps/sprout-updater`: separate policy-gated updater/verification executable.
- `Apps/sprout-macos`: actual macOS consumer for signed web/native handoff artifacts.
- `Scripts/`: release bundle, SPDX SBOM and manifest generation.

## Build/test
macOS workspace:
```bash
swift build --product sprout
swift build --product sprout-updater
swift build --product sprout-macos
swift test
```

Linux baseline:
```bash
swift build --product sprout
swift build --product sprout-updater
swift test
```

## Linux baseline
- Supported native Linux target: Ubuntu 22.04 `x86_64`.
- No Docker is required for build or deployment.
- `swift-crypto` is an explicit package dependency so `SproutCrypto` can build on Linux.
- Current Linux release scope is `sprout` + `sprout-updater`.
- `sprout-macos` is not part of Linux scope.
- `WSSClient` still lacks Linux runtime support, so Linux release scope is bootstrap/update/verification first, not full transport parity.

## Current bootstrap model
Sprout is intentionally narrow. Its implemented responsibility is:
1. understand runtime and purpose/goal/interests
2. load or acquire a local domain-scoped identity
3. validate bridge metadata and make scaffold admin identity explicit
4. present optional entity-link evidence to the resolver
5. get an explicit entity resolution decision with signed inclusion proof
6. obtain a signed `PortholeAccessContract`
7. hand the contract off to a client-specific consumer

Sprout is not the main user client. Web, CLI and native bindings consume the handoff artifacts after bootstrap.

## First-class artifacts in code
- `BootstrapIdentity`: identity only, no embedded `entity_id`
- `ScaffoldAdminIdentity`: explicit scaffold trust root derived from validated bridge metadata
- `EntityLinkEvidence`: explicit proof material carried into resolver calls
- `EntityAnchorSnapshot`: signed projection of anchor state
- `EntityInclusionProof`: resolver-signed proof of membership in a specific entity
- `EntityResolutionDecision`: explicit resolved vs unresolved entity state
- `PortholeAccessContract`: signed, capability-bounded handoff for web/CLI/native portholes
- `WebPortholeBootstrapDescriptor`: web consumer output
- `NativePortholeBindingDescriptor`: native consumer output
- `PortholeClientSession`: macOS-side consumer session model for handoff artifacts

## Key constraints in code
- No network action before explicit purpose/goal/interests are present.
- No synthetic `entity_id` generation in the client.
- No porthole access contract without explicit entity resolution.
- No inclusion proof accepted unless it matches domain, identity and scaffold admin key.
- No capability amplification between resolver capability decision and returned porthole contract.
- `sprout` never mutates installed binaries; update behavior is separated into `sprout-updater`.

## CLI reference flows
Bootstrap with file-backed anchor resolver:
```bash
.build/debug/sprout bootstrap join \
  --domain example.haven.local \
  --purpose bootstrap.join_scaffold \
  --goal "Join scaffold and register identity" \
  --interests haven.core.bootstrap,haven.core.bridge \
  --starter TestVectors/starter_auth_payload.signed.json \
  --catalog <signed-bridge-catalog.json> \
  --entity-anchor <entity-anchor-snapshot.json> \
  --porthole native \
  --now 2026-02-26T08:01:00Z
```

Consume porthole contracts:
```bash
.build/debug/sprout porthole web-bootstrap --contract <porthole-access-contract.json>
.build/debug/sprout porthole native-spec --contract <porthole-access-contract.json>
```

Build a release bundle:
```bash
bash Scripts/build_release_bundle.sh dist
bash Scripts/sign_release_bundle.sh dist
bash Scripts/verify_release_bundle.sh dist
```

Build a Linux-suffixed bundle:
```bash
bash Scripts/build_release_bundle.sh dist linux-x86_64
bash Scripts/verify_release_bundle.sh dist "" dist/SHA256SUMS-linux-x86_64.b64url
```

## Notes on current maturity
- `EntityAnchorResolverAdapter` is a file-backed P1 bridge, not the final live HAVEN resolver integration.
- `HavenResolverHTTPAdapter` is implemented and tested, but authoritative HAVEN server-side resolver routes are still external to this repo.
- `--resolved-entity` remains available only for the mock resolver path.
- `sprout-updater` is intentionally narrow: it plans and verifies installs, but does not turn `sprout` into a self-updating binary.
- CI is configured for macOS and Ubuntu 22.04 and can attest build provenance and SBOM, but production key management and published trust roots are still environment-dependent.
- Standard GitHub builds are self-contained and do not depend on the sibling `CellProtocol` repo.
- `sprout-macos` currently ships with a standalone fallback for native contracts. A deeper CellProtocol-native runtime should return only through an explicit, versioned integration path.
