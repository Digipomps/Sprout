# Purpose-driven scaffold installation — 2026-10-13

User instruction (verbatim): «Gjør det som gjenstår. Med automatisk scaffold installasjon. mener du da å hente og installere scaffolds som oppfyller brukerens (scaffoldadmin) formål. Det må på plass».

Scope extends the September identity-onboarding repair. The user's instruction authorizes implementation and host testing now; it is not a human identity/passkey approval or G3 acceptance.

Purpose tree, expected result and tests:
- Scaffoldadmin obtains runtimes for their explicit purposes. A signed catalog declares exact purpose IDs and dependency IDs. Every requested purpose must be covered; ambiguous candidates, missing dependencies, cycles, wrong platform and invalid signatures stop before download. New planner tests cover each boundary.
- Scaffoldadmin installs authentic software. OCI images use immutable digests covered by the pinned publisher's Ed25519 catalog signature. Docker verifies manifest/layer integrity during pull; Sprout verifies the resulting RepoDigest and writes an atomic private receipt. A missing signature/pin or mismatching digest never yields an installed receipt. New installer tests and a real Hetzner process run verify this.
- Installation is usable and inspectable. CLI supports listing purposes, planning, applying, and checking installed images; terminal scaffoldadmin flow offers a concrete plan before applying. Existing identity enrollment stays separate: installing local software does not claim identity rights or HAVEN channel access.
- Existing behavior is preserved. Full macOS/Linux regression and CLI transport checks remain required. No committed test is weakened.

Source audit (read by root): ScaffoldExecutableCatalog.swift, SproutCLI.swift software handlers, OnboardingCommand.swift, OnboardingDialogue.swift, PrivateStateFiles.swift. Reading agent catalog_runtime_audit checks CellScaffold publication and runtime contracts. Current catalog endpoint returned 404 in prior run; recheck and publish a real signed catalog if the existing operator contract permits it. No availability claim before measurement.

Implementation sequence: signed catalog extension and deterministic planner; Docker installer and receipts; CLI/terminal integration; negative tests and process tests; real immutable CellScaffold image on Hetzner; documentation and learning capture. No change to running production/staging containers in this work.

Lessons applied: a plan is not delivery; planned behavior is not implemented behavior; tests must exercise the actual path and effects; preserve existing private keys and dirty worktrees. Full acceptance requires test output and installed artifacts, not this document.
