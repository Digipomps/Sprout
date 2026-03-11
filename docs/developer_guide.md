# Developer Guide

## Repository layout
- `Packages/SproutCore`: bootstrap state machine, entity-link/admission evidence models, porthole consumers, schema validator, update policy.
- `Packages/SproutCrypto`: JCS, Ed25519, base64url, hashing.
- `Packages/SproutStorage`: audit log, local key store, sqlite cache.
- `Packages/SproutTransport`: channel interfaces + HTTPS/WSS adapters + gRPC/QUIC stubs.
- `Packages/SproutBridge`: descriptor validation, bridge manager, discovery client/mock server.
- `Packages/SproutResolverAdapter`: resolver protocol, scaffold admin trust-root descriptor, cross-scaffold continuity proof, entity admission request/contract, entity anchor snapshot, inclusion proof, scaffold admin identity, porthole access contract, mock and file-backed resolver adapters.
- `Packages/SproutAdminSupport`: operator helpers for Vapor vault inspection, signed scaffold trust-root generation, signed continuity proof generation and signed entity anchor snapshot/admission contract generation.
- `Packages/SproutEconomics`: RAU/IMU/ore units, pricing contracts/compiler, cost profiler, rollup ledger helpers, Stripe fee overlay.
- `Packages/SproutAppSupport`: reusable porthole client session logic and native runtime adapter/fallbacks for app consumers.
- `Apps/sprout-cli`: reference bootstrap executable.
- `Apps/sprout-admin`: separate operator executable for Vapor vault inspection and entity-anchor snapshot generation.
- `Apps/sprout-updater`: separate policy-gated updater/verification executable.
- `Apps/sprout-macos`: actual macOS consumer for signed web/native handoff artifacts.
- `Scripts/`: release bundle, SPDX SBOM and manifest generation.

## Build/test
macOS workspace:
```bash
swift build --product sprout
swift build --product sprout-admin
swift build --product sprout-updater
swift build --product sprout-macos
swift test
```

Linux baseline:
```bash
swift build --product sprout
swift build --product sprout-admin
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
3. load or fetch scaffold-admin trust root and make resolver/bridge trust explicit
4. present optional entity-link evidence or target-side admission evidence to the resolver
5. get an explicit entity resolution decision with signed inclusion proof
6. obtain a signed `PortholeAccessContract`
7. hand the contract off to a client-specific consumer

Sprout is not the main user client or full billing backend. Web, CLI and native bindings consume the handoff artifacts after bootstrap, while economics stays as explicit policy and measurement support.

## First-class artifacts in code
- `BootstrapIdentity`: identity only, no embedded `entity_id`
- `ScaffoldAdminTrustRootDescriptor`: signed scaffold trust root with resolver keys, bridge-owner keys and default bootstrap URLs
- `ScaffoldAdminIdentity`: explicit scaffold admin identity derived from a trust-root descriptor or validated bridge metadata
- `EntityLinkEvidence`: explicit proof material carried into resolver calls
- `CrossScaffoldEntityContinuityProof`: source-scaffold signed portability proof from one local entity to one target scaffold
- `EntityAdmissionRequest`: target-identity signed request binding a target identity to one exact continuity proof
- `EntityAdmissionContract`: target-scaffold signed local admission decision for one target identity and one target local entity
- `EntityAdmissionEvidence`: bootstrap wrapper for `EntityAdmissionContract` and optional continuity proof
- `EntityAnchorSnapshot`: signed projection of anchor state
- `EntityInclusionProof`: resolver-signed proof of membership in a specific entity
- `EntityResolutionDecision`: explicit resolved vs unresolved entity state
- `PortholeAccessContract`: signed, capability-bounded handoff for web/CLI/native portholes
- `WebPortholeBootstrapDescriptor`: web consumer output
- `NativePortholeBindingDescriptor`: native consumer output
- `PortholeClientSession`: macOS-side consumer session model for handoff artifacts
- `CloudBridgePricingContract`: resolver-consumed tariff contract with min deposit, rate cap and optional always-on escrow
- `CompiledCloudBridgePricingPlan`: resolver-enforced outcome of a pricing contract for a specific deposit and capability request
- `CloudBridgeSessionRecord`: measured per-session overhead record for pricing calibration
- `CloudBridgeRollupAggregator`: per `(wallet, cell, counterparty, minute)` rollup aggregator for ledger writes

## Key constraints in code
- No network action before explicit purpose/goal/interests are present.
- No synthetic `entity_id` generation in the client.
- No porthole access contract without explicit entity resolution.
- No inclusion proof accepted unless it matches domain, identity and scaffold admin key.
- No capability amplification between resolver capability decision and returned porthole contract.
- No pricing-based capability amplification: underfunding may only degrade or deny, never expand access.
- RAU is the only persisted accounting unit; IMU and ore are derived views.
- `sprout` never mutates installed binaries; update behavior is separated into `sprout-updater`.
- when present, `ScaffoldAdminTrustRootDescriptor` is the first trust input; bridge-owner equality is only a legacy fallback.

## Economics model
- `RAU` is the int64 source of truth in ledger, wallet and pricing enforcement.
- `IMU` and `ore` are conversion views only.
- Conversion constants are hardcoded in code:
  - `1 IMU = 1000 RAU`
  - `1 ore = 10_000 IMU = 10_000_000 RAU`
- Resolver-side pricing enforcement happens through optional fields on `PortholeAccessRequest`:
  - `declared_deposit_rau`
  - `pricing_contract`
- Resolver returns:
  - `declared_deposit_rau`
  - `pricing_plan`
- Underfunded behavior is explicit:
  - `deny`
  - `degrade` to a predeclared capability subset
- Rollups are the default ledger write shape, not per-micro-op writes.
- Cloudflare-style edge costs are modeled separately from generic session/message/audit fees.

## Economics CLI flows
Convert between accounting views:
```bash
.build/debug/sprout economics units --rau 10000000
```

Compile a pricing contract for a specific deposit:
```bash
.build/debug/sprout economics compile-contract \
  --contract TestVectors/cloud_bridge_pricing_contract.example.json \
  --deposit-rau 1500000 \
  --requested-capabilities cap.join,cap.discover
```

Simulate Stripe top-up pressure:
```bash
.build/debug/sprout economics stripe-sim \
  --topups-nok 20,50,100,300 \
  --daily-spend-nok 5
```

Suggest a session-minute tariff from measured records:
```bash
.build/debug/sprout economics suggest-rate \
  --records <session-records.json>
```

## CLI reference flows
Inspect the bootstrap plan before making network calls:
```bash
.build/debug/sprout bootstrap plan \
  --domain example.haven.local \
  --purpose bootstrap.join_scaffold \
  --goal "Join scaffold and register identity" \
  --interests haven.core.bootstrap,haven.core.bridge \
  --starter TestVectors/starter_auth_payload.signed.json \
  --resolved-entity entity_example_primary
```

`bootstrap plan` and `bootstrap join --plan-only` must remain side-effect free: no starter-intent fetch, no discovery query and no resolver calls.

Trust-root lookup order for `bootstrap join`:
- `--trust-root`
- `SPROUT_TRUST_ROOT_PATH`
- `.sprout/trust-roots/<domain>.json`
- `.sprout/scaffold_admin_trust_root.json`
- scaffold `well-known` trust-root descriptor when `purpose`, `goal` and `interests` are explicit

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

Create a target-side admission request from a source continuity proof:
```bash
.build/debug/sprout admission create-request \
  --continuity-proof <cross-scaffold-continuity-proof.json> \
  --domain target.example.haven.local
```

Bootstrap with target-side admission evidence:
```bash
.build/debug/sprout bootstrap join \
  --domain target.example.haven.local \
  --purpose bootstrap.join_scaffold \
  --goal "Continue into the target scaffold" \
  --interests haven.core.bootstrap,haven.core.identity \
  --starter .sprout/starters/target.example.haven.local.json \
  --catalog <signed-bridge-catalog.json> \
  --admission-contract <entity-admission-contract.json> \
  --continuity-proof <cross-scaffold-continuity-proof.json>
```

Starter auth lookup order for `bootstrap join`:
- `--starter`
- `SPROUT_STARTER_AUTH_PATH`
- `.sprout/starters/<domain>.json`
- `.sprout/starter_auth_payload.json`
- signed starter bootstrap intent fetched from the scaffold when `purpose`, `goal` and `interests` are explicit

Starter bootstrap intent endpoint resolution order:
- `--starter-bootstrap-url`
- `SPROUT_STARTER_BOOTSTRAP_URL`
- trust-root descriptor `starter_bootstrap_url`
- resolver origin + `/v1/resolver/starter-auth/intent`
- `https://<domain>/v1/resolver/starter-auth/intent`

Trust-root endpoint resolution order:
- `--trust-root-url`
- `SPROUT_TRUST_ROOT_URL`
- `https://<domain>/.well-known/haven-scaffold-admin-trust-root.json`

Auto-materialization flow in `bootstrap join`:
1. fetch `ScaffoldAdminTrustRootDescriptor` when no local trust root is present
2. pin resolver keys and bridge-owner keys from that descriptor
3. request `StarterBootstrapIntent` from the scaffold
4. load or create a local starter identity from `StarterIdentityStore`
5. sign a local `StarterAuthPayload`
6. write:
   - trust root to `.sprout/trust-roots/<domain>.json` unless `--trust-root-out` overrides it
   - starter payload to `.sprout/starters/<domain>.json` unless `--starter-out` overrides it

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

Inspect the Vapor vault on a scaffold host:
```bash
.build/debug/sprout-admin vapor-vault list-identities --vault-root /app/CellsContainer
```

Generate a signed entity anchor snapshot from a Vapor vault:
```bash
.build/debug/sprout-admin entity-anchor create-from-vapor-vault \
  --vault-root /app/CellsContainer \
  --identity-context Scaffold \
  --scaffold-domain staging.haven.digipomps.org \
  --entity-id entity_staging_demo \
  --subject-public-key <base64url-ed25519-pubkey> \
  --subject-domain staging.haven.digipomps.org \
  --out /app/CellsContainer/sprout/entity-anchor-snapshot.json
```

Generate a signed scaffold-admin trust-root descriptor from a Vapor vault:
```bash
.build/debug/sprout-admin scaffold-trust-root create-from-vapor-vault \
  --vault-root /app/CellsContainer \
  --identity-context Scaffold \
  --scaffold-domain staging.haven.digipomps.org \
  --out /app/CellsContainer/sprout/scaffold-admin-trust-root.json
```

Generate a source continuity proof from a Vapor vault:
```bash
.build/debug/sprout-admin continuity-proof create-from-vapor-vault \
  --vault-root /app/CellsContainer \
  --identity-context Scaffold \
  --source-scaffold-domain source.example.haven.local \
  --source-entity-id entity_source_primary \
  --source-identity-public-key <source-identity-pubkey> \
  --source-identity-domain source.example.haven.local \
  --target-scaffold-domain target.example.haven.local \
  --purpose bootstrap.join_scaffold \
  --goal "Continue the same person into target scaffold" \
  --interests haven.core.bootstrap,haven.core.identity
```

Generate a target admission contract from a Vapor vault:
```bash
.build/debug/sprout-admin admission-contract create-from-vapor-vault \
  --vault-root /app/CellsContainer \
  --identity-context Scaffold \
  --target-scaffold-domain target.example.haven.local \
  --target-entity-id entity_target_primary \
  --target-identity-public-key <target-identity-pubkey> \
  --target-identity-domain target.example.haven.local \
  --continuity-proof <cross-scaffold-continuity-proof.json> \
  --admission-request <entity-admission-request.json>
```

## Notes on current maturity
- `EntityAnchorResolverAdapter` is a file-backed P1 bridge, not the final live HAVEN resolver integration.
- `HavenResolverHTTPAdapter` is implemented and tested, but authoritative HAVEN server-side resolver routes are still external to this repo.
- staging now publishes a signed scaffold-admin trust root and `sprout` can consume it from `well-known`.
- `sprout-admin` is intentionally separate from `sprout`: it is an operator tool, not part of the minimal bootstrap binary trust surface.
- `--resolved-entity` remains available only for the mock resolver path.
- `sprout-updater` is intentionally narrow: it plans and verifies installs, but does not turn `sprout` into a self-updating binary.
- CI is configured for macOS and Ubuntu 22.04 and can attest build provenance and SBOM, but production key management and published trust roots are still environment-dependent.
- cross-scaffold continuity is now implemented as explicit source proof + target admission, not as a global entity model.
- a single person-level global entity across scaffolds remains an OPEN design/research question under HAVEN's anti-linkage constraints.
- Standard GitHub builds are self-contained and do not depend on the sibling `CellProtocol` repo.
- `sprout-macos` currently ships with a standalone fallback for native contracts. A deeper CellProtocol-native runtime should return only through an explicit, versioned integration path.
