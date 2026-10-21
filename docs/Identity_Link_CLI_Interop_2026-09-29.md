# Portable Sprout IdentityLink client — 2026-09-29

The CLI uses HAVEN's existing signed IdentityLink ceremony to link its already
created scaffold-domain Ed25519 key to an existing Person Entity. It does not
create an Entity, approve a passkey, grant a cell capability, or install a
scaffold. The owner must log in on the same HTTPS origin's `/link` page, share a
short-lived invitation, compare the four locally computed control words and
approve the exact request with a passkey.

## Authority and persistence

`IdentityLinkClient.prepare` requires a currently valid descriptor and the
existing pinned admin key, validates the invitation's HTTPS origin/domain and
fixed rendezvous route, then signs with the existing `StarterIdentityStore`
domain seed. A persistent UUID/public descriptor is stored in that domain's
private `identity-link.json`; the seed is neither replaced nor exported.

The request uses the established `private` and `scaffold` operation domains,
`sprout-cli` identity context and `same_entity` scope. The scaffold host remains
the ticket audience; it is not an operation domain. Possession of an invitation
alone has no identity authority.

`submit` sends the exact signed request. `poll` performs one bounded request and
returns nil for HTTP 202; caller polling remains bounded by the ticket expiry.
The client verifies the approval and credential signatures, request/key/scope
bindings, same origin, presentation challenge and WebAuthn evidence linkage.
The server independently verifies the passkey against the owner's actual
credential store and commits the link through the existing EntityAnchor gate.

Before completion is sent, the exact signed holder presentation is retained.
An ambiguous reply can be retried byte-for-byte, including after an approval
expires if the server has already prepared durable evidence. Such a retry does
not locally extend authority: the server decides whether recovery is authorized.
Saved completion signatures, holder and verifier context are revalidated before
retry. On success the ceremony data are removed, retaining the public descriptor,
`evidenceReference` and `linkID` in private state. Corruption fails closed.

A local completion can outlive the server's ticket without ever having reached
its durable journal. To avoid an endless retry loop, an actual HTTP 404 or 410
from an exact retry, together with an expired saved ticket, enables a bounded
restart choice. The CLI must obtain explicit user confirmation before calling
`archiveExpiredCompletionForNewInvitation` on the same client instance. The
client holds an internal permit bound to the domain, state directory, request
hash and exact state bytes; callers cannot supply a status code to manufacture
that permit. Fresh tickets, timeouts and 5xx failures do not enable restart.

Restart writes the full previous state verbatim to the private domain directory
`identity-link-recovery/<requestHash>.json` before clearing active pending and
completion fields. It never deletes the archive, replaces the seed/UUID, erases
a completed receipt or establishes Entity access. A changed checkpoint is
rejected. An archived attempt may already have completed on the server: HTTP
404/410 is not treated as proof that it had no effect, and the archive preserves
material for later investigation/recovery. The owner's authenticated device
list and current signed resolution remain authoritative. A new invitation
still requires a fresh request and independent passkey approval.

The resolver possession proof uses `PersonLinkProof`, the existing read-route
proof schema, action `sprout.entity.resolve.v1`, operation domain `private`, exact
HTTPS origin as audience and a 60-second nonce challenge. Its resource hashes
all resolution intent fields, admin key, evidence reference, link ID and any
optional legacy evidence. Neither this proof nor the local receipt grants
GeneralCell access.

## Exact canonicalization matters

Source contracts: CellProtocol `81601a6`,
`Sources/CellBase/Identity/IdentityLinkingModels.swift`,
`IdentityLinkCompletion.swift`, `IdentitySigningChallenge.swift`,
`Sources/CellBase/Crypto/CryptoAgilityModels.swift`, and
`Sources/CellBase/VerifiableCredentials/{VCClaim,VCPresentation}.swift`;
CellScaffold `adf48d46`, `IdentityLinkRendezvousStore.swift`,
`VaporIdentityLink.swift` and `PersonEntityReadRouteContract.swift`.

There are three deliberately different encodings; do not combine them or accept
alternate signatures as a compatibility fallback:

| Signed payload | Canonical bytes |
| --- | --- |
| Enrollment request / approval | Foundation `JSONSerialization.sortedKeys`, excluding top-level `proof`, with escaped slashes. Sorting is case insensitive: `requestedDomains` precedes `requestID`. |
| Credential / holder presentation | `JSONEncoder.sortedKeys.withoutEscapingSlashes`, excluding only top-level `proof`. Sorting is lexical: `linkType` precedes `linkedIdentity`; the embedded credential's proof remains included. |
| Identity signing challenge | `JSONEncoder.sortedKeys`, retaining default slash escaping. `publicKeyFingerprint` is the literal `EdDSA:Curve25519:` plus standard padded base64 public key, not its digest. |
| Sprout resolution resource binding | Sprout JCS, SHA-256 and unpadded base64url. |

An independent Python fixture first exposed an incorrectly shared
JSONSerialization helper for VC signing. It was corrected before deployment;
all positive signatures now use the one encoding required by their protocol.
The fixture generator explicitly models the request/approval case-insensitive
ASCII field ordering. It is scoped to these typed wire models, not a general
Foundation collation implementation.

`Tests/SproutCoreTests/Fixtures/IdentityLink/generate.py` uses Python and
cryptography 50.0.1 to generate synthetic Ed25519 keys, canonical payloads,
request/approval/credential/presentation signatures and the resolve proof.
`identity-link-v1.json` contains public test seeds only. They must never be used
for real enrollment. Both the CLI suite and CellScaffold's CP interoperability
suite can consume this same fixture. No Swift implementation under test produces
its expected cryptographic bytes.

## Validation status

The dedicated macOS suite covers independent fixture verification, Ed25519 and
P256 issuer signatures (compressed and X9.63 public keys), changed request fields,
wrong origin/key/scope/proof, expiry, receive-time 64 KiB response limit, redirects,
full HTTP composition with synthetic owner approval, unchanged seed/UUID,
receipt reload, corrupt persistence, exact retries after lost replies, explicit
404/410 recovery archival, key/UUID preservation and refusal to reset after
ambiguous failure or erase a receipt that appeared during the confirmation gap.

The WebAuthn assertion in the fixture is synthetic: this is not a performed human
passkey test. Linux execution of the same fixtures and actual CellProtocol
verification are required before claiming cross-runtime acceptance. See the
session's final test logs for those results; this document does not pre-claim
unperformed checks.


## Verification checkpoint — 2026-10-12

Last verified against code and live staging: 2026-10-12. The portable client
passed 193 ordinary tests on macOS (Swift 6.4) and Linux (Swift 6.2.4), plus eight
CLI process checks per platform. A real Linux request exposed a FoundationNetworking
per-request URLSession teardown crash missed by the mocks. Production now uses
fixed hardened process-lifetime sessions with session-level task dispatch;
onboarding keeps 20/45-second and person linking 20/30-second timeouts.
Declared oversized bodies call task.cancel in addition to rejecting disposition.
Four socket tests passed in three fresh processes on each platform, including
concurrent responses, cookie isolation, redirect refusal and observed disconnect.
Run them with `python3 Scripts/test_http_transport.py -- swift test --skip-build --filter BoundedHTTPNetworkTests`.
Explicit injected sessions retain their isolated implementation; real-network
Linux teardown on that path is not certified. Foundation's internal 3xx body
buffer is not covered by the streaming collector's size limit.

CellScaffold PR289 merged the server repair (tested head f47256c, merge 8861090).
Live staging App 9ff06f8/CP b4100f5 contains that repair. The real static CLI now
reaches the invitation prompt, exits 0 on pause and resumes with unchanged test
keys and awaitingApproval. No real person invitation, passkey approval or final
identityVerified has been performed. The current staging descriptor expires
2026-10-27T12:00:00Z; this is dated evidence, not a permanent trust pin.
