# Prompt: CellScaffold Native Linux Preflight

You are working in `CellScaffold`.
Implement or harden the native Linux preflight path without changing unrelated in-progress files.

## Goal
Make it obvious whether a Linux host can build and run `CellScaffold` without Docker.

## Constraints
- Prefer new files or isolated changes.
- Keep Docker as the controlled production baseline; native Linux is an explicit alternative path.
- The host must verify toolchain presence, private Git access and required shared libraries before attempting build/package.
- Do not assume root access.

## Existing repo facts
- `scripts/build-native-linux.sh` and `scripts/package-native-linux.sh` already exist.
- Native build currently depends on Swift in PATH, private GitHub SSH access and `libjemalloc`.
- Staging currently lacks native Swift and the required build packages.

## Deliverables
1. Add or improve a `preflight-native-linux.sh` script.
2. Ensure output is operator-readable and exits non-zero when blocked.
3. Document how to use the preflight before build/package.
4. Keep the result aligned with the Dockerfile's real build/runtime dependencies.

## Output requirements
- Include a concise summary of missing prerequisites.
- Separate hard blockers from optional runtime extras.
- Avoid broad refactors.
