# Sprout Linux Deployment Hardening Prompt

You are working in the `Digipomps/Sprout` repository. Your task is to harden the native Linux deployment path for Sprout without broadening Sprout beyond its intended bootstrap/distribution role.

## Current implemented baseline
- `sprout` and `sprout-updater` build natively for Ubuntu 22.04 `x86_64`.
- `swift-crypto` is an explicit dependency for Linux crypto support.
- CI and release workflows build platform-suffixed macOS and Linux artifacts.
- Release scripts are portable Bash scripts.
- Linux scope is currently bootstrap, verification and operator-managed replacement.
- `WSSClient` is not yet implemented for Linux runtime parity.

## Goals
1. Preserve the narrow trust boundary:
   - `sprout` must not become a self-updating general client.
   - updater behavior stays policy-gated and separate.
2. Harden Linux deployment hygiene:
   - verify installer layout, service account usage, filesystem permissions, audit log placement, and systemd hardening.
3. Evaluate whether Linux WSS support is actually required for the supported workflows.
4. If Linux streaming transport is required, propose the narrowest viable implementation and test plan.

## Constraints
- Domain-scoped identities only.
- `Entity != Identity`.
- No implicit cross-domain linkage.
- Resolver-enforced capability model only.
- No hidden privilege escalation.
- No claim of Linux runtime parity unless it is actually tested.

## Deliverables
- A concrete gap analysis with severity and file references.
- Recommended code/docs/tests changes.
- A deployment hardening checklist for Ubuntu 22.04.
- A transport decision for Linux: either keep CLI/update-only scope, or implement a streaming adapter with explicit rationale.
- If proposing code changes, include exact file targets and tests.

## Relevant files
- `Package.swift`
- `.github/workflows/ci.yml`
- `.github/workflows/release.yml`
- `Scripts/build_release_bundle.sh`
- `Scripts/sign_release_bundle.sh`
- `Scripts/verify_release_bundle.sh`
- `Packages/SproutTransport/Sources/SproutTransport/WSSClient.swift`
- `docs/linux_deployment.md`
- `docs/update_hardening_strategy.md`
- `RELEASE.md`
