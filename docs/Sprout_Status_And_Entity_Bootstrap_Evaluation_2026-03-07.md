# Sprout Status And Entity Bootstrap Evaluation (2026-03-07)

## Summary

Sprout has a useful P0 kernel:

- deterministic bootstrap state machine
- explicit Purpose/Goal gating before network discovery
- signed bootstrap payloads and bridge descriptors
- schema coverage and negative-path tests
- deny-by-default update policy evaluation

Sprout does not yet solve the core problem described for production:

- it does not resolve a real HAVEN Entity
- it does not yet model scaffold admin identity as a first-class trust root
- it does not yet provide resolver-enforced proof that multiple identities belong to the same Entity
- it does not yet implement a minimally vulnerable update channel

The strongest direction is to keep Sprout small and security-focused:

- understand runtime and security environment
- acquire or create local user identity
- discover and verify scaffold admin trust root
- collect explicit Purpose/Goal
- present or package entity-link evidence
- request capabilities and bootstrap the user's Porthole
- hand off to web, CLI, or native Porthole clients

Sprout should not become a broad application shell, editor, browser runtime, or rich client.

## Current Status

### Implemented

- `SproutBootstrapStateMachine` runs the core P0 flow.
- `StarterAuthPayload`, `BridgeDescriptor`, `EntityLinkContract`, and `UpdateGrantPolicy` exist as contracts.
- Bridge discovery exists as offline catalog and minimal HTTP client.
- Resolver integration exists as a mock adapter with allow/deny scenarios.
- CLI supports bootstrap, verify, link import/export, bridge list, and update policy checks.
- Test suite is green for current P0 scope.

### Not Implemented

- real resolver integration
- real discovery service with privacy-preserving authentication policy
- real Apple keystore integration in Sprout
- secure cross-device entity-link protocol tied to EntityAnchor or resolver policy
- real updater, artifact signature verification, provenance enforcement, or TUF
- full Porthole handoff model across web, CLI, and native clients

## Main Findings

### 1. Sprout does not yet find the user's Entity

The CLI bootstrap path currently creates a synthetic `entity_id` from the public key prefix instead of resolving an actual HAVEN Entity context.

Consequence:

- Sprout currently bootstraps identity, not entity presence.
- This is insufficient for "find my HAVEN entity and connect me to it securely".

### 2. Entity linking is only cryptographic co-signing today

`EntityLinkContract` proves that two keys signed the same canonical object. It does not prove that the resolver, scaffold, or EntityAnchor accepts both identities as part of the same Entity.

Consequence:

- the current contract is necessary but not sufficient
- there is no authoritative acceptance step
- there is no resolver-enforced consumption path for the evidence yet

### 3. Audit replay is not production-complete

The in-memory transition list can be replayed, but the persisted audit log does not store enough structured transition data to reconstruct the state machine exactly from disk.

Consequence:

- "replayable from audit log" is not fully satisfied yet

### 4. The update path is safe mostly because it is not implemented

`UpdateGrantPolicy` is a solid gate, but the repo does not yet have:

- signed release artifacts
- active signature verification in CI
- real provenance generation
- secure install/replace flow
- rollback protection

Consequence:

- do not ship self-update yet
- the least vulnerable near-term choice is no in-place updater

### 5. Apple and CLI keystore parity is not there yet

Sprout's own storage layer for CLI is file-permission based. Sprout iOS/macOS wrappers are placeholders and do not yet implement Keychain/Secure Enclave in this repo.

Consequence:

- the intended trust model is documented
- the production keystore implementation is not finished in Sprout

### 6. Ed25519 vector interoperability is not fully proven

Current tests prove verification against given public keys and signatures, but they do not prove that Sprout reproduces the originally specified seed-to-public-key/signature vectors across runtimes.

Consequence:

- cross-runtime deterministic key derivation should be treated as OPEN until explicit vector tests are added

## Recommended Role For Sprout

Sprout should be the minimal bootstrap and trust-establishment component for HAVEN.

### Sprout should do

- classify environment: cloud, on-prem, macOS, iOS, CLI
- determine available keystore and transport capabilities
- load or create user identity
- acquire scaffold admin trust root
- gather explicit Purpose/Goal and Interests
- discover or accept signed bridge descriptors
- validate domain, purpose, expiry, and signatures
- gather entity-link evidence
- request resolver capabilities
- bootstrap and expose the correct Porthole entrypoint

### Sprout should not do

- act as a general Porthole UI shell
- embed browser editor logic
- carry broad app-specific cell logic
- perform automatic self-update in P0/P1
- bypass resolver contracts for convenience

This keeps Sprout as the smallest practical trusted computing base.

## Recommended Entity Proof Model

The cleanest model is a three-layer proof chain.

### Layer A: Mutual identity-link proof

Two identities sign the same `EntityLinkContract`.

Purpose:

- proves intentional linkage between the two identities
- does not assert a global identity

### Layer B: EntityAnchor inclusion proof

One accepted identity updates its local `EntityAnchor` with:

- `relations.identities.<identityUUID> -> entityUUID`
- `proofs.entity_links.<contract_id> -> EntityLinkContract`

Purpose:

- binds the link to an existing HAVEN entity context
- preserves the `Entity != Identity` model

### Layer C: Resolver-consumable evidence

Resolver or contract conditions should require one of:

- entity-link contract signed by both identities and accepted by entity owner identity
- VC/presentation with subject binding
- trusted issuer or endorsement policy for entity-link acceptance

Purpose:

- turns link evidence into actual capability grants
- keeps the resolver authoritative

## Recommended Bootstrap Identity Model

Sprout should carry two independent trust questions:

### User identity

- local identity created or loaded from platform vault
- this identity signs bootstrap requests

### Scaffold admin identity

- discovered from signed bridge metadata or signed invite
- treated as remote trust root for the scaffold

These must not be conflated.

Recommended addition to Sprout context:

- `user_identity`
- `scaffold_admin_identity`
- `entity_link_evidence`
- `resolver_decision_evidence`

## Recommended Porthole Access Model

Sprout's end state should be "the user's Porthole is reachable with the correct identity and the correct contract".

### Web Porthole

- user authenticates to a session that is bound to one HAVEN identity
- session produces a scoped Porthole contract
- allowed capabilities should be explicit:
  - `flow.read`
  - `state.read`
  - `state.write`
  - `action.invoke:<name>`

Web must never become an implicit admin tunnel.

### CLI Porthole

- Sprout should eventually expose a narrow CLI client that speaks to the Porthole as that identity
- same resolver-enforced contract model as web/native
- no extra privileges for being local CLI

### Native CellProtocol client

- Binding or native app connects directly with domain-scoped identity
- Sprout's job is to provision route, bridge, and evidence bundle
- the app's job is rendering and interaction

## Least Vulnerable Update Strategy

The recommended order is:

1. No in-place updater in Sprout P0/P1.
2. Ship immutable signed artifacts and document manual verification.
3. Use platform-native update channels where available.
4. If a custom updater becomes necessary, make it a separate minimal component.

### Per runtime

- iOS: App Store only
- macOS app: signed + notarized artifact, optionally Sparkle only after explicit update grants
- CLI/server: signed tarball or package, manual or operator-driven replacement first

### Sprout-specific rule

Sprout should evaluate policy, but not replace its own executable until:

- artifact signature verification is real
- provenance verification is real
- rollback protection exists
- updater has a smaller trusted surface than Sprout itself

If a self-updater is ever added, it should likely live as a separate `sprout-update` helper with:

- TUF metadata
- cosign or equivalent artifact signature verification
- explicit `UpdateGrantPolicy`
- no network activity without explicit operator/user action unless grants allow it

## Recommended Next Changes

### Highest priority

- Add a first-class `ScaffoldAdminIdentity` model to Sprout contracts and state machine.
- Replace synthetic `entity_id` generation with entity resolution or explicit unresolved state.
- Extend `EntityLinkContract` usage into EntityAnchor and resolver evidence.
- Make persisted audit log sufficient for exact replay.

### Next

- Implement secure keystore adapters:
  - Apple Keychain/Secure Enclave
  - CLI secure local keystore strategy
- Define `PortholeAccessContract` and interface-specific capability bundles.
- Add resolver-side acceptance API for entity-link evidence.

### Later

- Separate updater component
- signed artifacts in CI
- provenance and TUF

## Recommendation

Yes: it is a good idea to strip Sprout down to bootstrap, trust establishment, entity-link evidence packaging, and Porthole setup.

That direction is better than growing Sprout into a larger client because:

- it reduces the attack surface
- it makes update strategy simpler
- it keeps resolver enforcement central
- it aligns with HAVEN's explicit identity/capability model
- it gives a cleaner separation between bootstrap and the actual Porthole consumers

The target should be:

"Sprout does not try to be HAVEN. Sprout proves enough about environment, identity, scaffold trust, and entity-link evidence that HAVEN can safely give the user the right Porthole."
