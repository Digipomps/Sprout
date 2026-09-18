# Linux Correspondence Readiness

Assessment date: 2026-09-09.

Correction, 2026-09-10: this audit inspected the older client under Binding.
The standalone HavenAgentD repository has a newer encrypted, CellProtocol-native
client. Its transport and diagnostic behavior differ. See
[the Entity-owned implementation report](Entity_Correspondence_Implementation_2026-09-10.md)
before using the findings below as current implementation guidance.

## Decision

A downloaded Sprout binary does not currently provide a working Linux
Correspondence setup. The shortest path is a narrow Linux port of the existing
HTTPS Correspondence MCP client against the hosted HAVEN mailbox, followed by
signed distribution and explicit onboarding. Running a full local CellScaffold
is not necessary for this first use case.

This is an implementation and packaging gap, not a need to invent the messaging
protocol. It is also not yet a one-command installation task. A reliable time
estimate requires a first clean Linux build and the intended distribution,
CPU architecture and client experience. Ordinary human chat UI is a different
deliverable from the existing AI-assistant MCP integration.

## Evidence Snapshot

The following are source-inspection or live metadata results, not a Linux
acceptance certificate.

| Component | Observed state | Consequence |
| --- | --- | --- |
| Sprout source/build configuration | Current release workflow includes Ubuntu 22.04, Swift 6.0, build/test/signing and platform-suffixed assets. The documented baseline is x86_64. | A Linux release path is implemented in source; current Linux execution was not tested in this assessment. |
| Published Sprout release | Authenticated GitHub inspection returned only v0.1.1, published 2026-03-08. Assets are unsuffixed `sprout` and `sprout-updater` plus verification material. Its successful release revision uses `runs-on: macos-latest` only. | Do not present this release as the Linux download. |
| Download/source access | GitHub reports `Digipomps/Sprout` as private. | A friend needs explicit repository access or a separately authorized distribution channel. Do not make source public as an incidental fix. |
| Software discovery | Sprout supports signed catalog fetch, verification and artifact selection. | These commands do not install a client or configure an MCP host. |
| Hosted software catalog | A read-only GET to the staging well-known catalog returned HTTP 404: `CellScaffold executable catalog is not configured.` | Source support is not a deployed, populated download catalog. Other domains were not checked. |
| Updater | `sprout-updater` emits an `operator-applied` install plan. | Installation must remain separately authorized; do not introduce implicit Sprout self-mutation. |
| Hosted Correspondence | Public staging health returned `status=ready`, `authority=messages-only`, and `authentication=ed25519-device-proof+entity-access-credential`. | The route is available, but health does not prove enrollment or a message roundtrip. |
| Correspondence protocol/client | Enrollment, approval refresh and four MCP message tools are implemented. Requests use HTTPS POST and per-device signing. | Reuse the existing contracts instead of inventing a second messaging protocol. |
| Linux client | The executable imports Darwin unconditionally and depends on the broad `HavenAgentRuntime`, which also contains unconditional Darwin and macOS runtime facilities. HTTP client imports need Linux review. Default profile paths are under `Library/Application Support`. | There is no demonstrated clean Linux client build/install path. Isolate the portable dependency slice. |
| Identity storage | `AgentIdentityStore` uses Keychain on Apple but already has a non-Apple file-seed fallback with directory/file permissions 0700/0600. | Linux key storage is not absent. Its at-rest protection, persistence, recovery and user disclosure still need explicit review and tests; file permissions are not Keychain-equivalent protection. |
| Onboarding | The public page downloads an invitation JSON and instructs the user to run an already installed client. | It is not a Linux installer or a general chat interface. |
| Full scaffold streaming | Sprout's non-Apple `WSSChannel` throws unsupported transport. The CLI join bridge connector currently only checks that the endpoint parses as a URL. | Bootstrap state is not proof of an established streaming bridge. These gaps matter for a full node, not for the existing HTTPS mailbox client. |

## Recommended Delivery Slices

1. **Linux client pilot.** Extract or isolate Correspondence contracts, signing,
   identity storage, MCP framing and HTTP access from the macOS automation
   runtime. Fix OS imports and paths. Build and run on the friend's actual
   Linux/CPU combination. Review the existing file-key fallback rather than
   claiming that changing `import Darwin` alone completes the port.
2. **One explicitly approved peer channel.** Create a dedicated invitation and
   profile when requested. Enroll the friend's own device key and Entity
   reference, have the owner approve scoped access, and configure both
   directions of allowed peer communication. This is not linking the friend's
   identity into the owner's Entity, and needs no identity-key sharing.
3. **Usable, trusted distribution.** Publish an accessible Linux build with
   checksums, signatures and identified source revision, then populate a signed
   catalog. Add a consented installer/setup adapter around Sprout's existing
   discovery/verification and separate install authority. Preserve existing
   MCP settings and use a distinct profile. Provide short end-user instructions.

The first two slices can be a supervised pilot without completing all of slice
three. A full autonomous scaffold member with Linux streaming bridges is a
separate, larger milestone. Do not make it a prerequisite for two people using
the hosted mailbox.

## Acceptance Gates

- A clean supported Linux machine can install and run the intended binary,
  without an undeclared Swift runtime/dependency prerequisite.
- Artifact verification rejects modified bytes and validates the intended
  signing identity. Independent source rebuild verification is reported
  separately: signatures alone do not prove reproducible builds or an untampered
  remote running process.
- Device identity survives restart without leaking a private seed into an
  invitation, profile export, log or assistant context.
- Before approval, message operations are denied. Wrong keys, expired/revoked
  grants, disallowed peers and replayed requests are rejected.
- With explicit participant consent, test send/list/read/ack in both directions,
  retry/idempotency, an offline recipient and a restart. Record secret-safe
  receipts, not private message bodies.
- A diagnostic health probe must not read inbox metadata. The current client
  `doctor` performs `inbox.list`; it is not a privacy-neutral health check.
- Document that HTTPS is not end-to-end message encryption. The hosted service
  operator/storage administrator can technically access message content.
- Document that persistent storage does not wake or run a sleeping local
  assistant. Automatic polling/notifications require their own adapter and
  permission boundary.

## Source Map

Paths are relative to sibling repositories under the HAVEN checkout.

| Repository/path | Evidence anchor |
| --- | --- |
| `sprout/.github/workflows/release.yml:99` | Current Linux build job. |
| `sprout/docs/linux_deployment.md` | Narrow Linux baseline and operator install/update. |
| `sprout/docs/executable_catalog_distribution.md` | Signed catalog, selection and explicit no-install boundary. |
| `sprout/Apps/sprout-updater/Sources/sprout-updater/main.swift` | Operator-applied installation plan. |
| `sprout/Apps/sprout-cli/Sources/sprout-cli/main.swift:295` | Current join bridge connector URL check. |
| `sprout/Packages/SproutTransport/Sources/SproutTransport/WSSClient.swift:44` | Non-Apple streaming unsupported. |
| `Binding/HavenAgentD/Package.swift` | Correspondence dependency on HavenAgentRuntime. |
| `Binding/HavenAgentD/Sources/HavenCorrespondenceMCP/HavenCorrespondenceMCPMain.swift:1` | Darwin import, setup/activate/doctor/serve commands. |
| `Binding/HavenAgentD/Sources/HavenCorrespondenceMCP/CorrespondenceClient.swift` | HTTPS transport, enrollment and signed message requests. |
| `Binding/HavenAgentD/Sources/HavenCorrespondenceMCP/CorrespondenceContracts.swift:191` | macOS-style profile path. |
| `Binding/HavenAgentD/Sources/HavenAgentRuntime/AgentIdentityStore.swift:353` | Platform key-storage selection; file backend is defined earlier. |
| `Binding/HavenAgentD/Sources/HavenAgentRuntime/AgentRuntime.swift:1` | macOS runtime dependency surface. |
| `Binding/HavenAgentD/Packaging/Resources/ASSISTANT_CORRESPONDENCE.md` | Four message tools, owner approval, privacy and offline behavior. |
| `Binding/HavenAgentD/Tests/HavenCorrespondenceMCPTests/CorrespondenceMCPTests.swift` | Enrollment/profile-secret handling and signed MCP sends in test source. |
| `CellScaffold/Sources/App/Controllers/VaporAssistantCorrespondence.swift` | Health, onboarding and HTTP routes. |
| `CellScaffold/Sources/App/Cells/Agent/AssistantCorrespondenceCell.swift` | Access credentials, peer policy and messaging. |
| `CellScaffold/Tests/AppTests/AssistantCorrespondenceCellTests.swift` | Signed roundtrip, replay, persistence, approval and key-isolation test source. |
| `CellScaffold/Tests/AppTests/AssistantCorrespondenceOnboardingRoutesTests.swift` | Recipient-bound invitation tests. |
| `CellScaffold/Tests/AppTests/AssistantCorrespondenceAdminRoutesTests.swift` | Approval and device-bound proof tests. |

## Verification Record And Limits

- Local HEADs: Sprout `473d6998bf54`, Binding `775fc93db713`, CellScaffold
  `1dbdee23f527`, CellProtocolDocuments `f6aa54460d82`. Source inspection uses
  current working-tree content, not a claim that every inspected byte is in HEAD.
- Sprout had five existing modified Swift files and existing untracked work.
  None was changed for this assessment.
- GitHub was checked using `gh release list`, `gh release view v0.1.1`,
  `gh repo view` and `gh run list --workflow release.yml`.
- Published release: <https://github.com/Digipomps/Sprout/releases/tag/v0.1.1>.
  Successful release run: <https://github.com/Digipomps/Sprout/actions/runs/22821360489>,
  revision `701089193841e42d07caebb839481b87a153c6a8`. The workflow at that
  revision was read using local `git show`. Binary contents were not downloaded
  or executed. Signature verification was not rerun.
- Public, unauthenticated GETs only:
  <https://staging.haven.digipomps.org/haven/api/assistant-correspondence/v1/health>
  and <https://staging.haven.digipomps.org/.well-known/haven-executable-catalog.json>.
- No invitation was created, no participant profile or inbox was read, and no
  messages were sent or acknowledged. No server configuration was changed.
- Test sources were inspected but no builds, tests or Linux execution were run.
  Existing test names are not evidence that the tests passed today.
- The February ChatGPT ZIP remains historical; see
  `HAVEN_ChatGPT_Package_Relevance_Audit_2026-09-07.md`. It should not be the sole
  input for implementing this September integration.

## Reusable Implementation Prompt

> Implement a minimal Linux HAVEN Correspondence client pilot using the current
> source repositories and this readiness assessment. First confirm the target
> Linux distribution/CPU and whether the user wants an MCP-connected assistant
> or ordinary chat UI. Reuse the existing signed HTTPS enrollment and messaging
> contracts. Isolate the portable client from macOS automation, explicitly review
> non-Apple key storage, and preserve device-bound, owner-approved, messages-only
> access. Do not merge two people's Entities, copy private keys, or grant remote
> execution authority. Keep Sprout discovery/verification separate from
> consented installation. Produce a Linux-tested artifact, verification steps,
> a short end-user guide, a developer setup guide and secret-safe acceptance
> evidence. Ask for authorization before creating real invitations, changing
> deployed grants, publishing artifacts or sending test messages. Document every
> remaining gap; distinguish source implementation, released assets, live health
> and demonstrated end-to-end behavior. Do not claim full scaffold membership,
> end-to-end encryption, reproducible builds or automatic assistant wakeup unless
> separately implemented and verified.
