# Sprout

Current scaffold installation contract: [purpose-driven CLI installation](docs/Scaffold_Installation.md).
Earlier integration evidence: [2026-09-18 validation](docs/Production_Integration_2026-09-18.md).

Sprout is the HAVEN bootstrap and distribution component with explicit `Purpose/Goal`, domain-scoped identities, resolver-enforced contracts/capabilities, and policy-gated update handling.

## Terminal Onboarding (2026-09-11)

Run `sprout` without arguments, or `sprout onboard`, for a resumable terminal
dialogue. No invitation/proof files, pasted credentials, or external AI account
are needed by this dialogue. `sprout onboard --help` lists optional initial
values. `/help`, `/status`, and `/pause` work at every prompt.

Personal onboarding supports invitation/passkey enrollment and request-bound
Entity proof verification. A local draft still grants no remote rights; channel
startup remains subject to bridge, Agreement and Grant enforcement. See
[portable IdentityLink](docs/Identity_Link_CLI_Interop_2026-09-29.md).

For the **scaffold administrator**, run `sprout scaffold` or
`sprout onboard --role scaffoldadmin`. Choose purposes from a signed catalog;
Sprout resolves required artifacts and dependencies, verifies the publisher and
immutable OCI digests, downloads images through Docker and writes private
installation receipts. `sprout scaffold plan` previews the selection and
`sprout scaffold status` verifies installed images. Images are reported as
`installed-not-started`; first-owner/vault provisioning and service activation
remain distinct steps. No Mac app is launched by this flow.

The CLI itself remains portable on Linux and macOS; only OCI scaffold
installation requires Docker. Registry access and an actually published v1.1
catalog are prerequisites. No catalog availability or live enrollment is inferred
from a successful health check. See [installation contract and current limits](docs/Scaffold_Installation.md).

`sprout doctor --json` checks local platform and ephemeral signing without
reading stored identities. Static Linux CLI candidates have executed successfully
on Hetzner. An uncommitted/test-installed candidate is not a new signed release.

## Historical Status (2026-03-11)
- P0 is implemented: deterministic bootstrap state machine, JCS subset, Ed25519, strict base64url, schemas, OpenAPI, golden vectors and CLI reference flow.
- P1 bridge is implemented in-repo: `EntityAnchorResolverAdapter`, feature-flagged `HavenResolverHTTPAdapter`, resolver-signed `EntityInclusionProof`, `PortholeAccessContract` consumers for web/native descriptors, `sprout-macos`, separate `sprout-updater`, release bundle scripts and CI signing.
- Native Linux baseline is now part of the repo scope for `sprout` and `sprout-updater`: Ubuntu 22.04 `x86_64`, no Docker required for build or deployment.
- Economics baseline is implemented: RAU is the storage unit, IMU and ore are derived views, resolver-enforced pricing contracts exist, rollups aggregate micro-usage, and session profiling can calibrate a session-minute tariff from observed process cost.
- Cross-scaffold entity continuity baseline is implemented: source continuity proof, target admission request, target admission contract and bootstrap-side admission evidence are now first-class contracts.
- Scaffold-owner identity bootstrap now exists in `sprout`: `owner init/show/list` creates and inspects a local domain-scoped owner identity with `identity_context = Scaffold`, separate from starter/user and federation-contact identities.
- Executable distribution discovery now has a signed `ScaffoldExecutableCatalog`: scaffolds can publish compiled/signed scaffold artifacts such as CellScaffold, and `sprout` can fetch, verify and select an artifact without installing it.
- Locally verified on 2026-03-08: `swift build --product sprout`, `swift build --product sprout-updater`, `swift build --product sprout-macos`, `swift test`, `bash Scripts/build_release_bundle.sh /tmp/sprout-dist-verify`, `bash Scripts/verify_release_bundle.sh /tmp/sprout-dist-verify`, `bash Scripts/build_release_bundle.sh /tmp/sprout-dist-linux linux-x86_64`, `bash Scripts/verify_release_bundle.sh /tmp/sprout-dist-linux "" /tmp/sprout-dist-linux/SHA256SUMS-linux-x86_64.b64url`.
- GitHub Actions is configured for self-contained macOS and Ubuntu 22.04 builds.
- GitHub release `v0.1.1` is published with signed CLI artifacts and checksum manifest.
- Still OPEN in the release scope of this repo: authoritative HAVEN server-side resolver routes, QR-based cross-device linking UX, iOS production wrapper, notarized macOS release flow, TUF hardening, and Linux WSS transport parity.
- Still OPEN in the identity model: whether HAVEN should ever model a single global person-level entity across scaffolds; current implementation stays scaffold-local and explicit.

## Design boundary
`sprout` is intentionally narrow. It should:
- understand runtime context
- acquire or load a local scaffold-owner identity when this runtime owns a scaffold
- acquire or load a domain-scoped identity
- make scaffold admin trust explicit
- resolve the identity into an entity or stop explicitly
- obtain a signed porthole handoff artifact

It should not be the general-purpose client, billing backend or wallet UI, and it should not mutate itself.

For cross-scaffold onboarding, `sprout` now supports explicit continuity between scaffold-local entities:
- source scaffold issues `CrossScaffoldEntityContinuityProof`
- target identity signs `EntityAdmissionRequest`
- target scaffold issues `EntityAdmissionContract`
- bootstrap consumes that admission contract as evidence

This is deliberately not a global identity system.

## Quickstart
Build and test:
```bash
swift build --product sprout
swift build --product sprout-updater
swift build --product sprout-macos
swift test
```

On Linux, the supported baseline is the CLI/updater pair:
```bash
swift build --product sprout
swift build --product sprout-updater
swift test
```

Verify signed fixtures:
```bash
.build/debug/sprout verify TestVectors/starter_auth_payload.signed.json
.build/debug/sprout verify TestVectors/bridge_descriptor.signed.json
.build/debug/sprout verify TestVectors/entity_link_contract.mutual.json
.build/debug/sprout verify TestVectors/porthole_access_contract.example.json --now 2026-02-26T08:03:00Z
```

Initialize or inspect a local scaffold-owner identity:
```bash
.build/debug/sprout owner init \
  --domain local.haven.test \
  --display-name "Local owner"

.build/debug/sprout owner show --domain local.haven.test

.build/debug/sprout owner trust-root --domain local.haven.test
```

Sign, verify and select a scaffold executable catalog:
```bash
.build/debug/sprout software sign-catalog \
  --domain local.haven.test \
  --unsigned unsigned-executable-catalog.json \
  --out signed-executable-catalog.json

.build/debug/sprout software verify \
  --catalog signed-executable-catalog.json \
  --trust-root .sprout/trust-roots/local.haven.test.json

.build/debug/sprout software select \
  --catalog signed-executable-catalog.json \
  --kind cellscaffold \
  --platform linux-x86_64 \
  --channel stable
```

Mock bootstrap path:
```bash
.build/debug/sprout bootstrap plan \
  --domain example.haven.local \
  --purpose bootstrap.join_scaffold \
  --goal "Join scaffold and register identity" \
  --interests haven.core.bootstrap,haven.core.bridge \
  --starter TestVectors/starter_auth_payload.signed.json \
  --resolved-entity entity_example_primary

.build/debug/sprout bootstrap join \
  --domain example.haven.local \
  --purpose bootstrap.join_scaffold \
  --goal "Join scaffold and register identity" \
  --interests haven.core.bootstrap,haven.core.bridge \
  --starter TestVectors/starter_auth_payload.signed.json \
  --catalog TestVectors/bridge_descriptor.signed.json \
  --resolved-entity entity_example_primary \
  --porthole cli \
  --now 2026-02-26T08:01:00Z
```

Live discovery path:
```bash
.build/debug/sprout bootstrap join \
  --domain staging.haven.digipomps.org \
  --purpose bootstrap.join_scaffold \
  --goal "Join scaffold and request next scaffold recommendation" \
  --interests haven.core.bootstrap,haven.core.bridge \
  --discovery-url https://staging.haven.digipomps.org/v1/bridges/query \
  --enable-live-resolver \
  --resolver-base-url https://staging.haven.digipomps.org \
  --porthole cli
```

`sprout bootstrap plan` is now the first planning stage used by `bootstrap join`.
`sprout bootstrap plan` and `sprout bootstrap join --plan-only` do not perform bootstrap network calls.

Starter auth lookup and acquisition order:
- `--starter`
- `SPROUT_STARTER_AUTH_PATH`
- `.sprout/starters/<domain>.json`
- `.sprout/starter_auth_payload.json`
- signed starter bootstrap intent fetched from the scaffold when `purpose`, `goal` and `interests` are explicit

Starter bootstrap intent endpoint resolution order:
- `--starter-bootstrap-url`
- `SPROUT_STARTER_BOOTSTRAP_URL`
- resolver origin + `/v1/resolver/starter-auth/intent`
- `https://<domain>/v1/resolver/starter-auth/intent`

When intent bootstrap is used, `sprout`:
- requests a short-lived signed bootstrap intent from the scaffold
- creates or reuses a local starter identity under `.sprout/starter-identities`
- materializes a signed `StarterAuthPayload`
- caches it at `.sprout/starters/<domain>.json` unless `--starter-out` overrides the path

If `--catalog` is omitted, `sprout` uses live bridge discovery. Endpoint resolution order:
- `--discovery-url`
- `SPROUT_DISCOVERY_URL`
- resolver origin + `/v1/bridges/query`
- `https://<domain>/v1/bridges/query`

Anchor-backed bootstrap path:
```bash
.build/debug/sprout bootstrap join \
  --domain example.haven.local \
  --purpose bootstrap.join_scaffold \
  --goal "Join scaffold and register identity" \
  --interests haven.core.bootstrap,haven.core.bridge \
  --starter TestVectors/starter_auth_payload.signed.json \
  --catalog TestVectors/bridge_descriptor.signed.json \
  --entity-anchor <entity-anchor-snapshot.json> \
  --entity-link <entity-link-contract.json> \
  --porthole web \
  --now 2026-02-26T08:01:00Z
```

Cross-scaffold continuity path:
```bash
.build/debug/sprout admission create-request \
  --continuity-proof <cross-scaffold-continuity-proof.json> \
  --domain target.example.haven.local

.build/debug/sprout bootstrap join \
  --domain target.example.haven.local \
  --purpose bootstrap.join_scaffold \
  --goal "Continue into target scaffold" \
  --interests haven.core.bootstrap,haven.core.identity \
  --starter .sprout/starters/target.example.haven.local.json \
  --catalog <signed-bridge-catalog.json> \
  --admission-contract <entity-admission-contract.json> \
  --continuity-proof <cross-scaffold-continuity-proof.json>
```

Live resolver path:
```bash
SPROUT_ENABLE_LIVE_RESOLVER=1 \
SPROUT_RESOLVER_BASE_URL=https://resolver.example.haven.local \
.build/debug/sprout bootstrap join \
  --domain example.haven.local \
  --purpose bootstrap.join_scaffold \
  --goal "Join scaffold and register identity" \
  --interests haven.core.bootstrap,haven.core.bridge \
  --catalog TestVectors/bridge_descriptor.signed.json \
  --enable-live-resolver \
  --trusted-resolver-key <resolver-pubkey> \
  --porthole web \
  --now 2026-02-26T08:01:00Z
```

Consume signed porthole contracts:
```bash
.build/debug/sprout porthole web-bootstrap --contract <porthole-access-contract.json>
.build/debug/sprout porthole native-spec --contract <porthole-access-contract.json>
.build/debug/sprout-macos
```

Inspect and calibrate pricing:
```bash
.build/debug/sprout economics units --ore 200
.build/debug/sprout economics compile-contract --contract TestVectors/cloud_bridge_pricing_contract.example.json --deposit-rau 1500000 --requested-capabilities cap.join,cap.discover
.build/debug/sprout economics stripe-sim --topups-nok 20,50,100,300 --daily-spend-nok 5
.build/debug/sprout economics suggest-rate --records <session-records.json>
```

`sprout-macos` in the standalone GitHub build consumes `web` contracts directly and can inspect/copy signed `native` descriptors. Live CellProtocol-native runtime is reserved for a future explicit integration path and is not part of the default release artifact.

Build and verify a release bundle:
```bash
bash Scripts/build_release_bundle.sh dist
bash Scripts/sign_release_bundle.sh dist
bash Scripts/verify_release_bundle.sh dist
```

Build a Linux-suffixed release bundle locally:
```bash
bash Scripts/build_release_bundle.sh dist linux-x86_64
bash Scripts/verify_release_bundle.sh dist "" dist/SHA256SUMS-linux-x86_64.b64url
```

## Key docs
- `docs/entity_bootstrap_and_porthole_access.md`
- `docs/cross_scaffold_entity_continuity.md`
- `docs/economics_and_pricing.md`
- `docs/update_hardening_strategy.md`
- `docs/executable_catalog_distribution.md`
- `docs/linux_deployment.md`
- `docs/developer_guide.md`
- `docs/user_guide.md`
- `OpenAPI/resolver.openapi.yaml`
- `docs/verification_checklist.md`
- `docs/github_repository_setup.md`
