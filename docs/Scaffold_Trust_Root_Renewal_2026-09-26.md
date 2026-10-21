# Scaffold trust-root renewal

The operator command renews an existing public `ScaffoldAdminTrustRootDescriptor`
using its existing encrypted Vapor vault `Scaffold` identity. It creates a local
public artifact for review. It does not publish the descriptor, update the vault,
rotate keys, change approved trust parameters, or make network requests.

**Current runtime limitation:** this command accepts the existing encrypted
legacy array payload only. The current CellVapor
`haven.vapor-identity-vault.v2` envelope is explicitly rejected with
`currentVaultRequiresOwnerBinding`; it is never unwrapped into the old signing
path. Do not substitute an older/shared vault to bypass this refusal. Current
vault support requires a separately reviewed active-owner binding path.
The separate, explicitly pinned migration operation is documented in
[Scaffold trust-root migration](Scaffold_Trust_Root_Migration_2026-09-29.md).
It does not change this renewal command or the ordinary v2-loader refusal.

CellScaffold image revision `4dd70c520dac2d8921229fed767533c05b1c574b` pins
CellProtocol `473357cf4efee831cb3b55ae87bc921d4bb63c10`. Its compose default is
`/app/CellsContainer/IdentityVaults/OrganisationIdentities.crypt`, with master key
`/run/secrets/cell-vault-master-key`. The owner is bound by configured context,
UUID, signing-key fingerprint, and the owner-signed runtime manifest. A literal
`Scaffold` context can otherwise be a compatibility identity, so it alone does
not establish the current owner. On 2026-09-26, the parent task's selective live
checks established that the public staging descriptor's signer differs from
the active owner. Same-key renewal cannot repair that mismatch; reviewed trust
migration and publication are separate work.

Build the command with the repository's resolved dependencies:

```sh
swift build --product sprout-admin --skip-update
```

Run it on the host that already holds the approved Scaffold vault. Set the
explicit expiry to a time after the current and previous expiry, at most 30 days
after the command runs. The example paths are placeholders; the output must be a
new file, separate from the served descriptor and vault files.

```sh
.build/debug/sprout-admin scaffold-trust-root renew-from-vapor-vault \
  --descriptor /operator-review/current-trust-root.json \
  --scaffold-domain staging.haven.digipomps.org \
  --identity-context Scaffold \
  --vault-root /app/CellsContainer \
  --expires-at 2026-10-20T12:00:00Z \
  --out /operator-review/renewed-trust-root.json
```

Optional `--vault-file` and `--master-key-file` select the existing encrypted
vault and master-key files. They accept paths, not private-key values. Optional
`--descriptor-id` selects a new nonempty ID; by default the command generates a
fresh UUID-based ID. There is no clock override or flag to replace domain, keys,
URLs, or catalog contents. Duplicate, missing-value, and unsupported flags fail.
Standard output contains public renewal metadata. Only the new public descriptor
is written, using exclusive creation so an existing destination is not replaced.

Before publication, compare the old and new JSON. Only `descriptor_id`,
`issued_at`, `expires_at`, and `signature` change. The Scaffold domain, admin key,
ordered resolver and bridge-owner key arrays, all endpoint strings, version, and
optional `software_catalog_url` are preserved. Formatting can change; a missing
or null optional catalog remains semantically absent. Unknown fields and versions
are rejected because this implementation cannot safely preserve their semantics.
An expired old descriptor can be renewed; ordinary discovery and bootstrap still
reject that expired descriptor. Publication remains a separate operator action.

## Security boundary

The protected action is signing a replacement trust-root descriptor for the
same Scaffold domain. Authority is possession of the existing `Scaffold` vault
signer and an authentic existing descriptor bound to the explicitly supplied
domain. Both the vault record's public key and the public key derived from its
private seed must match the descriptor signer. This is an administrative key
custody operation; it grants no separate resolver capability or access right.

Historical validation runs the existing descriptor validator at the descriptor's
signed issuance time, after checking that issuance and expiry form a valid
interval and that issuance is not in the future. This retains its URL, key-set,
domain, algorithm, and cryptographic checks. Runtime discovery still refuses
expired input. Signature errors and malformed expiry dates are now distinguished
from a genuine signed descriptor that has expired.
The renewed result passes that same validator at the actual renewal time.
Validity must extend the old expiry and fit within 30 days of new issuance,
matching the existing creation command's default lifetime as a conservative
operator renewal ceiling. A longer policy or key rotation needs a separately
reviewed operation. Renewal does not establish that a key is unrevoked elsewhere;
the operator must select the approved current vault and public input.

## Local verification

```sh
swift build --product sprout-admin --skip-update
swift test --filter SproutAdminSupportTests --skip-update
```

The focused tests cover preservation with and without a catalog, genuine expired
and active inputs, forged signatures, wrong signer/private seed/domain/context,
unsafe historical and renewed validity, invalid approved-key sets and URLs,
unsupported versions and fields, and fresh descriptor IDs. CLI process tests use
fresh synthetic encrypted vaults and check real command execution, strict flags,
new-file output, preservation, and rejection without output. Those process tests
explicitly skip if `.build/debug/sprout-admin` has not been built first. CI builds
that product before testing. To exercise a specific release/static executable,
set `SPROUT_ADMIN_TEST_BINARY` to its absolute path; an invalid explicit path fails
the tests instead of skipping them.
An encrypted synthetic v2 fixture also proves both vault-loading entrypoints
refuse without returning identities, signing, rewriting the vault, or falling
back to legacy storage.
