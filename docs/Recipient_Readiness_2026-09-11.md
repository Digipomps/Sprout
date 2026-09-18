# Sprout recipient readiness

Updated: 2026-09-11. Decision: **NOT READY to send as a working Correspondence
client**. Local implementation and an unsigned Linux candidate exist. This is
not a release, a live identity approval, or an encrypted-channel certification.

## Request and authority

The user wants a low-friction terminal/assistant experience for a Linux recipient.
Invitations and proofs must stay in the target Entity's Cells at the normalized
paths in `Entity_Correspondence_Implementation_2026-09-10.md`, governed by
Agreement, exact Grants and purpose. No file-paste fallback is acceptable.

The user explicitly approved status sharing with the separate task **Design
sikker Entitetssammenslåing** (task ID
`01a08bdf-7a94-74a3-985d-cb1d59869d50`).
Messages were successfully exchanged. This supersedes the earlier blocked-share
notes. No authorization has yet been received for push, publication, staging
mutation or production changes. Staging-only publication/deployment approval was
requested separately; production remains untouched.

Pending preferences: Linux distribution/architecture, chosen assistant, staging
versus ordinary HAVEN, and whether the recipient already has an Entity. x86_64
is a provisional build target, not an observed fact about his computer.

## Verified locally

| Check | Evidence and boundary |
| --- | --- |
| Native unit/contract tests | 128 XCTest + 6 Swift Testing passed; `.build/recipient-hardening-tests-final.log`; macOS arm64, not Linux |
| Terminal process | Resume, refusal, EOF, safe defaults, corruption refusal and unchanged key smoke in `Scripts/test_terminal_onboarding.sh` |
| Bounded HTTP | 1 MiB cap while receiving, declared/chunked oversize rejection, cancellation and no redirects; synthetic URLProtocol tests, not a live hostile service |
| Doctor | `sprout doctor --json` reports platform plus ephemeral Ed25519/base64 checks; no network, identity file access or channel-ready claim |
| Linux compilation | Both Sprout and updater cross-compiled successfully with official Swift 6.2.4/static Linux SDK |
| Linux binary structure | ELF64 x86_64, no ELF interpreter or dynamic library dependencies; `validate_release_platform.swift` passed |
| Release guards | Reject unsigned delivery by default, altered bytes, unsafe paths, duplicate/empty checksum entries, symlinks, partial signatures, wrong platforms/dynamic ELF and mismatched release ref/source |
| Signer selection | Exact Digipomps/Sprout release workflow/version-tag policy; wiring tested with a local fake cosign, NOT cryptographic Sigstore verification |

Static candidate (development only):

```text
dist/recipient-candidate-20260911-final/sprout-linux-x86_64
dist/recipient-candidate-20260911-final/sprout-updater-linux-x86_64
dist/recipient-candidate-20260911-final/SHA256SUMS-linux-x86_64.b64url
dist/recipient-candidate-20260911-final/release-manifest-linux-x86_64.json
dist/recipient-candidate-20260911-final/sprout-linux-x86_64.spdx.json
```

Build log: `.build/recipient-linux-bundle-final.log`. Integrity-only verification
passed in `.build/recipient-bundle-integrity-final.log`. Both executables are
about 77 MiB after removing debug information from delivery copies; the original
symbol-rich build outputs remain under `.build/recipient-linux`. The bundle has
no compiler cache. The earlier unslimmed candidate is retained, not a release.

The candidate is unsigned and
has not run on Linux. Do not ask a recipient to bypass signature verification.
The original SBOM generator lists source targets, not a complete transitive
static-SDK/native-library inventory; it is not a complete supply-chain audit.

Terminal smoke and release-guard logs: `.build/recipient-terminal-smoke.log` and
`.build/recipient-release-guards.log`. YAML parsing, shell syntax checks and
`git diff --check` passed. Real Sigstore signing/verification and the edited
remote CI workflows have not been exercised. The CLI now explicitly distinguishes
Sprout's own no-AI/no-transcript behavior from the chosen assistant's retention.

Machine-readable evidence and candidate hashes:
`docs/Recipient_Readiness_2026-09-11.json`. Hashes bind the local candidate bytes;
they do not attest publisher identity or reproducibility.

Docker diagnostics did not yield a usable engine. Bounded `_ping` and `/version`
socket requests returned empty HTTP 200 bodies rather than a valid version
response. No engine restart or unrelated process termination was performed.

## Toolchain provenance

The official Swift documentation says macOS-to-static-Linux builds require the
matching open-source Swift toolchain, not the Xcode toolchain. Both were downloaded
as public artifacts into `.build/linux-toolchain`; nothing was installed globally.

- Swift version: 6.2.4, macOS toolchain package from download.swift.org.
- SDK: `swift-6.2.4-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz`.
- SDK SHA256: `24bdf84495dd31a6de2eb679647c1982b747bfbfe1a2060c779d84dcecd902a4`,
  matched the official installation page before extraction.
- Host `pkgutil --check-signature` verified a notarized package from
  `Developer ID Installer: Swift Open Source (V9AUD2URP3)`.
- Signature evidence: `.build/linux-toolchain/signature-check-host.txt`.
  The earlier sandbox check reported an invalid signature; the repeated host
  check succeeded. Keep this distinction rather than treating the sandbox result
  as a verified compromise or silently ignoring it.
- Compiler:
  `.build/linux-toolchain/expanded/swift-6.2.4-RELEASE-osx-package.pkg/Payload/usr/bin/swift`.
- SDK directory: `.build/linux-toolchain/sdks`.

Sources checked on 2026-09-11:
[Static Linux getting started](https://www.swift.org/documentation/articles/static-linux-getting-started.html),
[Swift macOS installation](https://www.swift.org/install/macos/).

## Live staging evidence and hard stop

Only public, unauthenticated GET requests were made. No keys, preferences,
profiles or user data were submitted; the service can observe the request IP.
Evidence is under `.build/recipient-readiness/`.

- `/health`: HTTP 200, `status: ok`.
- `/haven/api/assistant-correspondence/v1/health`: HTTP 200, `status: ready`,
  `authority: messages-only`, `ed25519-device-proof+entity-access-credential`.
- `/.well-known/haven-scaffold-admin-trust-root.json`: HTTP 200, but
  `expires_at: 2026-09-07T19:58:50Z`, already expired at verification.
- Descriptor ID:
  `trd_staging_haven_digipomps_org_1782744225-renew-20260808t195850z`.

The descriptor must be renewed through the authorized operator workflow.
Do not extend validity locally, rotate a pin silently, use an unrelated admin key,
or weaken checks. A health response does not prove enrollment, Entity storage,
Bridge access, encrypted delivery or attachment support.

## Actual person-enrollment gap

Selected server and Binding source inspection agrees with the other task:

- `CellScaffold/Sources/App/Controllers/VaporIdentityLink.swift`: `/link`
  requires an authenticated FidoUser. `POST /link/api/ticket` is issued from the
  authenticated human side; it is not a terminal-initiated rendezvous contract.
- Enrollment requests depend on a previously issued ticket; knowing a URL,
  Entity ID or nearby offer does not prove person authority.
- Binding's identity-link flow handles CellBase enrollment/approval contracts.
  The nearby companion uses Apple Network and is not a Linux enrollment client.
- No implemented and approved CLI device-code, browser callback or equivalent
  fileless terminal person-enrollment contract was found.

Do not manufacture an OAuth endpoint, copy browser cookies, scrape a passkey
session, substitute an owner/admin/service key, or present opening `/link` as
successful enrollment. A new server/UX contract plus human review is required.

## Cross-task candidates and baseline

This checkout remains dirty on `main` at
`473d6998bf5417c6355de053fe806ebdf91383e6`; user-existing requested-capability
edits and unrelated documentation/worktrees are preserved. No commit was made.

The other task reports Sprout candidate `d2dcfa2` on baseline `d5a70f3`, draft
[Sprout PR 2](https://github.com/Digipomps/Sprout/pull/2), and passing CI run
34619683027. Those are other-candidate results, not execution of this checkout's
static artifact. Its `entity connect` launcher, SproutMacOS support and CLI file
rename are not merged here. Integrate the two CLI dispatches deliberately.

Follow-up from that task: `d2dcfa2` has a reproduced companion-discovery bug.
`sprout nearby --help` finds adjacent `haven-nearby` when launched with an
absolute executable path, but reports `helperNotInstalled` under ordinary PATH
launch. The reproduction used a copied CLI and synthetic companion in a temporary
directory, not a real person enrollment. The fix is now delivered in commit
`4a5b3efdd8c135ff5cfd75123f484aaba55b1beb` (PR 2): `PersonEntityCommands.swift`
uses `_NSGetExecutablePath` and resolves launch symlinks; explicit
`SPROUT_NEARBY_HELPER` remains supported. This task inspected the commit and
independently ran `Scripts/test_nearby_companion.py` against that candidate's
existing `.build/debug/sprout`. All five process checks passed: absolute launch,
PATH launch, PATH symlink, relative override, missing override refusal. These
are macOS launcher checks with a synthetic helper, not device enrollment or a
rebuild of the candidate. The owning task subsequently confirmed that CI
34630426281 passed for this commit on Linux (6m47s) and macOS (2m35s), including
the new installation regression. This remote result is reported by the owning
task, not independently queried here. It verifies that candidate's build/tests
and companion lookup, not this checkout's separate static recipient package or
fileless Linux person enrollment. The fix is not imported into this checkout.

Its baseline uses swift-crypto 4.5.2; this candidate uses the unchanged
Package.resolved pins swift-crypto 3.15.1 and swift-asn1 1.5.1. This is a known
integration difference, not evidence of compatibility or a security audit.
Resolve it and rerun all checks on one final commit before delivery.

Related candidates: Binding PR 32 and CellScaffold PR 241 are reported by the
other task; source review and unit tests do not establish physical passkey,
two-device approval or deployed integration. Its durable runbook is
`Binding/Documentation/Personal_Entity_Link_Test_Runbook_2026-09-11.md` in HAVEN.

## Delivery gates

1. Agree and implement the fileless terminal-initiated person enrollment
   contract, preserving exact domain, subject key, requested action, one-use
   challenge, expiry and human approval. This is the substantive missing feature.
2. Integrate Entity-owned invitation/proof read AND authorized write on the
   deployed Cell path. The September 10 daemon slice only proves read access for
   an already enrolled device; do not relabel it as complete enrollment.
3. Renew staging's trust-root descriptor with operator authority, then test
   denial, expiry, wrong key/domain/Entity, replay, interruption and revocation.
4. Run actual Linux artifacts on native Linux, including HTTPS, restart,
   approval and an actual two-person encrypted message/attachment round trip.
5. Build one reviewed immutable source tag, resolve baseline differences, sign
   with the expected release workflow, and independently verify artifacts.
   Bit-for-bit reproducibility has not been demonstrated.

## Reusable recipient prompt

```text
Help me use a verified Sprout release for a private HAVEN Correspondence channel.
First verify the release publisher and checksum without executing an unverified
download. Run sprout doctor, then use its terminal onboarding. Explain permissions
before I approve them. Never request pasted keys, cookies, invitation/proof files
or passwords. Keep existing identity state after an error. Do not confuse a local
draft, an opened browser, a health check or identity verification with a working
channel. If person enrollment is unavailable, stop and identify the missing step.
```

## Reusable implementation prompt

```text
Continue from Recipient_Readiness_2026-09-11.md, Terminal_Onboarding_2026-09-11.md
and Entity_Correspondence_Implementation_2026-09-10.md. Inspect current git status
and coordinate with the Entity-continuity task before editing common CLI files.
Status sharing is approved. Publication, deployment, owner signing and real user
actions still require their applicable approval. Implement the missing fileless
Linux person-enrollment server/UX contract, not a fake CLI endpoint. Reuse actual
CellProtocol contracts and enforce Agreement/Grants/purpose in Cells. Preserve
domain-scoped keys, explicit human review, exact-envelope binding and fail-closed
expiry/replay/revocation checks. Invitations/proofs stay under the target Entity's
normalized correspondence.v1 paths. Integrate candidate baselines, run one final
native Linux end-to-end user path, and document exact artifacts and limitations.
Do not claim ready or publish while any delivery gate remains unmet.
```
