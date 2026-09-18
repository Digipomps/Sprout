# Entity-owned Correspondence Implementation

Date: 2026-09-10. Status: implementation slice verified locally in isolated
worktrees; onboarding integration and recipient delivery are not complete.

## User Requirement

The Linux recipient uses an AI assistant. Invitations and access evidence must
be stored in the recipient's Entity and accessed through Cells, Agreements,
Grants and purpose policy. No invitation/proof download, copying or pasting is
part of the intended user workflow. Private device keys stay in the local vault;
this requirement does not prohibit internal persistence files or installing a
client executable.

## Correction To The September 9 Assessment

The previous audit inspected the older client under `Binding::HavenAgentD`.
The standalone `HavenAgentD` repository contains a newer, CellProtocol-native
client at `ba14895`. It encrypts envelopes locally, uses Resolver/Meddle and
WebSocket bridges, and has a local-only `doctor`. The older plaintext/HTTPS
mailbox and inbox-reading diagnostic conclusions must not be applied to this
newer client. Neither implementation's source alone establishes deployed state.

`CellProtocol` has CorrespondenceCell in `a00e3a0` and authenticated attachment
stream cryptography in `4096760`. The September 9 integration handoff explicitly
separates attachment cryptography from manifest, Grants and MCP attachment
transport. A complete deployed attachment flow has not been verified here.
The locally inspected invitation-rotation queue item is `HANDOFF_REQUIRED`, not
proof that the encrypted implementation is simply awaiting a successful deploy.
No live service, inbox or participant data was inspected in this implementation
session.

## Working Copies

These are actual Git worktrees, not replacement copies of the shared repos:

- `CellProtocol`, branch `codex/entity-correspondence-20260910`, base `4096760`.
- `HavenAgentD`, branch `codex/entity-correspondence-linux-20260910`, base `ba14895`.
- Both are located below this Sprout checkout's
  `implementation/entity-correspondence/`, named by repository.

The shared source trees were not edited. The portable identity module includes
the already existing standalone working-tree `AgentIdentityStore` additions
needed by `ba14895`: explicit context/display name and non-creating
`loadExisting`. Their provenance must be retained during integration. No commit
was amended, pushed or deployed.

Reviewable source patches, a verification runner and a machine-readable result
are retained in `implementation/entity-correspondence/`. The patches omit the
local-path development `Package.resolved` change. They do not represent a new
published dependency pin or an installation package for the recipient.

## Implemented Contract

Normalized Entity-data keypaths:

```text
correspondence.v1.invitations.<lowercase-invitation-UUID>
correspondence.v1.proofs.<lowercase-Contract-UUID>
```

The common implementation is installed on both Apple and Vapor EntityAnchorCell.
It stores records in the existing Entity backing data, not a second onboarding
database. The record family is versioned. Identifier normalization applies to
keypaths; signed Contract bytes and Identity identifiers are not rewritten.

| Operation | Permission | Meaning |
| --- | --- | --- |
| GET `correspondence.v1.invitations` | `r---` | Read the recipient Entity's invitation records. |
| GET `correspondence.v1.proofs` | `r---` | Read its retained access-evidence records. |
| SET `correspondence.v1.storeInvitation` | `-w-s` | Persist one immutable Entity-bound invitation proposal. |
| SET `correspondence.v1.storeProof` | `-w-s` | Persist one verified Contract bound to an existing invitation. |

Writes require an explicit `purposeRef` of `purpose://contact.communication`.
Owner proof or an approved, exact scoped Grant is still required by the Cell.
An invitation is intent, not access authority. Proof validation checks the
expected issuer, recipient, correspondence domain, signature, validity and exact
four-message-operation grant set. The remote CorrespondenceCell/Resolver remains
authoritative on every message operation, including conditions and revocation.

Duplicate identical records are idempotent; a changed record under the same ID
is rejected. Wrong Entity, unsupported fields, invalid proof and generic batch
or legacy direct-write attempts to mutate this reserved namespace are rejected.
Explicitly marked private key material is rejected. Typed Identity decoding may
fill optional defaults; normalization does not require byte-identical input JSON.
Writes are serialized
within the store and acknowledged after the backing write and read-back. This
is not a distributed commit, independent replica convergence, backup erasure or
power-loss certificate. Expired invitation evidence does not by itself revoke an
already valid Contract; new admission still checks invitation expiry.

## Client Changes

- `HavenIdentity` isolates existing identity/key storage from macOS automation.
  `HavenAgentRuntime` re-exports it for compatibility.
- The correspondence build graph can omit the Mac daemon/automation targets.
- Linux imports and XDG state paths are used for the portable client.
- `--entity cell://HOST/ENTITY_UUID`, or bootstrap-provided
  `HAVEN_ENTITY_ENDPOINT`, selects Entity mode.
- Entity mode loads an already established local device identity, reads both
  record collections through Resolver, verifies them, and constructs a volatile
  client profile. It does not write an invitation or `profile.json`.
- Missing identity fails before any Entity read or implicit identity creation.
  An arbitrary Entity UUID, endpoint or invitation never establishes ownership.
- `haven-correspondence://invitations` shows purpose and untrusted issuer labels,
  with `awaiting_proof`, `expired` or `contract_available` status. An invitation
  never grants authority. This is a startup snapshot, not a live approval feed.
- In Entity mode `haven-correspondence://contracts` returns record references
  only, not signed proof payloads in the AI transcript.
- The old file mode remains a compatibility path, not the selected onboarding
  design. `doctor` stays local-only and is not repurposed as an Entity/inbox read.

## Verification

The test run uses the already installed `swift:6.2.4-noble` Linux/amd64 image
under emulation on the arm64 Mac, with `--network none` and local dependency
copies. No remote dependency or user data is requested. The local CellProtocol
override is explicit through `HAVEN_CELLPROTOCOL_PATH`; this is not a build
against a newly published dependency pin.

Working-directory command inside that container:

```sh
HAVEN_CELLPROTOCOL_PATH=/work/CellProtocol HAVEN_CORRESPONDENCE_ONLY=1 \
  swift test -j 4 --disable-automatic-resolution --filter CorrespondenceEntityTests
```

New tests cover normalized persistence, duplicate/restart encoding, wrong
Entity/purpose, unknown fields, generic batch bypass, immutable conflict,
missing/forged/wrong-subject proof, expiry, missing Storage grant, unrelated
reader, failed writes, no implicit identity creation, and Entity-loaded
encrypted send/list/read/ack through an isolated real Resolver/CorrespondenceCell.

The focused static Explore audit reported zero errors and two manual-review
warnings for computed registration keys. It does not prove those dynamically
registered handlers; source/runtime checks are also needed. Native Swift parsing
of the new files passed.

### Final Results

- **32 tests in four suites passed** on the final source, including the actual
  Vapor EntityAnchor write, backing-file inspection, reconstruction without
  embedded Entity data, read-back, idempotent replay and direct-write rejection.
  Final log: `implementation/entity-correspondence/linux-final-validation.log`.
- The new Entity client test reads records via a Cell, shows both pending and
  Contract-backed invitation states, excludes full proofs from AI resources,
  creates no profile file, and sends/lists/opens/acknowledges encrypted content
  through a real in-process Resolver/CorrespondenceCell.
- `--help` runs on Linux. Entity-mode startup without an enrolled identity exits
  with code 1 and an explicit enrollment explanation, before creating any state
  directory. Log: `linux-cli-smoke.log` in the evidence directory.
- ELF inspection confirms a Linux x86-64 position-independent debug executable.
  `ldd` confirms dynamic Swift, Foundation and system-library dependencies. This
  is **not** a self-contained, signed recipient distribution. The optional `file`
  utility was absent in the image; inspection was completed with `readelf` and
  `ldd` in `linux-binary-dependencies.log`.
- Actual Apple EntityAnchor syntax was checked, but its module/runtime and the
  full macOS daemon graph were not tested. No live WSS bridge or deployment was
  exercised. The Linux emulator qualification below is mandatory.
- Both patches pass reverse `git apply --check` against their isolated source
  trees; both repositories' diffs pass `git diff --check`.

The actual-Anchor test caught an integration mistake that the storage adapter
alone could not: existing `ValueType.==` deliberately does not deep-compare
objects/lists. Read-back now compares canonical serialized records instead.
Global ValueType equality semantics were not changed. Strict parent traversal
also rejects malformed stored namespaces rather than replacing them via the
generic keypath setter's object coercion.

### Observed Linux Crypto Diagnostic

The first default-CPU Linux/amd64 emulation runs failed `ciphertextOpenFailed`
in both the new Entity integration test and four pre-existing hosted-cell tests.
A direct Swift Crypto ChaChaPoly round-trip also failed with BoringSSL
`CIPHER_R_BAD_DECRYPT` (`503316581`). A small shared-envelope round-trip passed.
This isolated the failure below the Entity/Resolver boundary.

Without rebuilding the test binary, setting `OPENSSL_ia32cap=0` made all 21
then-current Entity and hosted-cell tests pass (1.571 seconds of test execution,
`linux-crypto-no-acceleration.log`). This supports an accelerated-CPU-path issue
in the emulated environment; it does not establish the precise upstream cause
or native Linux behavior. No shared crypto source, algorithm, key size or
authentication check was weakened or changed.

The installed dependency's `crypto/cpu_intel.cc` documents the capability override.
[Swift Crypto's upstream implementation notes](https://github.com/apple/swift-crypto)
confirm that Linux uses its BoringSSL-backed implementation rather than Apple's
CryptoKit backend. The [upstream ChaChaPoly API](https://github.com/apple/swift-crypto/blob/main/Sources/Crypto/AEADs/ChachaPoly/ChaChaPoly.swift)
requires authenticated decryption, including matching associated data; a passing
signature alone is not successful decryption.

The opt-in actual-Anchor test run uses `HAVEN_ENTITY_ANCHOR_TESTS=1` and
`OPENSSL_ia32cap=0:0` in this local emulator. The repeatable runner is
`implementation/entity-correspondence/verify-linux.sh`; its `emulated` argument
sets the diagnostic override. A native x86_64 Linux run without the override is
still a release gate. Neither this flag nor the unsigned debug binary is a
recommended recipient installation workaround.

## Remaining Delivery Gates

1. Run the companion Apple EntityAnchor and full macOS agent regression checks.
   The actual Vapor Anchor and all 32 portable-client tests passed in the
   qualified emulator environment; ordinary native Linux remains unverified.
2. Integrate CellProtocol changes and repair/update the standalone client's
   dependency pin. The previous unpublished integration is not a clean-release
   baseline, and local package overrides must not disguise that.
3. Wire invitation creation, owner approval and proof delivery to the new target
   Entity operations in the actual onboarding service. This assessment does not
   claim that existing HTTP invite issuance already writes these records. The
   inspected `CellScaffold/Sources/App/Controllers/VaporAssistantCorrespondence.swift`
   still sends an attachment named `haven-<profile>-invite.json` (line 203) and
   presents the old `setup --invite` workflow (line 240). No current source call
   to the new `correspondence.v1` operations was found in that shared service.
4. Establish the recipient's device/Entity access through the existing approved
   identity ceremony. His Linux distribution/architecture and whether he already
   has an Entity were asked asynchronously and remain unconfirmed.
5. Configure Sprout's discovery/install adapter to select the signed client and
   supply the authorized Entity endpoint. No general installer was added here.
6. Publish a signed, accessible Linux artifact and verify its exact source pin.
   No new release or signing key has been published/used in this session.
7. Verify bridge connectivity, bilateral approval, encrypted messaging and
   attachments against the actual deployed revisions. Public health is not
   enough. Native Linux crypto and Apple-side Anchor tests are also required.
   Deploy execution follows its separate owner approval/runbook.
8. Specify record revocation/tombstones, selected-proof renewal and retention
   under the Entity's existing authority history. Multiple live Contracts for
   one relationship must not be silently selected by arrival order.

## Prompts

End-user intent, after the installation/identity gates are satisfied:

> Open my correspondence invitations from my HAVEN Entity. Show who the channel
> is with, its purpose and requested permissions. Ask for my approval when needed.
> Use only valid, recipient-bound proofs from my Entity. Never ask me to download
> or paste invitation files, private keys or access credentials. If my device is
> not enrolled, say which identity step is missing instead of claiming access.

Developer continuation:

> Continue the two isolated Entity Correspondence worktrees listed here. First
> inspect current source, build logs and dependency state. Complete the tests and
> integration, preserving the shared trees and the pre-existing identity-store
> changes. Keep invitation/proof records in the target Entity's normalized
> keypaths and use the existing owner/Agreement/Grant/Resolver boundary. Do not
> add bearer secrets, implicit identity linking, privilege bypasses or invitation
> file exchange. Wire the real issuance/approval service to the Entity operations
> and the Linux client to approved bootstrap discovery. Validate denied access,
> failures, restart and two-sided encrypted use. Keep attachment crypto, full
> attachment transport, source integration, signed releases and deployed behavior
> separate in the evidence. Document remaining gates, and do not deploy or publish
> without the required authorization.
