# Operator-bound Scaffold trust-root migration

User intent: «Reparer det som må repareres. Sjekk hva som har blitt gjort i det
siste med entitetsutvidelse.» This follows the reviewed diagnosis that staging's
expired public descriptor has a different signer from its active runtime owner.
Same-key renewal cannot repair that mismatch. This implementation creates a
reviewable replacement public descriptor; actual publication belongs to the
separately authorized staging operation.

## Purpose and observable contract

| Purpose | Required outcome | Verification |
| --- | --- | --- |
| `purpose://scaffold.operations` | Produce a valid v1 descriptor signed by the explicitly pinned current owner, preserving domain and endpoint/catalog strings. | Migration API and actual CLI success tests; independent verification of output signature/hash. |
| `purpose://access.audit.privacy` | Reject stale/ambiguous vaults, unrelated owners, forged public input, missing authority pins and unreviewed key sets. | Negative API/CLI tests for every binding, schema, key role, input hash, flag and output collision. |
| `purpose://scaffold.operations` | Keep the ordinary v2-loader refusal and leave all input files untouched. | Generic-loader refusal regression plus vault/key/input byte comparisons. |

The operator sees a new JSON file and a public JSON summary on stdout. The command
does not expose v2 identities/private keys, mutate the vault, discover authority
from the network, create new keys, restart services, or publish anything.

## Independently establish the pins

These are mandatory trusted operator inputs. Verify them against the **active**
runtime, its successful owner/manifest gate, and its exact mounted vault revision.
Never infer them from the old public descriptor or from an arbitrary candidate
vault. Only select required metadata; do not dump environment or decrypted vaults.

- `CELL_SCAFFOLD_OWNER_UUID`, `CELL_SCAFFOLD_OWNER_CONTEXT`, and
  `CELL_SCAFFOLD_OWNER_SIGNING_KEY_FINGERPRINT` must agree with the current
  manifest's `payload.bindings` entry whose `registryID` is `owner.scaffold`,
  the manifest signer, and `payload.effectiveOwnerContext`.
- The selected owner binding must be `present`. A `compatibility.scaffold-exact`
  entry does not establish ownership. This command accepts only the explicitly
  pinned `Scaffold` owner context.
- The exact encrypted vault bytes must match the active manifest's
  `payload.vaultRevision.fileDigest` (lowercase hexadecimal SHA256). Bind the
  manifest to the current release and verify runtime readiness separately.
- Review the old public descriptor bytes and record their lowercase SHA256.
- Independently verify and explicitly approve every current resolver and
  bridge-owner public key. The command never fills these lists from defaults.

The current-owner fingerprint is:

```text
base64url_without_padding(SHA256(UTF8(
  "EdDSA:Curve25519:" + standard_base64_with_padding(raw_32_byte_public_key)
)))
```

It is **not** SHA256 of the raw public key. This distinction prevented a false
comparison during diagnosis; the correct calculation then confirmed an actual
old-versus-current signer mismatch.

The trust boundary is explicit operator attestation of already verified runtime
pins. The command does not independently validate the complete owner-signed
runtime manifest, release evidence, migration interlock, or live readiness.
For unattended discovery, those checks would need their own verified integration.
Possession of a candidate vault, descriptor, or UUID alone is insufficient.

## Run the separate migration command

Build the operator binary first:

```sh
swift build --product sprout-admin --skip-update
```

The variables below represent freshly reviewed **public pins and file paths**;
do not set them from examples or derive owner pins from the candidate vault. The
master key stays in its existing protected file and never appears in argv.

```sh
.build/debug/sprout-admin scaffold-trust-root migrate-from-pinned-v2-vault \
  --descriptor "$REVIEWED_OLD_DESCRIPTOR_FILE" \
  --expected-descriptor-sha256 "$REVIEWED_OLD_DESCRIPTOR_SHA256" \
  --scaffold-domain staging.haven.digipomps.org \
  --expected-owner-uuid "$VERIFIED_ACTIVE_OWNER_UUID" \
  --expected-owner-context Scaffold \
  --expected-owner-fingerprint "$VERIFIED_ACTIVE_OWNER_FINGERPRINT" \
  --expected-vault-sha256 "$VERIFIED_ACTIVE_VAULT_SHA256" \
  --vault-file "$VERIFIED_ACTIVE_VAULT_FILE" \
  --master-key-file "$VERIFIED_ACTIVE_MASTER_KEY_FILE" \
  --resolver-public-keys "$REVIEWED_RESOLVER_KEYS_CSV" \
  --bridge-owner-public-keys "$REVIEWED_BRIDGE_OWNER_KEYS_CSV" \
  --descriptor-id "$REVIEWED_NEW_DESCRIPTOR_ID" \
  --expires-at "$REVIEWED_NEW_EXPIRY" \
  --out "$NEW_REVIEW_ARTIFACT_FILE"
```

All flags shown are required. Duplicate/unknown flags and absent values fail.
There is no clock override or automatic vault/path/key-list fallback. Expiry must
be after actual issuance and at most 30 days later. The new ID must differ from
the old ID; this command also requires a genuinely different signer.

The operation hashes the old public input, verifies its domain and historical
signature, and validates its dates. It hashes one bounded snapshot of the
encrypted vault **before** decryption. Only `haven.vapor-identity-vault.v2` with a
positive file version is accepted, with unique identity UUIDs and contexts and
consistent Ed25519/X25519 raw keys and `SecureKey` roles. It selects the exact
pinned UUID/context and verifies the canonical fingerprint digest before signing.
No identity-returning v2 loader is exposed. Ordinary `VaporVaultDecoder` APIs
still reject current v2 input.

The resulting v1 descriptor preserves version, scaffold domain, all endpoint
strings and optional catalog. It deliberately changes admin key, reviewed
resolver/bridge key arrays, ID, issuance, expiry, and signature. The command
refuses existing output files, including input/vault/key collisions. Stdout
reports the exact new output-file SHA256, old descriptor SHA256, encrypted vault
SHA256, current-owner fingerprint digest, domain, ID and dates.

## Publication boundary

Before publishing, compare the new artifact against the reviewed change and
verify its signature against the independently pinned current owner. Refresh
runtime/manifest/vault pins if anything changed during preparation. Publish only
through the authorized staging procedure, retain the previous public artifact,
and check the served byte hash plus discovery and fresh onboarding behavior.

A new self-signature cannot prove continuity from the old signer. Clients that
pin the old key need the explicitly approved trust migration. Restoring an
expired/stale public artifact is not equivalent to restoring a working trust
chain; use the reviewed incident procedure for rollback.

## Source basis and tests

Current source inspection: CellProtocol `9c60001ac53abc35ba7ad6e2c0efa2a79ab2a366`,
`Sources/CellVapor/VaporIdentityVault.swift` (`StrictPersistedVaultDocument`,
`StrictVaultIdentityRecord`, key validation and CVLT1 encryption),
`Sources/CellBase/Identity/IdentitySigningChallenge.swift` (fingerprint), and
`Sources/CellBase/VerifiableCredentials/SecureKey.swift` (key-role encoding).
The vault implementation is unchanged from previously inspected `473357cf`.

```sh
swift build --product sprout-admin --skip-update
swift test --filter SproutAdminSupportTests --skip-update
```

`ScaffoldTrustRootMigrationTests` and `ScaffoldTrustRootMigrationCLITests` use only
synthetic encrypted complete v2 fixtures. Process tests honor
`SPROUT_ADMIN_TEST_BINARY` for a separately built operator executable. A supplied
invalid path fails; without an override, a missing debug binary causes an explicit
skip. Live staging verification is a separate parent-task result.

Local verification on 2026-09-29: operator build passed; the filtered
`SproutAdminSupportTests` run passed **42 tests, zero failures, zero skipped**,
including 9 new migration API tests and 5 new actual CLI process tests. The first
run caught a test expectation mismatch: padded Base64URL is rejected by existing
signature verification before signer comparison. The expectation was corrected;
validation was not relaxed. The full filtered rerun passed.
