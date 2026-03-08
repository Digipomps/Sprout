# Economics and Pricing

## Scope
Sprout does not become a billing backend. It exposes an explicit economics layer so bootstrap/access decisions can be priced, measured and bounded before a session is granted.

The implemented baseline covers:
- deterministic accounting units
- explicit CloudBridge pricing contracts
- resolver-side pricing enforcement
- rollup-oriented ledger writes
- outbound session cost profiling
- Stripe fee overlay scenarios
- optional separation of stateless worker cost from stateful residency cost

## Unit model
- `RAU` is the int64 source of truth.
- `IMU` is a derived view.
- `ore` is a derived view.

Hardcoded conversion constants:
- `1 IMU = 1000 RAU`
- `1 ore = 10_000 IMU = 10_000_000 RAU`

Implication:
- ledger, wallet, deposits and tariff enforcement store `RAU`
- UI/reporting can present `IMU` or `ore`
- no persisted contract or balance should use a floating-point monetary source of truth

## Pricing contract
`CloudBridgePricingContract` defines the tariff the resolver enforces for a requested porthole session.

Current fields:
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

Rules:
- if `declared_deposit_rau < min_deposit_rau`, the outcome is `deny` or `degrade`
- `degrade` may only return the predeclared degraded capability subset
- if `requires_always_on == true`, `do_duration_escrow_rau` is added to the required deposit
- `max_rate_rau_per_minute` caps the billable rate

## Resolver enforcement
Economics is optional on `PortholeAccessRequest`, but if a pricing contract is present:
- the request carries `declared_deposit_rau`
- the resolver compiles the contract for the requested capability set
- the returned `PortholeAccessContract` carries a `pricing_plan`
- bootstrap validation ensures the returned plan matches the requested contract and deposit

This keeps billing policy explicit and capability-bounded. Pricing must not silently widen access.

## Charge model
`CloudBridgePricingCompiler.estimateCharge` currently computes:
- billed minutes: rounded up to whole minutes when there is any usage
- billed kilobytes: rounded up to whole KiB
- session fee
- message fee
- kilobyte fee
- audit fee
- optional edge fee
- capped total using `max_rate_rau_per_minute`

## Rollups
Billing writes are aggregated instead of emitting one ledger entry per micro-operation.

Default aggregation key:
- `wallet_id`
- `cell_id`
- `counterparty_id`
- minute bucket

Flush behavior:
- on message threshold
- on byte threshold
- on audit threshold
- on explicit close

This keeps the ledger small while retaining a deterministic pricing trace.

## Cost profiling
`CloudBridgeCostProfiler` instruments outbound sessions.

Per session it records:
- endpoint
- counterparty id
- duration
- outbound/inbound message count
- outbound/inbound bytes
- audit event count
- thread delta
- RSS delta
- heap delta when available
- user/system CPU delta

`economics suggest-rate` then estimates a session-minute tariff using explicit calibration constants instead of hidden heuristics.

## Stripe overlay
`StripeTopUpSimulator` models end-user payment pressure on top-ups.

Current default overlay:
- domestic card fee `2.4%`
- fixed fee `2 NOK`

The simulator exposes:
- fee share per top-up
- net credited ore
- estimated days of runway
- heuristic churn pressure
- heuristic payment latency

Default scenarios:
- `20 NOK`
- `50 NOK`
- `100 NOK`
- `300 NOK`

## Edge pricing split
`CloudflareEdgePricingModel` keeps stateless worker and stateful residency costs separate.

Modeled separately:
- worker requests
- worker CPU milliseconds
- durable object requests
- durable object duration milliseconds
- durable object storage GiB-months

This supports a policy where always-on contracts can require explicit Durable Object duration escrow.

## CLI commands
Convert units:
```bash
.build/debug/sprout economics units --ore 200
```

Compile a contract:
```bash
.build/debug/sprout economics compile-contract \
  --contract TestVectors/cloud_bridge_pricing_contract.example.json \
  --deposit-rau 1500000 \
  --requested-capabilities cap.join,cap.discover
```

Run Stripe scenarios:
```bash
.build/debug/sprout economics stripe-sim \
  --topups-nok 20,50,100,300 \
  --daily-spend-nok 5
```

Suggest a session-minute tariff:
```bash
.build/debug/sprout economics suggest-rate \
  --records <session-records.json>
```

Aggregate usage into rollups:
```bash
.build/debug/sprout economics rollup \
  --usage <usage-deltas.json> \
  --contract TestVectors/cloud_bridge_pricing_contract.example.json
```

## Test vectors
Current economics vectors in `TestVectors/`:
- `cloud_bridge_pricing_contract.example.json`
- `cloud_bridge_usage_deltas.example.json`
- `cloud_bridge_rollup_entries.expected.json`
- `cloud_bridge_session_records.example.json`
- `cloud_bridge_session_rate_calibration.example.json`
- `cloud_bridge_session_rate_suggestion.expected.json`

Note:
- rollup entries contain generated `entry_id` values in normal runtime use
- the golden rollup test injects deterministic IDs so the expected JSON can be compared bit-for-bit

## Current limits
- No external payment processor integration is performed in Sprout.
- No on-chain or bank settlement logic exists here.
- Session profiling is process-level cost measurement, not user profiling.
- The current compiler is deterministic and explicit, but tariff publication/governance remains an operator concern.
