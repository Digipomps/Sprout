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
git tag v0.1.1
git push origin v0.1.1
```

Manual release from GitHub Actions:

```bash
gh workflow run release.yml -f release_tag=v0.1.1
```

The workflow:

1. Builds `sprout`, `sprout-updater` and `sprout-macos`.
2. Runs `swift test`.
3. Builds the release bundle in `dist/`.
4. Applies `cosign` keyless signatures.
5. Verifies the bundle before publication.
6. Optionally emits provenance and SBOM attestations when `SPROUT_ENABLE_GITHUB_ATTESTATIONS=true`.
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

## Current repository note

GitHub remote and `gh` authentication are configured for this workspace. The remaining platform caveat is GitHub attestations: on the current private Digipomps repo they must stay disabled unless the billing plan/repository support changes.

Separate platform caveat:
- branch protection on `main` cannot currently be enabled on this private repository because GitHub returns `HTTP 403` unless the repository is public or the billing plan is upgraded.
