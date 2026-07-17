# Executable Catalog Distribution

Date: 2026-05-31

`ScaffoldExecutableCatalog` is the signed metadata contract for discovering HAVEN executable artifacts without letting `sprout` mutate installed binaries.

## Trust Path
- The catalog is scoped to one `scaffold_domain`.
- The catalog is signed with `issued_by`.
- When a `ScaffoldAdminTrustRootDescriptor` is available, `issued_by` must match the trust root's `scaffold_admin_public_key`.
- Each artifact must include a `sha256_b64url` digest and at least one signing evidence entry.

This keeps software distribution under the scaffold owner/admin identity, but does not turn software distribution into Entity membership or user identity.

## Publication Endpoints
Preferred endpoints:
- `https://<domain>/.well-known/haven-executable-catalog.json`
- `https://<domain>/v1/software/catalog`

The trust root can also point directly at a catalog with `software_catalog_url`.

## Artifact Shape
Each artifact describes:
- `kind`: for example `cellscaffold`, `sprout`, `sprout-updater`, `scaffold-bundle`
- `platform`: for example `linux-x86_64`, `macos-arm64`
- `semver` and `channel`
- `download_url`
- `sha256_b64url`
- optional manifest, checksum, SBOM and provenance URLs
- `signing`: signing type plus detached signature/certificate URL or signing identity

## CLI Flow
Sign a prepared catalog with a local scaffold owner identity:
```bash
.build/debug/sprout software sign-catalog \
  --domain local.haven.test \
  --unsigned unsigned-executable-catalog.json \
  --out signed-executable-catalog.json
```

Fetch and verify from a scaffold:
```bash
.build/debug/sprout software fetch \
  --domain staging.haven.digipomps.org \
  --trust-root .sprout/trust-roots/staging.haven.digipomps.org.json
```

Select the CellScaffold artifact for a Linux host:
```bash
.build/debug/sprout software select \
  --catalog .sprout/software-catalogs/staging.haven.digipomps.org.json \
  --kind cellscaffold \
  --platform linux-x86_64 \
  --channel stable
```

`sprout` still does not install the artifact. Installation remains an operator/updater responsibility after checksum and signing/provenance verification.
