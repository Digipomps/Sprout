# Scaffold Admin Trust Root

Date: 2026-03-11

## Purpose

`ScaffoldAdminTrustRootDescriptor` is the explicit trust-root contract for a scaffold.

It separates:

- scaffold admin identity
- resolver issuer keys
- bridge owner keys

This removes the old implicit assumption that `bridge.owner_pubkey == scaffold admin key`.

## Contract

Implemented in:

- `Packages/SproutResolverAdapter/Sources/SproutResolverAdapter/ScaffoldAdminTrustRootDescriptor.swift`
- `Schemas/ScaffoldAdminTrustRootDescriptor.schema.json`

The descriptor is:

- canonical JSON
- Ed25519 signed
- domain scoped
- expiry bounded
- explicit about:
  - `scaffold_admin_public_key`
  - `resolver_public_keys`
  - `bridge_owner_public_keys`
  - `starter_bootstrap_url`
  - `bridge_discovery_url`
  - `resolver_base_url`
  - optional `software_catalog_url`

## Generator

Operator generation is implemented in:

- `Apps/sprout-admin/Sources/sprout-admin/main.swift`
- `Packages/SproutAdminSupport/Sources/SproutAdminSupport/ScaffoldTrustRootDescriptorBuilder.swift`

Reference command:

```bash
.build/debug/sprout-admin scaffold-trust-root create-from-vapor-vault \
  --vault-root /app/CellsContainer \
  --identity-context Scaffold \
  --scaffold-domain staging.haven.digipomps.org \
  --out /app/CellsContainer/sprout/scaffold-admin-trust-root.json
```

## Bootstrap use

`sprout bootstrap join` now supports:

- `--trust-root <file>`
- `--trust-root-url <https://domain/.well-known/haven-scaffold-admin-trust-root.json>`
- `--trust-root-out <file>`

Lookup and acquisition order:

1. `--trust-root`
2. `SPROUT_TRUST_ROOT_PATH`
3. `.sprout/trust-roots/<domain>.json`
4. `.sprout/scaffold_admin_trust_root.json`
5. `https://<domain>/.well-known/haven-scaffold-admin-trust-root.json`

When present, the trust root is used to:

- pin trusted resolver issuers for live HTTP resolver
- validate that the chosen bridge owner key is trusted
- derive `ScaffoldAdminIdentity` without reusing bridge-owner identity
- derive default resolver/discovery/starter-intent URLs
- derive the default signed executable catalog URL for software/scaffold discovery

## Verified on staging

Published URL:

- `https://staging.haven.digipomps.org/.well-known/haven-scaffold-admin-trust-root.json`

Verified on 2026-03-11:

- public `GET` returns `200 OK`
- `sprout verify` returns `ScaffoldAdminTrustRootDescriptor valid`
- `sprout bootstrap join` reaches `Done` on staging with:
  - no explicit `--trust-root`
  - no explicit `--resolver-base-url`
  - live starter bootstrap intent
  - live bridge discovery
  - live resolver
  - trust root loaded from `well-known`

Observed success path:

- `scaffold_trust_root_source.origin = "well-known-trust-root"`
- `starter_source.origin = "bootstrap-intent"`
- `resolver_mode = "live-http"`
- `entity_resolution_status = "resolved"`
- `resolved_entity_id = "entity_staging_demo"`

## Important boundary

Trust-root publication does not make every fresh starter identity resolvable.

A fresh starter identity still reaches `entityUnresolved(...)` until:

- the anchor snapshot contains that identity directly, or
- accepted entity-link evidence ties it to an anchored identity

This is correct behavior. The trust root hardens trust establishment; it does not bypass entity membership rules.
