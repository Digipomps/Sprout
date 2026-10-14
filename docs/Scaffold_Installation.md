# Purpose-driven scaffold installation

Last verified against code: 2026-10-13. Live verification results are recorded separately.

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
6. On Linux, normal installation executes the signed `cellscaffold-web-v1`
   service profile as root. It enrolls a new local scaffold owner offline,
   provisions the runtime identities, creates private configuration and starts
   the service on loopback. Readiness, exact build, login/access boundary, discovery for every
   selected purpose and a restart must succeed before the service receipt says `ready`.
7. `sprout scaffold status --instance NAME` measures the actual service;
   plain `status` checks the images referenced by the image receipts.

```sh
sprout scaffold --domain staging.haven.digipomps.org
sprout scaffold purposes --domain staging.haven.digipomps.org
sprout scaffold plan --domain example.org --purpose purpose://scaffold.operations
sudo sprout scaffold install --domain example.org --purpose purpose://scaffold.operations \
  --instance scaffold --port 9089 --public-origin https://scaffold.example.org
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
`service_profile`. Activation requires the signed profile `cellscaffold-web-v1`;
a legacy or unknown profile cannot execute service setup.
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
Engine on the local Unix socket, `unshare`, `setpriv`, `libjemalloc.so.2`, and
registry read access. Missing prerequisites stop before image download. Sprout
does not install these host packages or configure DNS, firewalls or a TLS proxy.
`--public-origin` must be an HTTPS DNS origin, optionally with a nondefault port (omit explicit `:443`). The
container binds only `127.0.0.1:PORT`; configure a TLS reverse proxy separately.
A ready receipt explicitly says `public_tls_verified: false` until an external
operator verifies that route.

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
retry. Repeating the same request reuses that generation; a changed image or
configuration for an existing instance is rejected. This is a fresh-install
profile, not an upgrade mechanism. One service instance can cover multiple
purposes; independently selected services need separate instances. Dependency
images are downloaded, but are not implicitly activated.

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
