# HAVEN ChatGPT package relevance audit

Audit date: 2026-09-07 (Europe/Oslo).

## Verdict

The February package is useful as historical background, but is materially
outdated and insufficient as the working context for implementing Sprout today.
Replace the package and refresh its master prompt before resuming implementation.
The original product intent remains relevant: explicit Purpose/Goal, owner and
starter identity bootstrap, trusted discovery, bridges, signed distribution,
and consent-based continuity across devices/scaffolds.

This is a local source/documentation freshness audit. It is not a build,
security certification, deployment test, or claim that the current checkouts
match production. No application tests or live HAVEN requests were run.

## Archive verification

Archive: `/Users/kjetil/Build/Digipomps/HAVEN/sprout/haven_docs_plus_prompt_sources_2026-02-23.zip`

- Size: 403,961 bytes.
- SHA-256: `12efb15c38f930fba4453dccaa972408dbb9d0426f2ca4dd788391e3abc84f9d`.
- ZIP CRC verification: passed for every entry.
- The filename says February 23; entry timestamps extend to February 24, 2026.
- Contents are Markdown, JSON, and Swift. This archive contains no PDF, YAML,
  SVG, PNG, or Drawio files, despite the earlier broad packaging description.

Each archived file was read directly from the ZIP and SHA-256-compared with
the current file at its corresponding local HAVEN path. Nothing was extracted
over an existing checkout.

| Result | Files |
| --- | ---: |
| Identical bytes | 130 |
| Changed bytes | 79 |
| Current path absent | 22 |
| Total | 231 |

All seven archived Swift sources have changed. All 18 archived entries under
the canonical `CellProtocolDocuments/` root have changed.

The 22 absent paths are 21 `Binding/CellProtocolDocuments/` entries and
`tmp/FileUtils-c/README.md`. An absent path does not prove that a document was
deleted or has no replacement; this audit does not infer rename history.

There are 24 groups of byte-identical archive entries, containing 40 redundant
copies. Book documents appear under multiple repositories without a package
manifest identifying which revision is authoritative. All 231 entry names
start with `../`; a replacement should use clean `HAVEN/<repo>/...` paths.

Full per-file results, archived/current hashes, repository revisions, duplicate
groups, and pre-existing Sprout worktree status are recorded in
[the machine-readable audit](HAVEN_ChatGPT_Package_Relevance_Audit_2026-09-07.json).

## Findings

### 1. The package omits the Sprout implementation

The archive contains exactly one Sprout file: the original master prompt.
The current tracked root/docs inventory contains 43 Markdown documents; 42
are absent from the package. There are also 64 tracked Swift sources under
`Apps/` and `Packages/`, and 34 under `Tests/`, all absent from the package.
These counts exclude the separate untracked overlay and the untracked July
owner-bootstrap assessment.

The current `Package.swift` defines the core, crypto, storage, bridge,
transport, resolver adapter, app support and admin support modules, plus CLI,
admin and updater executables. This is no longer the February SwiftUI stub.

Source evidence:

- `sprout/Package.swift`: current products, targets and dependencies.
- `sprout/Packages/SproutCore/Sources/SproutCore/BootstrapModels.swift`:
  bootstrap states include `resolveEntity` and `issuePortholeAccess`.
- `sprout/Packages/SproutCore/Sources/SproutCore/SproutBootstrapStateMachine.swift`:
  validates entity-link/admission evidence and requests resolver decisions.
- `sprout/Apps/sprout-cli/Sources/sprout-cli/main.swift`:
  owner, software, admission and bootstrap command dispatch.

Impact: using the old package alone can lead to redesigning existing contracts
and building a parallel bootstrap implementation.

### 2. Identity and authorization guidance has materially changed

The archived identity chapter lists a domain string on `Identity` and says
Entities are never stored or transmitted. The current chapter explains that
runtime identity domain/context comes from the vault and signed evidence,
and distinguishes Entity-related records from bearer authority.

Current sources:

- `CellProtocolDocuments/Book/03_Identity_Model.md`, especially sections 1 and 2.1.
- `CellProtocol/Sources/CellBase/Identity/IdentityDomainBinding.swift`.
- `CellProtocol/Sources/CellBase/Identity/IdentityVaultProtocol.swift`.
- `CellProtocol/Sources/CellBase/Agreement/Grant/Permission.swift`.
- `CellProtocolDocuments/Book/04_Agreements_Contracts.md`.

`IdentityDomainBinding` has `grantsAuthority = false`: domain context must not
be mistaken for authorization. Canonical permissions now include `rwxs`, with
Storage/retention distinct from read, write and execute.

These are CellProtocol runtime contracts. Their correspondence with Sprout's
own wire DTOs must be checked explicitly; similar field names do not establish
interoperability.

### 3. Old guarantees overstate current evidence

The archived core/runtime chapters present broad guarantees about determinism,
replay, privacy and resolver mediation. The current core chapter explicitly
limits such claims to paths whose relevant contracts are implemented and tested.
It recognizes verified owner proof, Contracts/Grants and deliberately narrow
cell policy as explicit authorization paths.

Read:

- `CellProtocolDocuments/Book/01_CellProtocol_Core.md`, particularly the opening
  evidence boundary and sections on required invariants and replay.
- `CellProtocolDocuments/Book/05_Flows_Lifecycle.md`.
- `CellProtocolDocuments/Book/06_CellResolver.md`.
- `CellProtocolDocuments/Book/07_Scaffold_Runtime.md`.
- `CellProtocolDocuments/Deliverables/HAVEN_Cross_Repo_Robustness_Audit_2026-07-13.md`.

The master prompt's phrase "full member" needs per-platform acceptance criteria.
A successful bootstrap or signed handoff alone is insufficient evidence of full
runtime, persistence, transport and replay parity.

### 4. Cross-device and cross-scaffold work now has concrete contracts

Sprout already contains `CrossScaffoldEntityContinuityProof`,
`EntityAdmissionRequest`, `EntityAdmissionContract` and bootstrap admission
evidence. Separately, CellScaffold has `EntityScaffoldEnrollment` with request,
owner approval, activation challenge and revocation operations.

Read:

- `sprout/docs/cross_scaffold_entity_continuity.md`.
- `sprout/Packages/SproutResolverAdapter/Sources/SproutResolverAdapter/CrossScaffoldEntityContinuity.swift`.
- `sprout/Packages/SproutCore/Sources/SproutCore/EntityAdmissionEvidence.swift`.
- `CellScaffold/Documentation/EntityScaffoldEnrollment.md`.
- `CellScaffold/Sources/App/Cells/EntityScaffoldEnrollment/EntityScaffoldEnrollmentCell.swift`.
- `CellProtocolDocuments/Book/32_Cross_Scaffold_Entity_Enrollment.md`.

The Book chapter is marked draft and identifies missing grant-backed remote
EntityAnchor access. Sprout continuity between scaffold-local entities and
owner-approved access to shared EntityAnchor data are related but distinct
contracts. Their integration must be established, not assumed.

### 5. Discovery and server integration need newer sources

Current CellScaffold source includes Sprout HTTP route collections for starter
intent/registration, capability requests, entity resolution, membership checks,
porthole access and bridge discovery:

- `CellScaffold/Sources/App/Controllers/VaporSproutResolver.swift`.
- `CellScaffold/Sources/App/Services/SproutResolverCompatibility.swift`.
- `CellScaffold/Sources/App/Controllers/VaporSproutBridgeDiscovery.swift`.
- `CellScaffold/Sources/App/Services/SproutBridgeDiscoveryCompatibility.swift`.

These sources are missing from the archive. Their existence corrects an overly
broad reading of the March Sprout README's "server routes OPEN" statement, but
does not prove authoritative admission semantics or current deployed behavior.

Purpose work should now also include
`CellProtocolDocuments/Book/23_Purpose_Knowledge_Base.md` and its JSON knowledge
base, alongside the updated chapters 09 and 14. The knowledge base explicitly
labels draft/candidate terms and describes Goal-based purpose grounding.

### 6. Owner binding and distribution still have documented gaps

`ScaffoldOwnerIdentityStore.initialize` generates/persists a local domain-scoped
key. That is not by itself a ceremony binding an existing external owner's
Identity to a new installation.

The July assessment separates installation identity, owner identity and
delegated admin/service identity, and proposes `unclaimed` and recovery rules.
It is an untracked design assessment, not an implementation certificate:

- `sprout/docs/Sprout_Newborn_Owner_Bootstrap_Security_Assessment_2026-07-18.md`.
- `sprout/docs/signed_sprout_executable_first_run.md`.
- `sprout/Packages/SproutStorage/Sources/SproutStorage/ScaffoldOwnerIdentityStore.swift`.

Distribution scripts and CI signing now exist. However, `sprout/RELEASE.md`
explicitly says bit-for-bit reproducibility across independent environments
has not been proven in CI. The iOS wrapper README describes a placeholder,
and `SproutTransport/WSSClient.swift` throws `unsupportedTransport` outside
its Apple platform branches. These limits belong in the replacement context.

External checks performed on 2026-09-07:

- Reproducibility requires independently recreating identical specified
  artifacts from the same source, environment and instructions.
  [Reproducible Builds definition](https://reproducible-builds.org/docs/definition/).
- Apple distinguishes developer code signing from notarization, which checks
  submitted software for known malware. Neither should be conflated with
  Sprout owner authorization or an independent rebuild result.
  [Apple platform security](https://support.apple.com/en-gb/guide/security/sec3ad8e6e53/web).

## Replacement package contents

Use one canonical copy of each document. Preserve historical material in a
clearly marked optional section, rather than mixing it into current guidance.

| Area | Include |
| --- | --- |
| Sprout entrypoints | `README.md`, `Package.swift`, dependency lockfile, `DECISION_LOG.md`, `SECURITY.md`, `THREAT_MODEL.md`, `RELEASE.md` |
| Sprout docs | Developer/user guides, owner/federation plan, admin trust root, entity/porthole access, continuity, executable distribution, first-run, July owner assessment, live resolver and interop limits |
| Sprout implementation | Relevant `Apps/`, `Packages/`, `Tests/`, `Schemas/`, `OpenAPI/`, public synthetic `TestVectors/`, release scripts and CI workflows |
| Core protocol | Updated Book chapters 01-14, canonical index/catalog, chapters 21, 22, 23, 31, 32, purpose knowledge JSON and current robustness audit |
| Runtime source | Updated original seven Swift files plus their relevant identity, vault, grants, bridge and contract dependencies and tests |
| Server integration | Sprout resolver/discovery/software controllers and services, EntityScaffoldEnrollment implementation, contract docs and tests |
| Reading/provenance | `START_HERE.md`, package timestamp, per-file SHA-256, repo revision, source branch, dirty/draft status and reading order |

Exclude build products, local identity stores, secrets, personal deployment
state and unrelated worktree overlays. Select test fixtures explicitly.
The resulting context bundle is not automatically a standalone buildable source
distribution; that requires all build inputs and dependency availability too.

## Master prompt refresh

The original prompt is byte-identical to its February version. A replacement
should retain the product goals and require the following:

1. Start from the existing Sprout modules, schemas and client/server contracts.
2. Label each claim as observed in source, tested at a specified revision,
   planned, or unresolved. Record both supporting evidence and limitations.
3. Resolve installation/owner/admin/starter/federation identities explicitly.
4. Check domain binding and `rwxs` authorization against the current runtime.
5. Map Sprout continuity/admission to CellScaffold enrollment without silently
   equating them or introducing global identity correlation.
6. Define success per supported platform, including first-run recovery, bridge
   behavior, revocation, persistence and signed handoff validation.
7. Separate signatures, notarization, reproducibility and running-process
   assurance; require evidence for each advertised property.
8. Refer to package-relative sources and treat bundled historical prompts as
   historical material. Start with an explicit reading order.
9. Update developer and user docs, decision log, unresolved questions and a
   next-session handoff after each implementation iteration.

## Verification limits and handoff

Repository HEADs were recorded with the machine-readable results. The inspected
repositories are on different local branches; their heads are not a claim of a
coordinated release. Five modified tracked Sprout files and two untracked paths
were present before this audit. Existing work was not modified.

Verification completed: ZIP CRC, per-file content hashes, missing-path and
duplicate counts, targeted current source/doc comparison and external checks
for signing/reproducibility distinctions. Current tests, CI, released binaries,
remote branch freshness and live staging interoperability remain unverified in
this audit.

The February ZIP and original master prompt were preserved. The next action is
to construct a current, deduplicated context bundle and a revised prompt from
the scope above, marking any included work in progress explicitly.
