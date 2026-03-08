# Sprout Economics Calibration Prompt

Use this prompt with another coding/research assistant when you want focused follow-up on tariff calibration and production hardening for Sprout economics.

---

You are working in the Sprout repo for HAVEN bootstrap/distribution.

Goal:
- evaluate and improve the economics/pricing layer without turning Sprout into a wallet app or billing monolith

Current implemented baseline:
- `Packages/SproutEconomics` exists
- `RAU` is the int64 source of truth
- `IMU` and `ore` are conversion views only
- hardcoded conversions:
  - `1 IMU = 1000 RAU`
  - `1 ore = 10_000 IMU`
- `CloudBridgePricingContract` exists with:
  - `session_fee_per_minute_rau`
  - `per_message_fee_rau`
  - `per_kb_fee_rau`
  - `audit_fee_per_event_rau`
  - `min_deposit_rau`
  - `max_rate_rau_per_minute`
  - `underfunded_mode`
  - `degraded_capability_grants`
  - `requires_always_on`
  - `do_duration_escrow_rau`
  - `edge_pricing`
- resolver-side enforcement exists through `PortholePricingEnforcer`
- rollups aggregate by `(wallet, cell, counterparty, minute)`
- `CloudBridgeCostProfiler` records thread/RSS/heap/CPU/message/duration deltas per outbound session
- `StripeTopUpSimulator` models top-up fee pressure using default domestic card fee `2.4% + 2 NOK`

Constraints:
- do not break canonical HAVEN constraints:
  - domain-scoped identities only
  - `Entity != Identity`
  - no implicit cross-domain linkage
  - capability/contract enforcement only
  - purpose/goal/interests remain explicit
  - no hidden privilege escalation
- keep Sprout narrow
- no self-update coupling
- no hidden behavioral scoring or user profiling

What to do:
1. review the implemented economics model for correctness, exploitability and operator usability
2. identify where pricing can be gamed:
   - undercounted session time
   - message batching abuse
   - deposit griefing
   - rate-cap abuse
   - edge cost under-recovery
3. propose concrete hardening changes, with code-level suggestions where possible
4. propose better calibration methodology for `economics suggest-rate`
5. evaluate whether minute-billing should remain whole-minute ceil or move to a different explicit bucket model
6. evaluate whether Stripe overlay defaults are reasonable for low-value top-ups in Norway
7. propose production metrics and dashboards for publishing tariffs responsibly

Output format:
- findings first, ordered by severity
- then recommended implementation changes
- then test additions
- then documentation changes
- include specific file paths in this repo where changes belong
- distinguish clearly between:
  - already implemented
  - missing
  - recommended but deferred

Focus files:
- `Package.swift`
- `Packages/SproutEconomics/Sources/SproutEconomics`
- `Packages/SproutResolverAdapter/Sources/SproutResolverAdapter/PortholePricingEnforcer.swift`
- `Packages/SproutResolverAdapter/Sources/SproutResolverAdapter/ResolverAdapter.swift`
- `Packages/SproutCore/Sources/SproutCore/SproutBootstrapStateMachine.swift`
- `Apps/sprout-cli/Sources/sprout-cli/main.swift`
- `Schemas/CloudBridgePricingContract.schema.json`
- `OpenAPI/resolver.openapi.yaml`
- `docs/economics_and_pricing.md`

Do not waste time suggesting a full billing platform. Keep the design narrow, explicit and production-defensible.
