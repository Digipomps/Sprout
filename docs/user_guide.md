# User Guide

## What Sprout does
Sprout bootstraps a HAVEN scaffold connection with explicit purpose/goal, signed metadata and strict policy checks. It is a bootstrap/distribution component, not the full client experience.

Sprout now does five things explicitly:
1. acquires a domain-scoped identity
2. makes scaffold admin identity explicit from signed bridge metadata
3. resolves the user into an entity, or stops with an explicit unresolved state
4. verifies a resolver-signed entity inclusion proof
5. obtains a signed `PortholeAccessContract` for web, CLI or native access

It does not try to be the wallet UI or the billing backend. Pricing is explicit contract/policy input to bootstrap and access, not hidden background logic.

## Safe startup path (CLI)
Mock/local path:
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

`sprout bootstrap plan` is the plan-first path and uses the same planner as `bootstrap join`.

Starter auth lookup order:
- `--starter`
- `SPROUT_STARTER_AUTH_PATH`
- `.sprout/starters/<domain>.json`
- `.sprout/starter_auth_payload.json`

Live discovery path:
```bash
.build/debug/sprout bootstrap join \
  --domain staging.haven.digipomps.org \
  --purpose bootstrap.join_scaffold \
  --goal "Join scaffold and request next scaffold recommendation" \
  --interests haven.core.bootstrap,haven.core.bridge \
  --starter <starter-auth-payload.json> \
  --enable-live-resolver \
  --resolver-base-url https://staging.haven.digipomps.org \
  --discovery-url https://staging.haven.digipomps.org/v1/bridges/query \
  --porthole cli
```

If `--catalog` is omitted, Sprout uses live bridge discovery. Endpoint resolution order:
- `--discovery-url`
- `SPROUT_DISCOVERY_URL`
- resolver origin + `/v1/bridges/query`
- `https://<domain>/v1/bridges/query`

Anchor-backed path:
```bash
.build/debug/sprout bootstrap join \
  --domain example.haven.local \
  --purpose bootstrap.join_scaffold \
  --goal "Join scaffold and register identity" \
  --interests haven.core.bootstrap,haven.core.bridge \
  --starter TestVectors/starter_auth_payload.signed.json \
  --catalog <signed-bridge-catalog.json> \
  --entity-anchor <entity-anchor-snapshot.json> \
  --entity-link <entity-link-contract.json> \
  --porthole web
```

Important:
- `--porthole web|cli|native` chooses the requested handoff type.
- `--entity-link <file>` provides explicit entity-link evidence.
- `--entity-anchor <file>` enables the file-backed anchor resolver path.
- `--resolved-entity <id>` is only for the mock resolver and local testing.
- `--pricing-contract <file>` attaches an explicit CloudBridge tariff contract to the access request.
- `--deposit-rau <int64>` declares the deposit that the resolver will evaluate against the tariff contract.

## Consume porthole contracts
Generate a web handoff descriptor:
```bash
.build/debug/sprout porthole web-bootstrap --contract <porthole-access-contract.json>
```

Generate a native binding descriptor:
```bash
.build/debug/sprout porthole native-spec --contract <porthole-access-contract.json>
```

Use the actual macOS client:
```bash
swift build --product sprout-macos
.build/debug/sprout-macos
```

`sprout-macos` now supports both:
- embedded web handoff from a signed `web` contract
- inspection/copy of a signed `native` contract descriptor in the standalone build

## Verify release bundles and update plans
Verify a local release bundle:
```bash
bash Scripts/build_release_bundle.sh dist
bash Scripts/sign_release_bundle.sh dist
bash Scripts/verify_release_bundle.sh dist
```

Verify a Linux release bundle:
```bash
bash Scripts/build_release_bundle.sh dist linux-x86_64
bash Scripts/verify_release_bundle.sh dist "" dist/SHA256SUMS-linux-x86_64.b64url
```

Use the live resolver path explicitly:
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
  --porthole web
```

Note:
- this repo contains the live resolver client path and tests
- the authoritative server-side resolver implementation is still an external deployment dependency
- standard GitHub/macOS release builds do not embed live `CellProtocol` native runtime
- native Linux scope is `sprout` + `sprout-updater`; full Linux WSS runtime is not part of the current baseline

## Economics commands
Convert accounting units:
```bash
.build/debug/sprout economics units --ore 200
```

Ask how a pricing contract will resolve for a given deposit:
```bash
.build/debug/sprout economics compile-contract \
  --contract TestVectors/cloud_bridge_pricing_contract.example.json \
  --deposit-rau 1500000 \
  --requested-capabilities cap.join,cap.discover
```

Simulate top-up pressure with default Stripe domestic card fees:
```bash
.build/debug/sprout economics stripe-sim \
  --topups-nok 20,50,100,300 \
  --daily-spend-nok 5
```

Key rules:
- RAU is the source of truth.
- IMU and ore are views only.
- If `deposit < min_deposit`, the resolver may only `deny` or apply the predeclared degraded capability set.
- Rollups aggregate usage before ledger writes, so Sprout does not write one event per micro-op.

Ask the updater if a specific install is allowed:
```bash
./dist/sprout-updater plan \
  --policy TestVectors/update_grant_policy.example.json \
  --artifact-path ./dist/sprout \
  --artifact-name sprout \
  --version 1.0.0 \
  --channel stable \
  --trigger contract:update-admin
```

## Verify signed files
```bash
.build/debug/sprout verify TestVectors/starter_auth_payload.signed.json
.build/debug/sprout verify TestVectors/bridge_descriptor.signed.json
.build/debug/sprout verify TestVectors/entity_link_contract.mutual.json
.build/debug/sprout verify TestVectors/porthole_access_contract.example.json --now 2026-02-26T08:03:00Z
```

## Trust model
- Trust only artifacts/contracts signed by authorized keys for your domain.
- A valid mutual `EntityLinkContract` is not enough on its own to prove entity membership.
- The resolver must return a valid `EntityInclusionProof` before Sprout continues to porthole access.
- `PortholeAccessContract` is the handoff boundary. Downstream web/CLI/native clients should use it as the access artifact.
- Updates are not performed by `sprout`. Use `sprout-updater` and explicit grants in policy.
- For Linux deployments, verify the platform-specific checksum file before installation. See `docs/linux_deployment.md`.
