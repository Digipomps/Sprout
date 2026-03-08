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
- Neste release-linje er konfigurert til å publisere plattform-suffikserte macOS- og Linux CLI-artefakter fra samme workflow.
- Release trigger:
  - automatisk via `git push origin <tag>`
  - alternativt via `gh workflow run release.yml -f release_tag=<tag>`

## GitHub Actions

### CI
- Workflow: `.github/workflows/ci.yml`
- Jobbnavn / anbefalte required checks:
  - `build-test-macos`
  - `build-test-linux`
- Validerer:
  - macOS:
    - `swift build --product sprout`
    - `swift build --product sprout-updater`
    - `swift build --product sprout-macos`
    - `swift test`
    - `bash Scripts/build_release_bundle.sh dist macos-<arch>`
    - `bash Scripts/sign_release_bundle.sh dist dist/SHA256SUMS-macos-<arch>.b64url`
    - `bash Scripts/verify_release_bundle.sh dist "" dist/SHA256SUMS-macos-<arch>.b64url`
  - Linux:
    - `swift build --product sprout`
    - `swift build --product sprout-updater`
    - `swift test`
    - `bash Scripts/build_release_bundle.sh dist linux-<arch>`
    - `bash Scripts/sign_release_bundle.sh dist dist/SHA256SUMS-linux-<arch>.b64url`
    - `bash Scripts/verify_release_bundle.sh dist "" dist/SHA256SUMS-linux-<arch>.b64url`

### Release
- Workflow: `.github/workflows/release.yml`
- Trigger:
  - tags `v*`
  - `workflow_dispatch`
- Publiserer:
  - macOS CLI artifacts:
    - `sprout-macos-<arch>`
    - `sprout-updater-macos-<arch>`
    - `release-manifest-macos-<arch>.json`
    - `SHA256SUMS-macos-<arch>.b64url`
    - `sprout-macos-<arch>.spdx.json`
  - Linux CLI artifacts:
    - `sprout-linux-<arch>`
    - `sprout-updater-linux-<arch>`
    - `release-manifest-linux-<arch>.json`
    - `SHA256SUMS-linux-<arch>.b64url`
    - `sprout-linux-<arch>.spdx.json`
  - cosign-signaturer hvis generert
  - GPG-signatur på checksum-fil hvis secrets er satt
- `sprout-macos`-appen bygges i macOS-jobben, men er ikke del av `dist/`-publiseringen i dagens release-script.

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
- required status checks:
  - `build-test-macos`
  - `build-test-linux`

Faktisk status:
- forsøk på å aktivere branch protection via GitHub API returnerte `HTTP 403`
- GitHub-respons: `Upgrade to GitHub Pro or make this repository public to enable this feature.`
- dette er derfor ikke implementert på repoet ennå

## Viktig releasegrense
- GitHub-byggene er self-contained.
- Standard release-artifakter bygger ikke inn live `CellProtocol`-runtime.
- `sprout-macos` i repoet:
  - bygges i CI
  - kjører `web` handoff
  - kan inspisere/kopiere signert `native` descriptor
  - har egen fremtidig packaging/notarization-path utenfor dagens CLI release bundle
- Native Linux-baseline gjelder `sprout` og `sprout-updater` på Ubuntu 22.04 `x86_64`.
- Linux WSS-transport er ikke release-baseline ennå.

Dette er bevisst for å unngå private, transitive GitHub-avhengigheter i Actions og for å holde Linux-scope smalt til det som faktisk er verifisert.
