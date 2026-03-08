# RELEASE

## Artifact trust policy
- Trust only release artifacts that match the published `SHA256SUMS.b64url`.
- Trust only artifacts covered by the published release manifest and matching the expected runtime/version/channel.
- Update/install authority is separate from bootstrap. `sprout` does not self-update.
- CLI install/update is allowed only when `UpdateGrantPolicy` grants artifact name + hash + semver + channel + trigger identity/contract.

## Build the release bundle
```bash
swift test
zsh Scripts/build_release_bundle.sh dist
```

Artifacts produced:
- `dist/sprout`
- `dist/sprout-updater`
- `dist/release-manifest.json`
- `dist/SHA256SUMS.b64url`
- `dist/sprout.spdx.json`
- optional keyless cosign signatures/certificates:
  - `dist/sprout.sig`, `dist/sprout.pem`
  - `dist/sprout-updater.sig`, `dist/sprout-updater.pem`
  - `dist/SHA256SUMS.b64url.sig`, `dist/SHA256SUMS.b64url.pem`

## Verify the release bundle locally
```bash
zsh Scripts/verify_release_bundle.sh dist
```

This verifies:
- artifact hash for `sprout` against `SHA256SUMS.b64url`
- optional detached GPG signature on `SHA256SUMS.b64url` when `dist/SHA256SUMS.b64url.asc` is present
- optional cosign signatures when `.sig` and `.pem` files are present

Most recent local verification in this workspace:
- Date: 2026-03-08
- Commands:
  - `zsh Scripts/build_release_bundle.sh /tmp/sprout-dist-verify`
  - `zsh Scripts/verify_release_bundle.sh /tmp/sprout-dist-verify`
- Result:
  - `sprout` checksum verification returned `verified: true`
  - `sprout-updater` release bundle build completed successfully

Create keyless signatures:
```bash
zsh Scripts/sign_release_bundle.sh dist
```

Direct updater verification:
```bash
./dist/sprout-updater verify-bundle \
  --artifact-path ./dist/sprout \
  --checksum-file ./dist/SHA256SUMS.b64url
```

Policy-gated install planning:
```bash
./dist/sprout-updater plan \
  --policy TestVectors/update_grant_policy.example.json \
  --artifact-path ./dist/sprout \
  --artifact-name sprout \
  --version 1.0.0 \
  --channel stable \
  --trigger contract:update-admin
```

## Signed contracts and vectors
```bash
.build/release/sprout verify TestVectors/starter_auth_payload.signed.json
.build/release/sprout verify TestVectors/bridge_descriptor.signed.json
.build/release/sprout verify TestVectors/entity_link_contract.mutual.json
.build/release/sprout verify TestVectors/porthole_access_contract.example.json --now 2026-02-26T08:03:00Z
```

## CI release evidence
GitHub Actions currently produces:
- release bundle artifacts
- cosign keyless signatures for `sprout`, `sprout-updater` and `SHA256SUMS.b64url`
- optional detached GPG signature for the checksum file when release secrets are configured
- optional GitHub build provenance / SBOM attestations when repo variable `SPROUT_ENABLE_GITHUB_ATTESTATIONS=true`

Current limitation:
- the repository and GitHub authentication are now configured
- GitHub attestations are disabled by default because the private Digipomps repository plan does not currently support the attestation API

## Reproducible build target
Target:
1. Build from immutable git tag in a clean environment.
2. Run `zsh Scripts/build_release_bundle.sh dist`.
3. Compare `dist/SHA256SUMS.b64url` against the published checksum file.
4. Verify checksum signature and provenance attestations.

Current status:
- local bundle generation and checksum verification are implemented
- CI keyless signing is wired for non-PR runs
- GitHub attestations are opt-in and require repository support before they can be treated as release baseline
- bit-for-bit reproducibility across independent environments remains an explicit release goal, not yet proven in CI

## Runtime-specific release policy
### CLI / server
- Preferred: operator-managed replacement of immutable signed artifacts.
- `sprout-updater` may plan or verify installs, but install mutation remains outside `sprout`.

### macOS
- Outside App Store, code signing and notarization are required before distribution.
- Sparkle or any auto-update path is deferred until explicit grants + stronger metadata controls exist.

### iOS
- App Store only.
- No custom updater.
