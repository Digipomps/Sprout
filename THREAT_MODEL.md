# THREAT MODEL

Date: 2026-03-08

## Scope
Sprout bootstrap, bridge discovery, scaffold admin trust establishment, entity resolution, porthole contract handoff, and release/update verification.

## Security baseline
The model uses NSM-style principles as the baseline:
- risk-based controls
- least privilege
- explicit access control and contract enforcement
- auditability and event logging
- privacy by design and data minimization

## Assets
- Domain-scoped identity keys.
- Signed bootstrap payloads.
- Signed bridge descriptors.
- Scaffold admin trust root.
- Entity anchor snapshots.
- Entity inclusion proofs.
- Porthole access contracts.
- Update grant policy and release artifacts.

## Threats and controls

### Bootstrap payload forgery or replay
- Threat: forged or replayed `StarterAuthPayload` leads to unauthorized registration.
- Control: Ed25519 verification over JCS payload, expiry, nonce, strict base64url parsing.

### Discovery poisoning
- Threat: attacker injects malicious bridge endpoint or owner key.
- Control: signed `BridgeDescriptor`, domain and purpose checks, expiry checks, explicit scaffold admin parity check.

### Bridge MITM or route substitution
- Threat: endpoint interception, downgrade, or bridge endpoint replacement.
- Control: `https` / `wss` baseline, resolver-issued porthole contract binds the exact bridge endpoint and descriptor id.

### Scaffold admin trust confusion
- Threat: attacker tricks bootstrap into accepting the wrong admin key for a domain.
- Control: `ScaffoldAdminIdentity` is explicit, validated against selected bridge metadata, and inclusion proof must match the same admin key.

### False entity membership claim
- Threat: user presents a mutual `EntityLinkContract` and is treated as part of an entity without authoritative confirmation.
- Control: mutual link contract is only evidence; resolver must issue `EntityInclusionProof`, and bootstrap validates signature, expiry, domain, subject identity, entity id and admin key parity.

### Resolver bypass
- Threat: direct porthole access without resolver decision.
- Control: no porthole contract issuance without explicit resolved entity and capability decision; consumer paths verify contract before use.

### Resolver issuer confusion
- Threat: bootstrap accepts proof or contract from an unexpected resolver issuer key.
- Control: live resolver adapter can pin trusted resolver issuer keys, and Sprout enforces issuer parity between inclusion proof and porthole contract.

### Capability widening
- Threat: porthole contract carries broader capabilities than resolver granted.
- Control: bootstrap enforces subset relation between resolver-granted capabilities and `PortholeAccessContract.capability_grants`.

### Update compromise or hidden privilege escalation
- Threat: unauthorized artifact replacement or bootstrap binary self-mutation.
- Control: `sprout` does not self-update, `sprout-updater` is separate, `UpdateGrantPolicy` is default deny, checksum verification is explicit, cosign/attestation path is documented, auto-update default false.

## Residual risks (OPEN)
- The authoritative HAVEN resolver server implementation and revocation semantics remain outside this repo's release boundary.
- Cross-device QR link flow is not yet production-integrated.
- Published production signing keys and artifact-verification workflow remain environment-dependent.
- TUF metadata and rollback protection are deferred to P2.
- Linux crypto parity still needs explicit CI matrix proof.
