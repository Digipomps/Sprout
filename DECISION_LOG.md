# DECISION LOG

## 2026-02-26

### D-001: Default stack is Swift-only
- Status: Specified + Implemented (P0)
- Rationale: fastest integration with existing HAVEN Swift stack across CLI/macOS/iOS.
- Alternatives:
  - Swift+Rust: OPEN (P1/P2 hardening option)
  - Rust-core+Swift-UI: OPEN (interop/perf option)
  - Go+Swift: OPEN (ops familiarity option)

### D-002: Deterministic state machine as bootstrap authority
- Status: Specified + Implemented (P0)
- Rationale: replayability, testability, auditability.

### D-003: Normative crypto/serialization profile
- Status: Specified + Implemented (P0)
- Rationale: stable signatures and cross-runtime verifiability.
- Notes: float/decimal canonicalization is explicitly rejected in P0.

### D-004: Update policy is deny-by-default
- Status: Specified + Implemented (P0)
- Rationale: prevents hidden privilege escalation.

### D-005: Discovery service API in OpenAPI + mock reference server
- Status: Specified + Implemented (P0)
- Rationale: contract-first integration while real service remains optional.

## 2026-03-07

### D-006: Entity resolution is explicit and separate from identity
- Status: Specified + Implemented (P0/P1 bridge)
- Rationale: removes synthetic `entity_id` generation and preserves `Entity != Identity`.
- Notes: bootstrap now carries `EntityResolutionDecision` as `resolved` or `unresolved`.

### D-007: Scaffold admin identity is a first-class bootstrap artifact
- Status: Specified + Implemented (P0/P1 bridge)
- Rationale: the bridge owner/admin trust root must be explicit before porthole access is requested.
- Notes: current source is signed `BridgeDescriptor.owner_pubkey`; stronger admin descriptor chain remains OPEN.

### D-008: Porthole access is a signed resolver-issued contract
- Status: Specified + Implemented (P0/P1 bridge)
- Rationale: web/CLI/native access should share one explicit access handoff model rather than runtime-specific shortcuts.
- Notes: core consumer outputs for web/native are implemented; external client consumption remains OPEN.

### D-009: Sprout should remain a narrow bootstrap/distribution component
- Status: Specified + Implemented in design/docs (P0/P1 bridge)
- Rationale: reducing functionality in the bootstrap binary reduces update risk and privilege concentration.
- Notes: self-update remains deny-by-default and should stay separate from bootstrap trust path.

### D-010: Entity membership proof must be anchor-backed and resolver-issued
- Status: Specified + Implemented (P1 bridge)
- Rationale: a mutual link contract proves co-signing, not authoritative entity membership.
- Notes: current implementation uses a signed `EntityAnchorSnapshot` and resolver-issued `EntityInclusionProof`; live HAVEN resolver integration remains OPEN.

### D-011: Updater remains a separate binary
- Status: Specified + Implemented (P1 bridge)
- Rationale: separating bootstrap and update trust boundaries reduces privilege concentration and self-mutation risk.
- Notes: `sprout-updater` currently verifies bundles and produces policy-gated install plans; full installer mutation path and TUF remain deferred.

### D-012: Live resolver integration is HTTP-based and feature-flagged
- Status: Specified + Implemented (P1 bridge)
- Rationale: there is no published authoritative HAVEN resolver API in this repo set yet, so the client path must be explicit and opt-in.
- Notes: current contract is documented in `OpenAPI/resolver.openapi.yaml`; server-side HAVEN implementation remains OPEN.

### D-013: First non-CLI consumer is the macOS handoff client
- Status: Specified + Implemented (P1 bridge)
- Rationale: `PortholeAccessContract` needed a real client consumer inside this repo.
- Notes: `sprout-macos` embeds web handoff and now builds a live CellProtocol-native binding session from signed native descriptors; deeper UX hardening and iOS parity remain OPEN.

### D-014: CellProtocol integration in `sprout-macos` is workspace-coupled for now
- Status: Specified + Implemented (P1 bridge)
- Rationale: the fastest path to a real native consumer was a local package dependency on the sibling `CellProtocol` repo.
- Notes: this is acceptable for current workspace verification, but production distribution should move to a versioned dependency or release artifact strategy.

## Open Questions (OPEN)

### OQ-001: Hosting default
- Options: AWS / DigitalOcean / Fly.io / Hetzner / self-hosted
- Owner: Platform
- Unblock criteria: latency/SLA/regulatory matrix approved.

### OQ-002: Server DB default
- Options: SQLite local / Postgres server / managed DB
- Owner: Platform
- Unblock criteria: resolver/discovery write throughput benchmarks.

### OQ-003: Discovery auth mode
- Options: none / signed descriptors only / OIDC
- Owner: Security + Platform
- Unblock criteria: threat model review sign-off.

### OQ-004: Transport expansion
- Options: HTTPS/WSS (default) / gRPC HTTP/2 (P1) / QUIC HTTP/3 (P2)
- Owner: Networking
- Unblock criteria: interop test harness green across runtimes.

### OQ-005: Linux crypto dependency policy
- Options: toolchain-provided crypto only / explicit `swift-crypto` dependency
- Owner: Build/Release
- Unblock criteria: CI matrix includes Linux and key-vector parity.

### OQ-006: Ed25519 seed-to-key derivation parity
- Options: keep current CryptoKit raw representation behavior / adopt explicit RFC8032 seed-expansion compatibility layer
- Owner: Security + Crypto
- Unblock criteria: deterministic cross-runtime seed->pubkey/signature test vectors approved.

### OQ-007: Entity inclusion proof format
- Options: resolver-signed attestation / entity-anchor inclusion proof / hybrid
- Owner: Resolver + Security
- Unblock criteria: HAVEN-side authoritative proof source and revocation model agreed.

### OQ-008: Scaffold admin trust root hardening
- Options: signed bridge owner only / dedicated admin descriptor / chain-of-trust rooted in scaffold config
- Owner: Scaffold + Security
- Unblock criteria: chosen trust root can be verified consistently across server and Apple runtimes.

### OQ-009: Live HAVEN resolver integration surface
- Options: direct adapter to current resolver API / dedicated bootstrap API / signed snapshot fetch + local verification
- Owner: Resolver + Platform
- Unblock criteria: authoritative API shape and auth model are fixed for staging/prod.

### OQ-010: Production signing trust root
- Options: GitHub OIDC keyless only / keyless + GPG checksum signing / dedicated org signing service
- Owner: Release + Security
- Unblock criteria: published verification policy and rotation procedure approved.
