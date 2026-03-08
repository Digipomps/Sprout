# Prompt for ChatGPT Deep Research

Date context: 2026-02-26.

You are auditing and extending a Swift-first bootstrap/distribution system for HAVEN called Sprout.

Constraints (canonical):
1) Domain-scoped identities only.
2) Entity != Identity.
3) No implicit cross-domain linkage.
4) Access is capability/contract-based and resolver-enforced.
5) Transport is semantics-neutral.
6) Purpose/Goal and interests are explicit only.
7) No hidden privilege escalation, including updater.

Current implemented baseline:
- Deterministic state machine: Idle -> LoadContext -> AcquireIdentity -> CollectPurposeInterest -> ProbeEnvironment -> DiscoverBridges -> EstablishBridge -> RegisterWithResolver -> MembershipChecks -> PersistBootstrap -> Done/Error.
- JCS canonicalization subset in Swift (rejects float/decimal in P0).
- Ed25519 sign/verify, strict base64url.
- Signed schemas + OpenAPI discovery query.
- Mock discovery and mock resolver adapters.
- UpdateGrantPolicy deny-by-default.

Need deep research output:
1. Best-practice migration from mock resolver/discovery to production service.
2. Supply-chain hardening blueprint: SBOM, cosign, SLSA, reproducibility checks.
3. TUF rollout design for CLI/macOS updater with explicit grants.
4. Cross-runtime secure keystore parity (iOS/macOS/Linux/server).
5. QR mutual-signature link flow UX/security details.
6. Recommended transport adapter progression (HTTPS/WSS -> gRPC -> QUIC).
7. Interop test matrix and conformance suite design.

Output format:
- Executive summary
- Recommended target architecture (P1/P2)
- Threat model deltas
- Protocol adjustments (if any)
- Test and verification plan with exit criteria
- Open risks with confidence levels
