# GitHub Repository Setup

Dette dokumentet beskriver det faktiske GitHub-oppsettet for `Digipomps/Sprout` per 2026-03-08.

## Repository
- Remote: `git@github.com:Digipomps/Sprout.git`
- Default branch: `main`
- Første baseline-push: `ecc16e4` `Bootstrap Sprout production baseline`
- Workflow-fikser:
  - `cab5740` `Fix GitHub Actions secret gating`
  - `da0c35b` `Make GitHub builds self-contained`
  - `55bd7e5` `Gate attestations behind repo variable`

## Tags og release-linje
- `v0.1.0` finnes og peker til den første baseline-commiten før workflow-fiksene.
- `v0.1.1` er publisert fra den første grønne, self-contained GitHub Actions-pipen.
- Release trigger:
  - automatisk via `git push origin <tag>`
  - alternativt via `gh workflow run release.yml -f release_tag=<tag>`

## GitHub Actions

### CI
- Workflow: `.github/workflows/ci.yml`
- Jobbnavn / required check: `build-test-release`
- Validerer:
  - `swift build --product sprout`
  - `swift build --product sprout-updater`
  - `swift build --product sprout-macos`
  - `swift test`
  - `zsh Scripts/build_release_bundle.sh dist`
  - `zsh Scripts/sign_release_bundle.sh dist`
  - `zsh Scripts/verify_release_bundle.sh dist`

### Release
- Workflow: `.github/workflows/release.yml`
- Trigger:
  - tags `v*`
  - `workflow_dispatch`
- Publiserer:
  - `sprout`
  - `sprout-updater`
  - `SHA256SUMS.b64url`
  - `release-manifest.json`
  - `sprout.spdx.json`
  - cosign-signaturer hvis generert
  - GPG-signatur på checksum-fil hvis secrets er satt

## Repo-variabler og secrets

### Variabler
- `SPROUT_ENABLE_GITHUB_ATTESTATIONS`
  - standard: ikke satt / `false`
  - effekt: GitHub attestations-steg hoppes over
  - begrunnelse: Digipomps-organisasjonen/repo-planen støtter ikke attestations-APIet for dette private repoet nå

### Secrets
- `SPROUT_GPG_PRIVATE_KEY`
- `SPROUT_GPG_PASSPHRASE`

Hvis disse ikke er satt:
- GPG-signering hoppes over
- cosign keyless-signering er fortsatt aktiv i CI/release

## Branch protection for `main`

Anbefalt policy:
- krev pull request før merge
- krev 1 godkjenning
- dismiss stale reviews
- krev conversation resolution
- krev linear history
- nekt force push
- nekt branch deletion
- enforce for admins
- required status check: `build-test-release`

Faktisk status:
- forsøk på å aktivere branch protection via GitHub API returnerte `HTTP 403`
- GitHub-respons: `Upgrade to GitHub Pro or make this repository public to enable this feature.`
- dette er derfor ikke implementert på repoet ennå

## Viktig releasegrense
- GitHub-byggene er nå self-contained.
- Standard release-artifakter bygger ikke inn live `CellProtocol`-runtime.
- `sprout-macos` i release-artifakter:
  - kjører `web` handoff
  - kan inspisere/kopiere signed `native` descriptor
  - tilbyr ikke live native runtime som default

Dette er bevisst for å unngå private, transitive GitHub-avhengigheter i Actions.
