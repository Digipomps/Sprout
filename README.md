# Sprout

Sprout is the HAVEN bootstrap and distribution component with explicit `Purpose/Goal`, domain-scoped identities, resolver-enforced contracts/capabilities, and policy-gated update handling.

## Status (2026-03-08)
- P0 is implemented: deterministic bootstrap state machine, JCS subset, Ed25519, strict base64url, schemas, OpenAPI, golden vectors and CLI reference flow.
- P1 bridge is implemented in-repo: `EntityAnchorResolverAdapter`, feature-flagged `HavenResolverHTTPAdapter`, resolver-signed `EntityInclusionProof`, `PortholeAccessContract` consumers for web/native descriptors, `sprout-macos`, separate `sprout-updater`, release bundle scripts and CI signing.
- Native Linux baseline is now part of the repo scope for `sprout` and `sprout-updater`: Ubuntu 22.04 `x86_64`, no Docker required for build or deployment.
- Economics baseline is implemented: RAU is the storage unit, IMU and ore are derived views, resolver-enforced pricing contracts exist, rollups aggregate micro-usage, and session profiling can calibrate a session-minute tariff from observed process cost.
- Locally verified on 2026-03-08: `swift build --product sprout`, `swift build --product sprout-updater`, `swift build --product sprout-macos`, `swift test`, `bash Scripts/build_release_bundle.sh /tmp/sprout-dist-verify`, `bash Scripts/verify_release_bundle.sh /tmp/sprout-dist-verify`, `bash Scripts/build_release_bundle.sh /tmp/sprout-dist-linux linux-x86_64`, `bash Scripts/verify_release_bundle.sh /tmp/sprout-dist-linux "" /tmp/sprout-dist-linux/SHA256SUMS-linux-x86_64.b64url`.
- GitHub Actions is configured for self-contained macOS and Ubuntu 22.04 builds.
- GitHub release `v0.1.1` is published with signed CLI artifacts and checksum manifest.
- Still OPEN in the release scope of this repo: authoritative HAVEN server-side resolver routes, QR-based cross-device linking UX, iOS production wrapper, notarized macOS release flow, TUF hardening, and Linux WSS transport parity.

## Design boundary
`sprout` is intentionally narrow. It should:
- understand runtime context
- acquire or load a domain-scoped identity
- make scaffold admin trust explicit
- resolve the identity into an entity or stop explicitly
- obtain a signed porthole handoff artifact

It should not be the general-purpose client, billing backend or wallet UI, and it should not mutate itself.

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
  --starter <starter-auth-payload.json> \
  --discovery-url https://staging.haven.digipomps.org/v1/bridges/query \
  --enable-live-resolver \
  --resolver-base-url https://staging.haven.digipomps.org \
  --porthole cli
```

`sprout bootstrap plan` is now the first planning stage used by `bootstrap join`.

Starter auth lookup order:
- `--starter`
- `SPROUT_STARTER_AUTH_PATH`
- `.sprout/starters/<domain>.json`
- `.sprout/starter_auth_payload.json`

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

Live resolver path:
```bash
SPROUT_ENABLE_LIVE_RESOLVER=1 \
SPROUT_RESOLVER_BASE_URL=https://resolver.example.haven.local \
.build/debug/sprout bootstrap join \
  --domain example.haven.local \
  --purpose bootstrap.join_scaffold \
  --goal "Join scaffold and register identity" \
  --interests haven.core.bootstrap,haven.core.bridge \
  --starter TestVectors/starter_auth_payload.signed.json \
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
- `docs/economics_and_pricing.md`
- `docs/update_hardening_strategy.md`
- `docs/linux_deployment.md`
- `docs/developer_guide.md`
- `docs/user_guide.md`
- `docs/verification_checklist.md`
- `docs/github_repository_setup.md`
