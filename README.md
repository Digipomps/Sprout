# Sprout

Sprout is the HAVEN bootstrap and distribution component with explicit `Purpose/Goal`, domain-scoped identities, resolver-enforced contracts/capabilities, and policy-gated update handling.

## Status (2026-03-08)
- P0 is implemented: deterministic bootstrap state machine, JCS subset, Ed25519, strict base64url, schemas, OpenAPI, golden vectors and CLI reference flow.
- P1 bridge is implemented in-repo: `EntityAnchorResolverAdapter`, feature-flagged `HavenResolverHTTPAdapter`, resolver-signed `EntityInclusionProof`, `PortholeAccessContract` consumers for web/native descriptors, `sprout-macos`, separate `sprout-updater`, release bundle scripts and CI signing.
- Locally verified on 2026-03-08: `swift build --product sprout`, `swift build --product sprout-updater`, `swift build --product sprout-macos`, `swift test`, `zsh Scripts/build_release_bundle.sh /tmp/sprout-dist-verify`, `zsh Scripts/verify_release_bundle.sh /tmp/sprout-dist-verify`.
- GitHub CI on `main` is green for commit `55bd7e5` and the repo is now configured for self-contained Actions builds.
- GitHub release `v0.1.1` is published with signed CLI artifacts and checksum manifest.
- Still OPEN in the release scope of this repo: authoritative HAVEN server-side resolver routes, QR-based cross-device linking UX, iOS production wrapper, notarized macOS release flow, TUF hardening.

## Design boundary
`sprout` is intentionally narrow. It should:
- understand runtime context
- acquire or load a domain-scoped identity
- make scaffold admin trust explicit
- resolve the identity into an entity or stop explicitly
- obtain a signed porthole handoff artifact

It should not be the general-purpose client and should not mutate itself.

## Quickstart
Build and test:
```bash
swift build --product sprout
swift build --product sprout-updater
swift build --product sprout-macos
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

`sprout-macos` in the standalone GitHub build consumes `web` contracts directly and can inspect/copy signed `native` descriptors. Live CellProtocol-native runtime is reserved for a future explicit integration path and is not part of the default release artifact.

Build and verify a release bundle:
```bash
zsh Scripts/build_release_bundle.sh dist
zsh Scripts/sign_release_bundle.sh dist
zsh Scripts/verify_release_bundle.sh dist
```

## Key docs
- `docs/entity_bootstrap_and_porthole_access.md`
- `docs/update_hardening_strategy.md`
- `docs/developer_guide.md`
- `docs/user_guide.md`
- `docs/verification_checklist.md`
- `docs/github_repository_setup.md`
