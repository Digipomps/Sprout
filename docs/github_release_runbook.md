# GitHub Release Runbook

This is the production release path for Sprout when GitHub Actions is the authoritative CI/CD environment.

## Preconditions

- The repository has a valid Git remote.
- GitHub Actions is enabled for the repository.
- `SPROUT_GPG_PRIVATE_KEY` and `SPROUT_GPG_PASSPHRASE` are set if GPG checksum signing is required.
- OIDC-based keyless signing is permitted for the repository so `cosign` can produce certificate-backed signatures.

## Release workflow

Automatic release on tag push:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Manual release from GitHub Actions:

```bash
gh workflow run release.yml -f release_tag=v0.1.0
```

The workflow:

1. Builds `sprout`, `sprout-updater` and `sprout-macos`.
2. Runs `swift test`.
3. Builds the release bundle in `dist/`.
4. Applies `cosign` keyless signatures.
5. Verifies the bundle before publication.
6. Emits provenance and SBOM attestations.
7. Publishes a GitHub release with the generated artifacts.

Local verification already completed in this workspace:

```bash
zsh Scripts/build_release_bundle.sh /tmp/sprout-dist-verify
zsh Scripts/verify_release_bundle.sh /tmp/sprout-dist-verify
```

## Local verification after publication

Download the release bundle, then verify:

```bash
zsh Scripts/verify_release_bundle.sh dist
```

## Current local blocker

In the current workspace, a remote release run cannot be triggered yet because:

- `git remote -v` does not point at a publishable remote.
- `gh auth status` reports an invalid GitHub token.

The workflow itself is ready, but an actual GitHub release requires a valid remote and working GitHub authentication.
