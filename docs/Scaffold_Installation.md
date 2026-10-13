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
6. `sprout scaffold status` checks the images referenced by the local receipts.

```sh
sprout scaffold --domain staging.haven.digipomps.org
sprout scaffold purposes --domain staging.haven.digipomps.org
sprout scaffold plan --domain example.org --purpose purpose://scaffold.operations
sprout scaffold install --domain example.org --purpose purpose://scaffold.operations --yes
sprout scaffold status
```

The domain must actually publish a v1.1 catalog. A 404, unsigned catalog, expired
catalog or missing purpose is an error, never an implicit fallback to arbitrary
software. A local signed catalog is supported with `--catalog FILE`; its initial
publisher key must be supplied explicitly. `--root` chooses isolated local state.

## What the signature proves

Catalog version `1.1` adds optional artifact fields `purpose_ids`, `dependencies`
and `installation`. Installation requires these fields and rejects legacy
metadata-only entries. `installation` currently supports `oci-image` with
`image` (registry/repository@sha256:digest) and `container_platform`.
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

The current installer downloads and verifies OCI images. It does **not** create
or start a service, install Docker, open network ports, copy an existing vault,
claim a new owner or bypass production identity provisioning. A receipt says
`installed-not-started`. New production CellScaffold instances still require a
scaffold owner, private vault configuration and a build-bound owner-signed
runtime manifest. The existing bootstrap tool requires a pre-existing owner;
first-owner provisioning must be completed before these images can serve users.

Linux needs Docker Engine and authorization to read the registry. macOS needs
a working Docker-compatible Linux engine and catalog entries for its host
platform; cross-architecture images require engine-supported emulation. No
native Mac/Linux CellScaffold bundles are currently published by the inspected
CellScaffold release workflow. Sprout identity commands do not require Docker.

The CellScaffold server's typed catalog must preserve the new fields when it
serves a pre-signed catalog; dropping them invalidates the signature. The
companion server change adds that support and optional OCI environment wiring.

`install --offline` verifies only images already present in Docker and writes the
same signed-source receipts. It fails if any digest is missing, never contacts
the registry, and explicitly reports that no download occurred. This supports
air-gapped/preloaded hosts; it is not evidence that a fresh registry pull works.
