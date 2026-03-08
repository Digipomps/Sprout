# Entity Bootstrap and Porthole Access

## Why this exists
Sprout must not collapse identity bootstrap, entity linkage and client access into one implicit step. The implemented model now separates:
- `Identity`: local, domain-scoped subject key
- `Entity`: resolver-resolved membership target
- `ScaffoldAdminIdentity`: scaffold trust root for the selected domain
- `EntityAnchorSnapshot`: signed anchor projection used by resolver-backed inclusion proof
- `EntityInclusionProof`: resolver-signed proof that a specific identity belongs to a specific entity
- `PortholeAccessContract`: signed access handoff for a concrete porthole mode

## Implemented artifact chain
1. `StarterAuthPayload`
   Purpose-scoped bootstrap request signed by the joining identity.
2. `BridgeDescriptor`
   Signed scaffold metadata containing endpoint and owner/admin pubkey.
3. `ScaffoldAdminIdentity`
   Explicit trust root derived from the selected signed bridge descriptor.
4. `EntityLinkEvidence`
   Optional proof material presented to the resolver.
5. `EntityAnchorSnapshot`
   Signed snapshot of accepted entity membership and accepted link contracts.
6. `EntityInclusionProof`
   Resolver-signed decision binding one domain-scoped identity to one entity based on the anchor snapshot.
7. `PortholeAccessContract`
   Signed, time-bounded, capability-bounded handoff.

## Current evidence model
Implemented now:
- `EntityLinkEvidence` can wrap a mutual `EntityLinkContract`.
- `EntityAnchorResolverAdapter` can resolve membership directly from an anchor snapshot or from an anchor-accepted entity-link contract.
- `EntityResolutionDecision` includes a signed `EntityInclusionProof`.
- The state machine validates the inclusion proof before requesting porthole access.

Still OPEN:
- direct integration with HAVEN's live resolver API
- full revocation/unlink path beyond accepted contract IDs in the snapshot
- stronger admin trust root than `BridgeDescriptor.owner_pubkey`

## Inclusion proof semantics
`EntityInclusionProof` proves:
- which scaffold domain the proof applies to
- which entity the subject identity belongs to
- which subject identity public key was resolved
- which anchor snapshot and admin key the decision was based on
- which resolver key issued the proof
- which optional evidence contract participated in the decision

This is stronger than a mutual link contract because it is:
- anchor-backed
- resolver-issued
- scoped to one entity resolution result

## Porthole modes and consumers
Implemented now:
- `web` consumer -> `WebPortholeBootstrapDescriptor`
- `native` consumer -> `NativePortholeBindingDescriptor`
- `cli` contract verification remains available, but the dedicated interactive CLI porthole is still OPEN
- `sprout-macos` consumes `web` contracts directly and handles signed `native` descriptors in the standalone build

The bootstrap output is not the porthole itself. It is the signed contract that downstream consumers should honor.

## Enforcement rules in code
- No `PortholeAccessContract` is requested before entity resolution is explicit.
- If entity resolution is `unresolved`, bootstrap stops with `entityUnresolved`.
- If inclusion proof is missing, expired, wrongly scoped or signed by the wrong key, bootstrap stops.
- Returned porthole contracts are verified for signature, expiry and field parity.
- Contract capabilities must be a subset of the resolver capability decision.
- Web/native consumers verify contract signature, expiry and protocol-kind before producing launch specs.

## CLI paths
Bootstrap against anchor-backed resolver:
```bash
.build/debug/sprout bootstrap join \
  --domain example.haven.local \
  --purpose bootstrap.join_scaffold \
  --goal "Join scaffold and register identity" \
  --interests haven.core.bootstrap,haven.core.bridge \
  --starter TestVectors/starter_auth_payload.signed.json \
  --catalog <signed-bridge-catalog.json> \
  --entity-anchor <entity-anchor-snapshot.json> \
  --porthole web
```

Consume porthole contracts:
```bash
.build/debug/sprout porthole web-bootstrap --contract <porthole-access-contract.json>
.build/debug/sprout porthole native-spec --contract <porthole-access-contract.json>
```

## Recommended next step
Implement or publish the authoritative HAVEN server-side resolver routes so the existing `HavenResolverHTTPAdapter` can be used against staging/prod without relying on file-backed anchor snapshots.
