# ChatGPT Deep Research Prompt: Sprout Distribution + Bootstrap MCM

Use this in a fresh ChatGPT Deep Research session.

---

You are a principal distributed-systems architect and security engineer.

Date context: **February 26, 2026**.

## Mission
Design a production-grade, low-friction distribution and bootstrap model for **Sprout** in the HAVEN ecosystem, across:
- cloud service executable
- on-prem server executable
- desktop/laptop app
- mobile/tablet app

The model must preserve HAVEN constraints:
- domain-scoped identities (no global identity)
- explicit capability/contract enforcement
- transport must be semantics-neutral
- Purpose/Goal must be explicit and measurable
- no hidden privilege escalation

## Current implementation signals (use as constraints)
- Purpose/Goal and catalog bootstrap exist in ConfigurationCatalog cell.
- Server owner identity bootstrap currently relies mainly on env/context (`CELL_SCAFFOLD_OWNER_*`).
- Resolver supports remote host routing (`cell://host/...` -> `ws(s)://...`) and ws/wss policy.
- Porthole attachment exists in Apple and server startup paths.
- Vault implementations exist for Apple/Vapor/browser variants, but hardening parity is incomplete.
- No unified MCM bootstrap state machine across runtimes yet.
- No fully specified executable update policy with explicit grants.

## Research questions to answer
1. What is the best-practice **minimum common bootstrap protocol** across these runtime profiles?
2. Which identity-acquisition channels are best for first startup, and in which order should they be attempted?
   - env/context
   - mDNS/DNS-SD (Bonjour/zeroconf)
   - QR/deep-link bootstrap payload
   - passkey/WebAuthn-assisted linking
   - manual fallback
3. How should bootstrap payloads be structured (claims, signatures, replay protection, expiry, revocation)?
4. What secure, low-friction update strategies are realistic per platform without violating explicit rights?
   - server/on-prem executables
   - macOS desktop
   - Windows desktop
   - Linux desktop
   - iOS/iPadOS app constraints
5. Which supply-chain controls should be baseline?
   - artifact signing and verification
   - provenance attestations
   - reproducible builds
   - rollout/rollback strategy
6. How should permission boundaries be modeled so updater behavior never exceeds explicit grants?
7. What test matrix is required for bootstrap and update safety (negative tests included)?

## Output format (strict)
1. `Executive Summary`
2. `Current Best-Practice Baseline (2026)`
3. `MCM Bootstrap Protocol (Normative Draft)`
4. `Identity Acquisition Decision Tree`
5. `Update Architecture by Runtime Profile`
6. `Signed Distribution + Reproducible Build Blueprint`
7. `Threat Model and Mitigations`
8. `Compliance and Operational Considerations`
9. `Implementation Backlog (P0/P1/P2)`
10. `Validation Matrix (Tests + Exit Criteria)`
11. `Open Risks and Unknowns`

## Required evidence quality
- Prefer primary sources: official standards, official platform security docs, official framework docs, peer-reviewed/security publications.
- Include concrete source links and publication/update dates.
- Mark each claim as:
  - `Strongly evidenced`
  - `Reasonable inference`
  - `Uncertain`
- If sources conflict, explain trade-offs and propose a conservative default.

## Constraints for recommendations
- Must be implementable incrementally in a Swift-first codebase.
- Must preserve explicit permission grants for update operations.
- Must include fallback behavior for offline or partially connected environments.
- Must avoid assumptions that require global identity correlation.

## Final deliverable requirements
- Include at least one concrete state-machine spec for bootstrap.
- Include one concrete policy schema for update-right grants/denials.
- Include one concrete rollout plan for migration from existing HAVEN code paths.
