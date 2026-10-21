# Purpose-driven scaffold installation

Candidate source contract: 2026-10-14; full real-image acceptance remains required. Live verification results are recorded separately.

`sprout scaffold` is the lightweight CLI entry point for a scaffold administrator.
`sprout onboard --role scaffoldadmin` enters the same flow. Existing personal
Entity onboarding remains available through `sprout onboard`; local software
installation does not grant remote Entity, Agreement or bridge privileges.

## User flow

1. Select a HAVEN domain. Fetch and verify its public trust descriptor.
2. Confirm its publisher key once, or provide an independently verified pin with
   `--trusted-publisher-key`. `--yes` never creates implicit first-contact trust.
3. Fetch the signed executable catalog. It declares which exact purpose IDs
   each scaffold supports, its dependencies, version, channel and platform.
4. Choose one or more purposes from the menu, or pass `--purpose ID,ID`.
   The CLI shows all selected scaffolds and dependencies before applying.
5. Sprout asks Docker to download immutable OCI image references, verifies each
   resulting RepoDigest, and atomically records the complete installation.
6. On Linux, normal installation requires an explicit signed three-role stack:
   `cellscaffold-web-stack-v1` → `cellscaffold-admin-v1` → `cellscaffold-node-agent-v1`.
   It enrolls separate web and Admin owners through strict offline ceremonies,
   creates a fresh paired channel credential and node signing key, then starts
   the isolated dependencies. Admin must accept a real fresh signed snapshot
   before web canonical provisioning proceeds. Web readiness, exact build,
   login/access boundary, selected-purpose discovery and restart must succeed
   before the aggregate service receipt says `ready`.
7. `sprout scaffold status --instance NAME` measures the actual service;
   plain `status` checks the images referenced by the image receipts.

```sh
sprout scaffold --domain staging.haven.digipomps.org
sprout scaffold purposes --domain staging.haven.digipomps.org
sprout scaffold plan --domain example.org --purpose purpose://scaffold.operations
sudo sprout scaffold install --domain example.org --purpose purpose://scaffold.operations \
  --instance scaffold --port 9089 --public-origin https://scaffold.example.org \
  --admin-port 9098 --admin-public-origin https://admin.example.org
sudo sprout scaffold status --instance scaffold
# Explicitly download images without creating an owner or starting a service:
sprout scaffold install --domain example.org --purpose purpose://scaffold.operations --download-only
sprout scaffold status
```

The domain must actually publish a v1.1 catalog. A 404, unsigned catalog, expired
catalog or missing purpose is an error, never an implicit fallback to arbitrary
software. A local signed catalog is supported with `--catalog FILE`; its initial
publisher key must be supplied explicitly. `--root` chooses catalog trust and
image-receipt state. Service state always lives below `/var/lib/haven-sprout/NAME`;
it cannot be redirected to an arbitrary host path. The shared `/var/lib/haven`
parent is never created or changed. Existing system ancestors must allow UID995
read/traversal before any pull; Sprout creates only its dedicated root and instance.

An existing `/var/lib/haven/sprout/NAME` from v0.3.0 stops all service operations
with `legacy_instance_requires_explicit_recovery`, including partial state and
symlinks. Keep that generation and its keys for explicit operator recovery;
there is no automatic migration, adoption, or replacement owner. Do not run
old and new installers concurrently for the same instance.

## What the signature proves

Catalog version `1.1` adds optional artifact fields `purpose_ids`, `dependencies`
and `installation`. Installation requires these fields and rejects legacy
metadata-only entries. `installation` currently supports `oci-image` with
`image` (registry/repository@sha256:digest), `container_platform`, and optional
`service_profile`. Activation requires exactly one web-stack, one Admin and one
node-agent role, with the exact dependency chain above and no extra artifacts.
All roles require the same trusted publisher and compatible platform. Only the
web role declares the selected purposes. Legacy `cellscaffold-web-v1` metadata
remains readable for download and recovery checks, but cannot start a new
production service by itself. Unknown roles cannot execute service setup.
`sha256_b64url` must encode that same OCI manifest digest; `download_url` must
name its registry manifest URL. Docker performs the OCI download and content
integrity verification. The catalog's pinned Ed25519 publisher authorizes that
exact digest with signing type `catalog-ed25519`, identity equal to `issued_by`.
This is not a claim that optional cosign/SBOM/provenance evidence was verified.

Purpose matching is exact, publisher-declared matching, not semantic inference
from free text. Unknown purposes, multiple matching artifacts for a purpose,
wrong platform/channel, missing dependencies and dependency cycles fail before
any pull. One artifact can cover multiple purposes. Dependencies are installed
once in dependency order. A failure leaves already downloaded image layers in
Docker's cache but publishes no new partial installation receipt. Reapplying is
safe and Docker reuses already verified layers.

## Runtime boundary

Normal installation requires Linux, root, Python 3 at `/usr/bin/python3`, Docker
Engine on the local Unix socket, `unshare`, `setpriv`, OpenSSL with Ed25519 support, `libjemalloc.so.2`, and
registry read access. Missing prerequisites stop before image download. Sprout
does not install these host packages or configure DNS, firewalls or a TLS proxy.
`--public-origin` must be an HTTPS DNS origin, optionally with a nondefault port (omit explicit `:443`). The
web container binds only `127.0.0.1:PORT`; Admin uses the separately supplied
`--admin-port` and `--admin-public-origin`. Both require preconfigured TLS proxies.
Admin HTTPS must actually work for signed node ingestion; the installer verifies
its TLS readiness/build. Public web TLS remains a separate acceptance check
(`public_tls_verified: false` at the top level). Keep Admin's `/health/restore-audit`
and `/metrics` off the public proxy; the installer uses the private bearer only
on loopback. Local channel installation grants no human Admin role.

Visible fixed limits are web 2 GiB/2 CPU/512 PIDs, Admin 1 GiB/1 CPU/256 PIDs and
node 256 MiB/0.25 CPU/64 PIDs, with bounded logs. Admin/node have read-only root
filesystems, private writable volumes, all capabilities dropped and no Docker
socket. The node reports its own sidecar observations, not host fleet metrics.
Its strict persistent sequence mode rejects a missing/corrupt counter and any
sequence override; it never resets the counter or rotates the signing key.

The coordinator is embedded in the CLI executable. It accepts no shell fragments,
arbitrary environment or mounts from the catalog. It runs the image's exact
bootstrap binary offline as UID 995, creates fresh local vault keys, verifies the
owner/build-bound manifest, and provisions missing canonical runtime identities
before ordinary production startup. It uses no existing staging vault or
production bypass. The accepted container has `unless-stopped` restart policy.
This assumes Docker itself is configured to start at boot on the host.
The selected purposes configure discovery policy, and each is queried before
acceptance. Discovery grants no Entity/capability access; authenticated end-user
operations and descriptor-signature verification are separate checks.

A failed installation keeps its private generation and keys for diagnosis or
retry. A renewed signed catalog may have a different payload hash. Repetition
requires the same publisher, catalog domain/ID and every operative field (all
image pins, origins, ports, purposes, profile and limits); only that evidence hash
may differ. The original request/hash and container labels remain unchanged.
`catalog-verification.json` records the latest verified evidence separately; the
receipt distinguishes current `catalog_sha256_b64url` from
`initial_catalog_sha256_b64url`. Status does not fetch/renew catalog evidence:
it reports the initial catalog binding loaded from state, while the latest
install-verified hash remains in `catalog-verification.json`.
Repeating the same request reuses that generation; a changed image or
configuration for an existing instance is rejected. This is a fresh-install
profile with one narrowly defined recovery transition: a v0.3.1 web request
at phase `enrolled` may add the explicit dependency stack while preserving its
exact image/build, instance/root, origin/port, purposes, owner, generation,
enrollment and manifest. A private `stack-upgrade.json` records old/new request
hashes, the exact stopped provision container and preserved file hashes before
side effects. The old failed container and environment are archived, not deleted.
Unknown, ready, canonical-ready or changed web requests are refused. Legacy state
did not store its publisher pin: the new journal records fresh verified catalog
authority and explicitly does not claim historical signer continuity.

Admin state lives in its own `admin-data` volume, with separate `admin-secrets`,
`node-secrets` and `node-state`. The web receives only the paired client credential.
An interrupted Admin ceremony may retry only `verify-owner` against the same
image/journal; a missing fingerprint checkpoint remains an unknown outcome and
requires operator recovery. It cannot silently reenroll or heal keys. Repeating
the same accepted request restarts all three exact owned containers as needed;
status is read-only and rejects disabled restart policies on any member. A failed
Admin verifier can reuse its exact container, but the receipt is read only from
that invocation's nanosecond StartedAt boundary and the stopped run is checked
before and after capture. Process exit time is not a log cutoff: Docker may
timestamp the final stdout line later. Earlier failure output cannot poison a
later receipt.
Receipt fields include the public owner pins, exact images,
request/catalog binding and observed node counter. An observed counter is not a
claim that that precise value was accepted remotely; Admin independently verifies
fresh signature-bound telemetry. Ongoing freshness requires the node sidecar's
60-second loop. No mutable image or general in-place upgrade path is introduced.

`--download-only` preserves image-only installation and its `installed-not-started`
receipts. It also permits macOS use with a compatible Docker engine and catalog
platform entries. Automatic service activation currently targets Linux. Sprout
identity commands and planning do not require Docker. No native Mac/Linux
CellScaffold bundles are published by the inspected release workflow.

The CellScaffold server's typed catalog must preserve the new fields when it
serves a pre-signed catalog; dropping them invalidates the signature. The
companion server change adds that support and optional OCI environment wiring.

`install --offline` verifies only images already present in Docker and writes the
same signed-source receipts. It fails if any digest is missing, never contacts
the registry, and explicitly reports that no download occurred. This supports
air-gapped/preloaded hosts; it is not evidence that a fresh registry pull works.
