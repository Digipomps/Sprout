# Cross-Scaffold Entity Continuity

Date: 2026-03-11

## Goal
Sprout needs an explicit way to carry a person from one scaffold to another without breaking the core HAVEN constraints:
- identities are domain-scoped
- `Entity != Identity`
- no implicit cross-domain linkage
- access is always capability/contract enforced

The implemented model in this repo is not a global identity system.
It is an explicit continuity and admission chain between two scaffold-local entities.

## Short answer to the research question
"How do we ensure that one person has one entity, while using different identities for every occasion?"

Within HAVEN's current canonical constraints, that is only partially implementable.

What is implementable now:
- one person can hold many different domain-scoped identities
- one scaffold can explicitly attest continuity from one of its local entities to another scaffold
- another scaffold can explicitly admit a new local identity into one of its own local entities based on that attestation

What is not solved here:
- a single global person-entity automatically shared across scaffolds
- any implicit, background, or inferential linkage of identities across domains

If the target concept is literally "one person, one global entity everywhere", that is a separate research and design problem because it conflicts with the current anti-linkage constraints unless it is made fully explicit, contract-based and user-mediated.

## Normative model
There are three separate layers.

### 1. Source-scaffold continuity proof
A source scaffold issues a signed `CrossScaffoldEntityContinuityProof`.

Meaning:
- scaffold `A` says: identity `X` is accepted as part of local entity `EA`
- scaffold `A` allows that local fact to be presented to scaffold `B`
- the proof is bounded to explicit `purpose`, `goal` and `interests`
- the proof expires

This does not create a target-side entity.
It only creates portable continuity evidence.

### 2. Target-side admission request
The target identity signs an `EntityAdmissionRequest`.

Meaning:
- a new target-side identity `Y` asks scaffold `B` to consider continuity from scaffold `A`
- the request binds the target identity to the exact continuity proof by `proof_id` and canonical payload hash
- the request repeats the explicit `purpose`, `goal` and `interests`

This does not create access by itself.
It is a request artifact.

### 3. Target-side admission contract
The target scaffold issues a signed `EntityAdmissionContract`.

Meaning:
- scaffold `B` accepts the presented continuity proof and the target identity request
- scaffold `B` binds identity `Y` into a target-side local entity `EB`
- that admission is still local to scaffold `B`
- bootstrap can now use this contract as explicit entity evidence

This is the authoritative local acceptance step.

## Why this model fits HAVEN
It preserves the constraints cleanly.

- No global identity:
  continuity is scaffold-to-scaffold and contract-to-contract.
- `Entity != Identity`:
  entities stay local conceptual containers; identities stay operational handles.
- No implicit linkage:
  continuity only exists when a proof and a contract are explicitly created.
- Resolver-enforced access:
  the admission contract is evidence, not a bypass.
- Explicit purpose:
  continuity proof and admission request both carry purpose/goal/interests.

## What is implemented in Sprout
Implemented now in this repo:
- `CrossScaffoldEntityContinuityProof`
- `EntityAdmissionRequest`
- `EntityAdmissionContract`
- `EntityAdmissionEvidence` in bootstrap
- `sprout admission create-request`
- `sprout verify` support for all three artifacts
- `sprout bootstrap join --admission-contract <file> [--continuity-proof <file>]`
- `sprout-admin continuity-proof create-from-vapor-vault`
- `sprout-admin admission-contract create-from-vapor-vault`

This means the continuity chain is now expressible and testable from CLI alone.

## What works today
### Offline or controlled flow
1. Source scaffold operator issues `CrossScaffoldEntityContinuityProof`.
2. Target user creates `EntityAdmissionRequest` with their target-scaffold identity.
3. Target scaffold operator issues `EntityAdmissionContract`.
4. `sprout bootstrap join` consumes `--admission-contract` and uses it as explicit entity evidence.

This path is implemented and tested in `sprout`.

### Live resolver path
The live staging resolver currently supports:
- trust-root fetch
- starter bootstrap intent
- bridge discovery
- resolver-backed entity inclusion proof

What is still missing server-side:
- an authoritative live admission route that consumes `EntityAdmissionRequest`
- a target resolver flow that emits `EntityAdmissionContract`

So the live contract chain is specified client-side, but not fully wired into staging server routes yet.

## Recommended operational flow
### Source scaffold
Use `sprout-admin continuity-proof create-from-vapor-vault` from the source scaffold host.

The source scaffold signs only continuity from one of its own local entities.
It should never try to create target-side access directly.

### Target scaffold
Use `sprout admission create-request` from the target user's CLI context.
Then let the target scaffold issue `EntityAdmissionContract`.

The target scaffold decides:
- whether the continuity proof is acceptable
- whether to bind the target identity into an existing local entity
- whether to create a new local entity related by continuity

## Practical interpretation of “same person”
The safer phrasing is:
- the same person may be represented by multiple identities
- multiple scaffold-local entities may be linked by explicit continuity contracts
- a user can prove continuity across scaffolds without introducing implicit global linkage

That is already strong enough for bootstrap, onboarding and porthole access.

## Remaining research questions
These are still open:
- Should there ever be a global person-root above scaffold-local entities?
- If yes, how can that be explicit enough to avoid forbidden implicit linkage?
- How should revocation propagate across scaffold continuity contracts?
- Should continuity be pairwise only, or chainable across many scaffolds?
- Should source continuity proofs be one-shot, purpose-bounded tickets or reusable bounded attestations?

## Recommended next server-side step
The next concrete server-side step is not a global entity model.
It is a pair of explicit resolver routes:
- accept `EntityAdmissionRequest`
- issue `EntityAdmissionContract` after local policy and admin approval

That keeps the implementation aligned with HAVEN's current protocol stance and avoids over-claiming what entity continuity means across domains.
