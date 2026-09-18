# Sprout terminal onboarding

Updated: 2026-09-11. Status: implemented and locally verified; not released.

## Purpose and acceptance evidence

Purpose: let a person or their assistant start Sprout through a terminal
conversation, without moving credentials, invitation files, or proof documents.
Minimize questions without weakening the distinction between a local key,
an Entity association, scaffold ownership, and an authorized communication channel.

| Goal | Current result |
| --- | --- |
| Start with no required flags | `sprout`, `sprout onboard`, and `sprout chat` enter the same dialogue |
| Answer every onboarding question in the terminal | Entity intent, goal, purpose, interests, service hostname and consent are asked interactively; optional arguments are suggestions |
| Pause and resume without generating another identity | Versioned private checkpoint; `/pause`, `/quit`, EOF; OS process lock; regression and CLI tests |
| Avoid manual credential/proof exchange | Starter challenge fetched and signed in memory; Entity resolution requested over HTTPS; no invitation/proof export or import |
| New start without an existing account | A local Ed25519 identity and explicitly non-authoritative Entity draft reference are created after local-storage consent |
| Attach this device to an existing Entity | Preference captured, but device approval/admission creation is NOT wired; unresolved status stops explicitly |
| Let an assistant operate the tool | Line-oriented stdin/stdout, immediately flushed prompts, no LLM/API-key dependency or persisted chat transcript |
| Actually open a channel with another person | NOT implemented by this slice; requires approved device identity, Entity Cell access, Agreement/Grants and real transport |

## User walkthrough

Build with `swift build --product sprout`, then start `.build/debug/sprout`.
After a release provides an installed binary, the entrypoint is simply `sprout`.
This work does not claim such a new release has been published.

1. Sprout explains exactly what it keeps locally and asks for permission.
2. Choose a new local draft or an intended association with an existing Entity.
3. Describe the goal. The default purpose is `purpose://contact.communication`
   and the default interest is `correspondence`; both can be changed in the chat.
4. Enter the hostname of the intended scaffold, or choose `senere` to stay offline.
5. Review the answers. `endre` edits preferences without dropping keys or trust pins.
6. Separately approve fetching the public HTTPS service descriptor. No answers or
   public identity key are included in that GET; the server can see the IP address.
7. On first use, explicitly accept domain-based HTTPS trust. Sprout pins the
   advertised admin key and refuses silent replacement later.
8. Separately approve sending the displayed data to the displayed POST endpoints.
9. Sprout either reports local-only setup, pending Entity approval, or verified
   Entity association. None of those messages says the channel is connected.

`/help`, `/status`, `/pause` and `/quit` work at every question. EOF pauses without
approving the next action. Blank input may select a displayed preference default,
but never consents. There is no `--yes` or public-key-as-authentication bypass.

Optional example:

```sh
.build/debug/sprout onboard --domain example.test --entity-mode existing
```

`example.test` is an example, not a working HAVEN service. No production hostname
is silently selected. `--goal`, `--purpose`, `--interests`, and `--state-dir` are
also optional. A bare supplied Entity ID is intentionally not accepted as proof.

## Local persistence and trust package

Default storage is `$XDG_STATE_HOME/haven/sprout` when XDG_STATE_HOME is absolute,
otherwise `~/.local/state/haven/sprout`, independent of the current directory.
`--state-dir` is useful for isolated tests or deliberately separate installations.

| Data | Location and retention | Authority |
| --- | --- | --- |
| Local draft public key | `onboarding.json`; retained until deliberately deleted | Stable local draft reference only, never an actual CellProtocol Entity |
| Local private key | `identities/local.sprout.invalid/keys/ed25519.seed` | Local installation identity only; never sent to a service |
| Goal, purpose, interests, selected domain, intent | `onboarding.json`; no full transcript | User preferences, not grants or proof of ownership |
| Domain-specific private keys | `scaffold-identities/<domain>/keys/ed25519.seed` | Proof of possession of that key, not proof of a person's identity |
| Domain admin public-key pins | `onboarding.json` | Explicit HTTPS first-use trust; no independent global HAVEN attestation |
| Starter nonce, signed starter payload, inclusion proof | Memory during the approved HTTP operation only | Validated against the domain, subject key, trusted issuer and expiry |
| Last result enum | `onboarding.json` | Historical status only; never used as live authorization |
| Invitations and Correspondence proof records | NOT in local onboarding preferences | Must remain in the target Entity's authorized Cells |

Local-storage permission covers the keys, listed answers, pins and status, and
the dialogue explains indefinite local retention until deletion. Network consent
is separate and is requested again on every run; saved pins are not saved consent.
No request is made to an external AI provider by this feature. An independently
chosen assistant may have its own terminal/log retention outside Sprout's control.

Remote retention is not verified by Sprout and is explicitly disclosed as unknown
before POST. A server can retain the requests. This is not a machine-verifiable
personal-data trust receipt or a deletion guarantee. No real user's profile was
read, created, disclosed, or merged during implementation tests.

Files use mode 0600 and final private directories 0700. This is OS-user access
control, not encryption at rest or hardware-backed key storage. A process running
as the same OS user, backups, malware or root can access these files. Protect the
OS account and its backups. Do not ask people to paste keys into an assistant.

Do not delete an identity folder to repair a failed startup: it can strand an
existing identity. An ordinary retention/delete UI and safe recovery workflow are
not implemented here; deliberate deletion is a separate user-approved operation.

## Implementation map

- `Apps/sprout-cli/Sources/sprout-cli/main.swift`: default entry and aliases;
  legacy commands retained, including pre-existing requested-capabilities edits.
- `Apps/sprout-cli/Sources/sprout-cli/OnboardingCommand.swift`: strict optional
  arguments, state-root selection, stdin/stdout and safe error messages.
- `Packages/SproutCore/Sources/SproutCore/OnboardingDialogue.swift`: deterministic
  dialogue, checkpointing, separate consent gates, truthful completion statuses.
- `Packages/SproutCore/Sources/SproutCore/OnboardingProfile.swift`: versioned
  preferences bound to the local public key; no credentials or authorization artifacts.
- `Packages/SproutCore/Sources/SproutCore/OnboardingHTTPService.swift`: real
  existing trust-root, starter-auth and Entity-resolution HTTP clients, constrained
  sessions and exact inclusion-proof checks. Test doubles are injected only in tests.
- `Packages/SproutStorage/Sources/SproutStorage/PrivateStateFiles.swift`: private
  regular-file validation, no-follow reads and nonblocking process locks.
- `Packages/SproutStorage/Sources/SproutStorage/StarterIdentityStore.swift`:
  fixes the earlier `try? load` path that could regenerate a key after corruption.
- `Package.swift`: CLI uses `-parse-as-library` so `@main` in the retained
  `main.swift` works when adding the separate command source file.

## Security boundaries

1. Local draft != Entity != human owner != scaffold administrator. The new flow
   never calls `owner init`, `--overwrite`, mock resolvers, snapshot fixtures,
   or the legacy file-materializing `runBootstrap` path.
2. New/existing Entity selection records intent only. The existing resolver
   request contract does not implement initial owner-approved device enrollment.
   The flow checks whether the domain-specific key is already associated; it
   does not merge Entities, infer identity from names, or create backend admission.
3. The local draft key is kept separate from domain-specific keys to avoid
   automatically publishing the same device/person identifier across domains.
4. HTTP requests are restricted to HTTPS on the selected hostname, port 443.
   No userinfo, query credentials or fragments; resolver base must be origin-only.
   Cross-origin descriptor routes are rejected, not silently followed. Split-host
   deployments need a later explicit per-origin approval design.
5. Production URLSession is ephemeral, disables stored credentials/cookies/cache,
   rejects all redirects, and has 20-second request / 45-second resource timeouts.
   The three HTTP clients now stream through a collector capped at 1 MiB, reject
   oversized declared or chunked responses, propagate cancellation and reject
   redirects. This bounds collected response data, not all Foundation/TLS memory.
6. Descriptor signature/domain/expiry/version/issued time and pinned admin key
   are checked. A signed descriptor alone is NOT an independent trust anchor.
7. Starter intent context and signature, issuer trust, runtime, version, nonempty
   nonce and issued time are checked before signing with a persistent domain key.
   Server-side challenge single-use enforcement remains the server's responsibility.
8. A resolved Entity requires a valid signature, trusted resolver, matching
   subject key/domain, scaffold domain, Entity ID, anchor admin and no unrequested
   evidence contract. An expired, future-issued or forged proof is rejected.
9. Corrupt/missing metadata next to an existing key, mismatched public/private
   keys, unsafe file permissions/types, symlinked key files or a busy lock do not
   become first-run enrollment. DNS paths reject traversal and normalize case;
   legacy differently-cased folders require recovery rather than silent migration.
10. Checkpoint writes are atomic file replacements, not a distributed transaction
    or fsync-backed journal. Interrupted multi-file creation fails closed; total
    deletion/rollback of all local state cannot be detected without another anchor.
    Same-OS-user attacks and symlinked ancestors outside the private roots are not
    claimed to be solved by these helpers.
11. Remote error bodies and signed artifacts are not printed in chat errors.
    Network errors are distinguished from local corruption; nothing retries with
    weaker TLS, resets trust pins, or imports a file as a fallback.

## Entity-owned Correspondence integration

The earlier isolated implementation is described in
`docs/Entity_Correspondence_Implementation_2026-09-10.md`. Its normalized paths are:

```text
correspondence.v1.invitations.<lowercase-invitation-UUID>
correspondence.v1.proofs.<lowercase-contract-UUID>
```

Those records belong in the target Entity's Cells, with Agreement, Grants and
`purpose://contact.communication` enforcement, including the store permission.
Do not turn `onboarding.json` into a second source of truth for those records.
This dialogue does not yet write or fetch them; the earlier isolated daemon can
read them for an already-enrolled device using Entity mode.

Shortest remaining integration route:

1. Add/identify the actual owner-approved device enrollment/admission service
   operation. Bind a signed, expiring, one-use challenge to installation key,
   candidate domain identity, environment, intended Entity and requested action.
2. Show the approval on an already-authenticated device or its authorized
   assistant. A QR/device/network locator finds the request, but is not authority
   to merge Entities or assign scaffold ownership. Never approve a nearby device
   just because it shares a network. Keep staging/prod boundaries explicit.
3. Resume by querying the user's authorized Entity Cells rather than downloading
   or pasting contracts. Use the existing contracts and normalized namespaces;
   do not invent an endpoint without implementing and testing its server side.
4. Fetch the accepted invitation/proof in memory, evaluate the exact Agreement,
   Grants and purpose, then attach the real Bridge/daemon for Correspondence.
5. Prove two-device approval, denial, expiry, replay, revocation, restart and
   encrypted messages/attachments against the deployed service before claiming
   the friend can use it. Publish a separately verified and signed Linux artifact.

RFC 8628 is a design reference for secondary-device user approval and bounded
polling, not a replacement for HAVEN ownership proofs or an implemented endpoint:
[OAuth 2.0 Device Authorization Grant](https://www.rfc-editor.org/rfc/rfc8628.html).
This public standard was checked on 2026-09-11 without sending personal data.

## Verification

- Native macOS arm64, Apple Swift 6.2.4: latest hardening run passed 128 XCTest
  tests plus 6 Swift Testing tests. This adds bounded-response/cancellation and
  doctor tests to the earlier onboarding/identity recovery coverage.
  Logs: `.build/recipient-hardening-tests-final.log`.
- Real process stdin/stdout smoke passed via `bash Scripts/test_terminal_onboarding.sh`:
  no-argument entry, refusal, EOF, optional defaults, resume with unchanged seed,
  `/status`, rejection of `--yes`, corruption recovery guard. No network; disposable keys only.
- The HTTP integration test uses URLProtocol with signed synthetic responses and
  the actual production client composition. It is not a live deployment test.
- Redirect rejection is directly tested on the streaming collector and onboarding
  session delegates, including same-origin, cross-origin and HTTPS downgrade;
  not a real network redirect test.
- Linux/container verification was attempted with the previously installed
  `swift:6.2.4-noble` amd64 image, `--pull=never --network none`, read-only source
  mount and a separate writable `.build/onboarding-linux` scratch directory.
  Docker produced no output for over five minutes; a separate container-status
  query also hung. Only the two identified test/diagnostic client processes were
  terminated, not the Docker engine. Container state could not be inspected.
  Subsequently, the matching official open-source Swift 6.2.4 toolchain and
  static Linux SDK produced real static Linux x86_64 binaries for Sprout and
  the updater. ELF platform/linkage validation passed. Neither binary has yet
  executed on Linux; compilation is not runtime evidence. See the readiness
  report below for toolchain verification and the candidate location.
- No new release, signing, deployment or device pairing was done.

Reproduce on a configured build machine:

```sh
swift test --disable-automatic-resolution --jobs 4
bash Scripts/test_terminal_onboarding.sh
```

The implementation run used local cached git repositories for the exact
Package.resolved revisions of swift-crypto 3.15.1 and swift-asn1 1.5.1. No package
version changes were made. Dependency downloads may be required on a fresh machine.

## Reusable prompts

User/assistant prompt:

```text
Help me start Sprout in the terminal for a private Correspondence channel.
Use the interactive onboarding; explain each permission before I approve it.
Do not ask me to paste keys, proof files, invitation files or passwords.
Do not claim a local draft is an existing Entity or that identity verification
means a channel is connected. If device approval or server support is missing,
keep the current identity, pause, and explain the exact missing integration.
```

Developer prompt:

```text
Continue from docs/Terminal_Onboarding_2026-09-11.md and
docs/Entity_Correspondence_Implementation_2026-09-10.md. Inspect current source
and other active work before editing. Wire owner-approved device enrollment and
Entity-owned Correspondence into the terminal dialogue using actual implemented
Cell/service contracts. Preserve separate installation, domain identity, Entity,
scaffold-owner and delegated-agent authority. Bind approval to domain/environment,
subject key, intended Entity, action, expiry and a one-use challenge. Enforce
Agreement, exact Grants, purpose and retention in the Cells, not just in the CLI.
Keep invitation/proof records in the target Entity under the documented normalized
keypaths. Do not introduce file-paste fallbacks, mock membership, implicit merging,
silent trust rotation or unattended approval. Test denial, replay, revocation,
timeouts, process restart and both devices' real user paths. Document evidence,
remaining gaps and user/assistant prompts. Do not deploy or publish without approval.
```

## Durable handoff

- work_id: sprout-terminal-onboarding-20260911
- status: READY_FOR_REVIEW locally; release and live integration remain open
- repository: `/Users/kjetil/Build/Digipomps/HAVEN/sprout`
- base: `473d6998bf5417c6355de053fe806ebdf91383e6`, current branch `main`
- owner: current terminal-onboarding task; integrator: Kjetil/designated reviewer
- ownership: additive Onboarding files, CLI entry/help, Package.swift CLI setting,
  StarterIdentityStore hardening, new private storage helper, tests, smoke script,
  this report and README section
- pre-existing dirty code preserved: requested-capabilities edits in CLI/Core/
  ResolverAdapter/BootstrapStateMachineTests; existing docs/worktree directories
- no commit, push, deployment, live user identity, Entity merge or published artifact
- separate QR/Network Entity-continuity task works in an isolated Binding
  implementation copy. The user subsequently approved status sharing; progress
  and the specific integration gaps have now been exchanged successfully.
- integration collision surfaces: main.swift dispatch, Package.swift and key-store
  usage. This slice deliberately does not edit OwnerIdentityStore or QR/network APIs.

## Incoming integration note, 2026-09-11

The separate Entity-continuity task reports a candidate based on `d5a70f3` with
`entity connect [--place app|haven|staging]`, a `nearby` entry using
`haven-nearby-companion`, a new `PersonEntityCommands.swift`, an entry in
SproutMacOS, and a rename of `main.swift` to `SproutCLI.swift`. These were initially
incoming claims. Selected candidate and server sources have now been inspected,
but the changes have not been integrated into this checkout. Its stated
boundary is linking people's Entities, not Scaffold/admin/service keys. This is
consistent with this onboarding slice's authority separation.

Items to resolve when integration is authorized:

1. Preserve a single `@main` entrypoint. If adopting the candidate's filename
   rename, carry over this slice's no-argument/onboard/chat/help dispatch and the
   user's pre-existing requested-capabilities changes. Re-evaluate the CLI-only
   `-parse-as-library` setting after the rename rather than duplicating entrypoints.
2. Keep OnboardingCommand and PersonEntityCommands additive. A command opening a
   web approval surface is not evidence of completed Entity enrollment; completion
   must still verify the bound identity and approved service response.
3. Keep app/HAVEN/staging selection explicit and bind approval to the chosen
   environment, subject key and intended personal Entity. Network proximity alone
   is not consent or authority. Do not repurpose an admin/service key as a person.
4. Preserve private, domain-scoped starter storage and the corruption/rekey guards.
   Avoid adding CellProtocol to SproutCore merely to launch the separate companion.
5. Re-run the full tests and terminal smoke after combining CLI entrypoints, then
   verify a real two-device approval and denial path. The incoming note does not
   establish that this path or Linux distribution is ready.

Status sharing is now authorized and completed. The other task confirms that
`entity connect` opens an approval surface but does not establish terminal/Linux
person authority. No approved terminal-initiated device-code or loopback contract
was found. The existing nearby companion uses Apple Network, not Linux.

For current build evidence, expired staging metadata, source baseline differences
and the remaining delivery gates, read
[Recipient readiness](Recipient_Readiness_2026-09-11.md).
