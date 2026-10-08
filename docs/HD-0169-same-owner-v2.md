# Same-owner v2 descriptor renewal (HD-0169)

Implemented source path: `sprout-admin scaffold-trust-root renew-from-pinned-v2-vault`.
Compilation and the six new Swift tests are **capacity-blocked**, not passed.
The operational package is in `HAVEN-Deploy/_handoff/HD-0169/v2/` (HAVEN root).
No binary produced by this change has been signed or deployed.

Purpose: renew the existing active owner's staging descriptor without changing
its owner, key arrays, endpoints, encrypted vault or runtime manifest.

Every input is explicit: existing descriptor path/hash/domain, owner
UUID/Scaffold context/fingerprint, encrypted vault SHA256, vault/master paths,
new descriptor ID, expiry and new output. Duplicate, missing and unknown flags
are refused; no clock override, key-list override, environment fallback,
legacy v2 unwrap or migration fallback exists on this command.

The operation authenticates the predecessor at its signed issuance time,
requires the new expiry to be later than both now and predecessor expiry and
within 30 days (including the seconds encoded on the wire), decrypts one pinned
v2 snapshot, validates unique UUID/context and signing/agreement key records,
requires the pinned owner tuple and same Ed25519 key, then changes only ID,
issuance, expiry and signature. A second vault hash check rejects observed
concurrent vault drift. It returns a public descriptor; it never writes the
vault or manifest. Output uses Foundation's withoutOverwriting option.

`verify-served-staging` fetches through `ScaffoldTrustRootHTTPClient` and the
ordinary current-clock validator, comparing the result with the candidate and
same owner. This is trust-discovery acceptance, not enrollment or admission.

Prerequisites copied from the existing uncommitted 29.09 preparation are listed
with source hashes in `docs/HD-0169-prerequisites.json`. The new worktree starts
at committed `7aea5b0`; other working-tree changes were not imported.

Tests: five support tests plus one admin-process test (all require a new build).
The process test fails if the new binary is absent rather than skipping.
Python publisher tests are separately recorded in the operational package.
No formal release/client acceptance or G3 is claimed.
