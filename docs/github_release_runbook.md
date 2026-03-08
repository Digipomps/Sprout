# GitHub Release Runbook

This is the production release path for Sprout when GitHub Actions is the authoritative CI/CD environment.

## Preconditions
- The repository has a valid Git remote.
- GitHub Actions is enabled for the repository.
- `SPROUT_GPG_PRIVATE_KEY` and `SPROUT_GPG_PASSPHRASE` are set if GPG checksum signing is required.
- OIDC-based keyless signing is permitted for the repository so `cosign` can produce certificate-backed signatures.
- Optional: set repo variable `SPROUT_ENABLE_GITHUB_ATTESTATIONS=true` only if the repository plan supports GitHub attestations.

## Release workflow
Automatic release on tag push:

```bash
git tag v0.1.2
git push origin v0.1.2
```

Manual release from GitHub Actions:

```bash
gh workflow run release.yml -f release_tag=v0.1.2
```

The workflow:
1. Builds macOS targets for `sprout`, `sprout-updater` and `sprout-macos`.
2. Builds Linux targets for `sprout` and `sprout-updater` on Ubuntu 22.04.
3. Runs `swift test` on both runners.
4. Builds platform-suffixed CLI release bundles in `dist/`.
5. Applies `cosign` keyless signatures.
6. Verifies the bundles before publication.
7. Optionally emits provenance and SBOM attestations when `SPROUT_ENABLE_GITHUB_ATTESTATIONS=true`.
8. Publishes a GitHub release with macOS and Linux CLI artifacts.

Local verification already completed in this workspace:

```bash
bash Scripts/build_release_bundle.sh /tmp/sprout-dist-verify
bash Scripts/verify_release_bundle.sh /tmp/sprout-dist-verify
bash Scripts/build_release_bundle.sh /tmp/sprout-dist-linux linux-x86_64
bash Scripts/verify_release_bundle.sh /tmp/sprout-dist-linux "" /tmp/sprout-dist-linux/SHA256SUMS-linux-x86_64.b64url
```

## Local verification after publication
Download the release bundle, then verify:

```bash
bash Scripts/verify_release_bundle.sh dist
```

Or verify a platform-suffixed bundle explicitly:

```bash
bash Scripts/verify_release_bundle.sh dist "" dist/SHA256SUMS-linux-x86_64.b64url
```

## Current repository note
GitHub remote and `gh` authentication are configured for this workspace. The remaining platform caveats are:
- GitHub attestations must stay disabled unless the billing plan/repository support changes.
- branch protection on `main` cannot currently be enabled on this private repository because GitHub returns `HTTP 403` unless the repository is public or the billing plan is upgraded.
- Linux WSS transport parity is not part of the current release baseline.
- `sprout-macos` build verification exists in CI, but app packaging/notarization is not yet part of the CLI release bundle.
