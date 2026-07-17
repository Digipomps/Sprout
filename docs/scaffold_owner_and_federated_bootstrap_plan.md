# Scaffold Owner and Federated Bootstrap Plan

Date: 2026-03-09

## Goal
Sprout should remain a narrow bootstrap component, but it must be able to do four concrete things reliably:
- understand the runtime environment it is starting in
- acquire or load the correct user identity for that environment
- discover and trust the correct scaffold owner/admin identity for the selected HAVEN domain
- optionally establish a separate contact path to another HAVEN installation when that is required to fulfill an explicit `Purpose` and `Goal`

This plan keeps the current domain constraints intact:
- domain-scoped identities only
- `Entity != Identity`
- no implicit cross-domain linkage
- capability/contract enforcement only
- no hidden privilege escalation
- `Purpose`/`Goal` must remain explicit

## Current repo reality
What already exists:
- `CellScaffold` still resolves scaffold ownership mainly from environment/context (`CELL_SCAFFOLD_OWNER_*`).
- `CellScaffold` now uses `BridgeBase` + default websocket transport registration in `CellBase`.
- `Sprout` already models `ScaffoldAdminIdentity`, `EntityLinkEvidence`, `EntityInclusionProof` and `PortholeAccessContract`.
- `Sprout` already requires explicit `Purpose`/`Goal` before bootstrap requests.
- `Sprout` already supports CLI bootstrap and signed handoff for `web` and `native` porthole modes.

What is still missing:
- a first-class persisted scaffold owner bootstrap path in `CellScaffold`
- a first-class separate identity for outbound contact with other HAVEN installations
- a normative flow for asking another HAVEN installation for helper functionality based on explicit purpose
- full CLI parity for every bootstrap step that a Binding app may assist with

## Required identity roles
The implementation should separate these roles explicitly.

### 1. Scaffold owner identity
This identity belongs to the local scaffold domain.
Examples:
- `staging.haven.digipomps.org`
- `dev.haven.digipomps.org`

Responsibilities:
- owns scaffold-unique administrative cells
- acts as local scaffold trust root for admin workflows
- signs or authorizes local membership and porthole decisions through the resolver path
- never acts as a generic remote-contact identity

Required properties:
- persisted in the scaffold vault
- bootstrapped once, then reused
- environment variables remain allowed only as bootstrap input or recovery override
- ownership must become inspectable from CLI

### 2. Federation contact identity
This is a different identity from the scaffold owner identity.
It is used only for contact with another HAVEN installation when Sprout needs remote helper functionality.

Examples:
- local scaffold contacts `staging.haven.digipomps.org`
- local scaffold contacts `dev.haven.digipomps.org`

Responsibilities:
- authenticates outbound contact to another HAVEN installation
- requests only purpose-scoped helper functionality
- carries no local scaffold-admin privilege by default
- is bound to one remote domain at a time

Required properties:
- separate identity context and storage slot from scaffold owner
- explicit capability set and expiry per remote domain
- remote relationship documented as contract/evidence, not inferred
- should be creatable and inspectable from CLI

### 3. User device identity
This is the identity used by the person running Sprout from CLI, laptop, phone or tablet.

Responsibilities:
- signs bootstrap requests
- proves membership to an entity when required
- receives porthole access contracts
- may delegate scanning or approval to a Binding app, but must not depend on it

Required properties:
- always usable from CLI
- Binding app can assist with QR scan, approval and handoff
- identical contract semantics regardless of client type

## Contact model for other HAVEN installations
At the moment the practical remote targets are:
- `staging.haven.digipomps.org`
- `dev.haven.digipomps.org`

The model should be:
1. Sprout collects explicit `Purpose`, `Goal` and declared `Interests`.
2. Sprout selects a remote HAVEN domain only if that purpose requires external helper functionality.
3. Sprout uses the federation contact identity for that remote domain.
4. Remote helper requests stay capability-scoped and contract-bound.
5. Any returned descriptor, helper route or porthole access must be signed and auditable.

This avoids overloading the local scaffold owner identity with cross-domain responsibilities.

## Normative bootstrap sequence

### CLI-only path
1. Inspect local environment.
2. Load or create user device identity.
3. Load or bootstrap local scaffold owner identity.
4. Resolve scaffold admin trust root from signed bridge/admin metadata.
5. Collect explicit `Purpose`, `Goal` and declared `Interests`.
6. If the purpose requires external helper functionality, select remote HAVEN domain and load/create the matching federation contact identity.
7. Resolve entity membership and required capabilities.
8. Request signed `PortholeAccessContract` or helper contract.
9. Launch the requested porthole mode or emit machine-readable handoff output.

### Binding-assisted path
1. CLI or server produces a signed invitation or descriptor.
2. Binding app scans or imports the invitation.
3. Binding app uses the same contract chain, not a parallel trust model.
4. Binding app may help with QR, approval, local secure storage or native porthole launch.
5. Every step must still be possible from CLI by providing the same artifacts as files or flags.

## Concrete implementation workstreams

### Workstream A: Scaffold owner bootstrap in CellScaffold
Target repos:
- `CellScaffold`
- `CellProtocol`

Required changes:
- introduce a dedicated scaffold owner bootstrap service/cell instead of relying mainly on `CELL_SCAFFOLD_OWNER_*`
- persist the resulting owner identity in the vault
- add a read-only inspection path so operators can see which identity currently owns the scaffold
- keep env vars as explicit bootstrap override, not the long-term source of truth

Suggested deliverables:
- `ScaffoldOwnerBootstrapCell` or equivalent bootstrap service
- CLI/admin endpoint to inspect current owner identity UUID, domain and public key
- audit log entry when owner identity is initialized, rotated or restored

### Workstream B: Federation contact identity
Target repos:
- `CellScaffold`
- `Sprout`

Required changes:
- define separate identity contexts for remote HAVEN contact
- store one contact identity per remote HAVEN domain
- define a signed contract or descriptor describing why remote contact is permitted
- ensure remote-contact identity cannot administer the local scaffold

Suggested identity contexts:
- `Scaffold`
- `FederationContact/staging.haven.digipomps.org`
- `FederationContact/dev.haven.digipomps.org`

### Workstream C: Purpose-driven helper acquisition
Target repos:
- `Sprout`
- resolver/server side when available

Required changes:
- add a purpose-scoped command path such as `sprout purpose fulfill ...`
- let Sprout ask either the local scaffold or a permitted remote HAVEN installation for helper functionality
- require signed descriptors for returned helper cells, bridges or porthole routes
- reject any network action that is not attached to an explicit `Purpose` and `Goal`

### Workstream D: CLI parity and Binding assistance
Target repos:
- `Sprout`
- Binding app repo when needed

Required changes:
- every bootstrap artifact must be importable/exportable from CLI
- QR is only an encoding convenience, not a separate protocol
- Binding app may help with scan and secure storage, but the canonical flow remains file/JSON contract based

Required CLI surface:
- inspect local environment
- initialize scaffold owner
- inspect scaffold owner
- initialize federation contact identity for a target HAVEN domain
- export/import invitation or helper descriptor
- resolve entity and request porthole contract
- emit `web`, `native` or future `cli` porthole launch spec

## Recommended next implementation order
1. `CellScaffold`: add a native Linux preflight and operator-facing owner inspection path.
2. `CellScaffold`: add first-class scaffold owner bootstrap storage and inspection.
3. `Sprout`: add CLI commands for scaffold-owner inspection and federation-contact initialization.
4. `Sprout`: add purpose-fulfillment command path that can call local or remote HAVEN helper contracts.
5. Binding app: support the same artifact chain for scan/import/export without adding protocol divergence.

## Exit criteria for this plan
- local scaffold owner identity is persisted and inspectable without reading raw vault files
- remote HAVEN contact uses a separate identity from local scaffold ownership
- no cross-domain contact occurs without explicit purpose and contract evidence
- user can complete the full bootstrap flow from CLI alone
- Binding app can assist, but is not required for correctness
- every porthole or helper handoff is signed, bounded and auditable

## Open items
- authoritative server route shape for remote helper acquisition is still open
- the exact scaffold-owner bootstrap cell/service shape is still open
- `cli` porthole runtime remains less mature than `web` and `native`
- staging and dev are the only current remote HAVEN targets that should be wired first

## Follow-up implemented after this plan
- Sprout now has a local scaffold-owner identity store and CLI surface:
  - `sprout owner init --domain <local-scaffold-domain>`
  - `sprout owner show --domain <local-scaffold-domain>`
  - `sprout owner list`
  - `sprout owner trust-root --domain <local-scaffold-domain>`
- The owner identity is stored separately from starter/user identities and federation-contact identities.
- The owner record uses `identity_context = Scaffold` to align with current CellScaffold/VaporVault expectations, while the storage path remains domain-scoped.
- The local owner key can sign a `ScaffoldAdminTrustRootDescriptor`; this gives Sprout a concrete owner/admin trust artifact without requiring a VaporVault export for first local bootstrap.
- Sprout now has a signed executable catalog contract:
  - `ScaffoldExecutableCatalog`
  - `sprout software fetch`
  - `sprout software verify`
  - `sprout software select`
  - `sprout software sign-catalog`
- The scaffold trust root can now include `software_catalog_url`, so Sprout can discover where a HAVEN-hosted scaffold publishes compiled/signed software artifacts.
- CellScaffold now has an executable-catalog publication surface for `/.well-known/haven-executable-catalog.json` and `/v1/software/catalog` when artifact download, hash and signing evidence are configured.
- Cross-scaffold continuity is now modeled explicitly in `docs/cross_scaffold_entity_continuity.md`.
- The implemented chain is:
  - source-scaffold `CrossScaffoldEntityContinuityProof`
  - target-identity `EntityAdmissionRequest`
  - target-scaffold `EntityAdmissionContract`
- This is the current answer to cross-scaffold entity extension in Sprout.
- A single global person-level entity across scaffolds remains `OPEN` and should be treated as a separate research/design task unless it can be made fully explicit and anti-linkage-safe.
