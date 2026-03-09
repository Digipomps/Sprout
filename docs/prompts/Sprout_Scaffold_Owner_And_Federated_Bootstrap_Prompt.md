# Prompt: Scaffold Owner and Federated Bootstrap

You are working in the HAVEN repos.
Implement the next safe slice of scaffold-owner bootstrap and federated remote-contact support.

## Constraints
- Domain-scoped identities only.
- `Entity != Identity`.
- No implicit cross-domain linkage.
- Purpose/Goal must be explicit for every network action.
- Federation contact identity must be separate from local scaffold-owner identity.
- Every flow must remain possible from CLI even if a Binding app assists.
- Use `BridgeBase` / `BridgeTransportProtocol` semantics from `CellProtocol`; do not invent a parallel transport model.

## Existing repo facts
- `CellScaffold` currently derives scaffold ownership mainly from `CELL_SCAFFOLD_OWNER_*` in `Sources/App/configure.swift`.
- `CellScaffold` already registers default websocket bridge transports through `CellBase`.
- `Sprout` already has `ScaffoldAdminIdentity`, `EntityInclusionProof` and `PortholeAccessContract`.
- Current practical remote HAVEN targets are `staging.haven.digipomps.org` and `dev.haven.digipomps.org`.

## Deliverables
1. Add a first-class scaffold-owner bootstrap path that persists the owner identity and exposes an operator-readable inspection path.
2. Add a separate federation-contact identity model keyed by remote HAVEN domain.
3. Add CLI commands in `sprout` that:
   - inspect the current scaffold owner
   - initialize or inspect federation-contact identities
   - emit machine-readable JSON suitable for later Binding-app import/export
4. Add tests and documentation.

## Output requirements
- Prefer minimal-conflict edits.
- Reuse existing vault/resolver structures where possible.
- Document security boundaries between owner identity, federation-contact identity and user device identity.
- State any remaining server/API gaps explicitly as OPEN.
