# SECURITY

## Security model (normative)
- Domain-scoped identities only.
- `Entity != Identity` in all contracts and state transitions.
- No implicit cross-domain linkage.
- Capability and contract checks are resolver-enforced.
- Transport adapters are semantics-neutral byte channels.
- `Purpose/Goal` and interests must be explicit in request context.
- Scaffold admin identity must be explicit before entity resolution and porthole access.
- Mutual `EntityLinkContract` is evidence input only, not final authorization.
- Updater is deny-by-default and grant-enforced via `UpdateGrantPolicy`.
- Bootstrap and updater are separate trust boundaries.
- Live resolver mode is feature-flagged and can pin trusted resolver issuer keys.

## Main trust boundaries
1. Joining identity signs `StarterAuthPayload`.
2. Bridge metadata establishes scaffold admin trust input.
3. Resolver returns explicit `EntityResolutionDecision`.
4. Resolver-signed `EntityInclusionProof` binds identity to entity.
5. Resolver-signed `PortholeAccessContract` binds entity, identity, capabilities and client/protocol.
6. `sprout-updater` verifies release bundle and policy before any installation plan is authorized.

## Primary attack surfaces
- Bootstrap payload tampering or replay.
- Discovery metadata poisoning.
- Bridge MITM and route substitution.
- Scaffold admin trust-root confusion.
- Resolver bypass or forged entity membership.
- Porthole contract substitution or capability widening.
- Update repository compromise, checksum tampering or malicious artifact replacement.

## Implemented controls
- JCS canonicalization before signing/verifying.
- Ed25519 signatures on starter auth, bridge descriptors, anchor snapshots, inclusion proofs and porthole access contracts.
- Strict base64url parsing that rejects padding and invalid characters.
- Expiry checks on all signed time-bounded artifacts.
- Bridge descriptor validation for domain, purpose constraint and signature.
- Explicit `ScaffoldAdminIdentity` derivation and parity checks against selected bridge metadata.
- Explicit entity resolution with inclusion proof verification before porthole issuance.
- Inclusion proof and porthole contract issuer parity checks.
- Capability subset enforcement between resolver decision and porthole contract.
- TLS-only transport baseline (`https` / `wss`) with alternative transports behind feature flags.
- Update policy enforcement layer denies ungranted behavior.
- Release bundle checksum verification and optional detached GPG signature verification.
- Keyless cosign signatures in CI.
- Audit logging for bootstrap state transitions.

## Known open hardening work
- Authoritative HAVEN resolver server deployment and revocation model remain external dependencies to this repo.
- Apple Keychain / Secure Enclave parity across all wrappers.
- Published production signing keys and release trust-root rotation procedure.
- TUF metadata and rollback protection for custom updater flows.
- Cross-runtime reproducible build proof.

## Reporting
Use a private security reporting workflow before public disclosure.
