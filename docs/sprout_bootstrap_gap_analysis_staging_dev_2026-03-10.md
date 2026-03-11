# Sprout Bootstrap Gap Analysis for Staging and Dev

Date: 2026-03-10

## Update 2026-03-11

What changed after the first gap analysis:

- staging now serves `POST /v1/resolver/starter-auth/intent`
- staging now serves `POST /v1/bridges/query`
- both routes were verified live after source rebuild and redeploy of `CellScaffold`
- staging now has a signed entity anchor snapshot configured in the live resolver path
- a real `sprout bootstrap join` run against the live resolver now reaches `Done` on staging
- staging now publishes a signed scaffold-admin trust-root descriptor at `/.well-known/haven-scaffold-admin-trust-root.json`
- a real `sprout bootstrap join` run against staging now reaches `Done` without explicit `--trust-root` or `--resolver-base-url` when the starter identity is already anchored

What is now proven on `staging.haven.digipomps.org`:

- Sprout can obtain a signed starter bootstrap intent from the scaffold
- Sprout can obtain a signed bridge descriptor from the scaffold
- Sprout can obtain a signed scaffold-admin trust-root descriptor from the scaffold
- the public bridge endpoint published by staging is:
  - `wss://staging.haven.digipomps.org/bridgehead/Porthole/CloudBridge`
- a real `sprout bootstrap join` run from the staging host reaches `Done` when:
  - starter intent is fetched live
  - bridge discovery is fetched live
  - entity resolution is supplied via mock `--resolved-entity`
- a real `sprout bootstrap join` run from the staging host also reaches `Done` when:
  - starter intent is fetched live
  - scaffold-admin trust root is fetched live from `well-known`
  - bridge discovery is fetched live
  - entity resolution is performed by the live resolver against the configured anchor snapshot

What is still not proven end-to-end:

- the full `sprout bootstrap join` flow from this local runtime, because public DNS resolution to `staging.haven.digipomps.org` failed in the local execution environment
- full success for a completely fresh starter identity without prior anchor membership or accepted entity-link evidence

This shifts the main gap from discovery, resolver authority and trust-root publication to fresh-identity entity admission and post-bootstrap routing.

## Scope

This document evaluates the current `sprout` executable against the intended role:

- as small as possible
- enough capability to understand its environment
- enough identity handling to make correct bootstrap choices
- enough protocol compatibility to attach to a HAVEN scaffold
- enough purpose/goal handling to get help from the right remote scaffold, matching cell or AI assistant cell
- usable from CLI first, with binding-app assistance as an optional handoff

Targets reviewed:

- `staging.haven.digipomps.org`
- `dev.haven.digipomps.org`

## Verified Runtime Facts

### Staging

Verified directly:

- `GET https://staging.haven.digipomps.org/health` returns `200 OK`
- `GET https://staging.haven.digipomps.org/.well-known/haven-scaffold-admin-trust-root.json` returns `200 OK`
- `POST https://staging.haven.digipomps.org/v1/resolver/starter-auth/register` returns `400` for `{}`, which proves the resolver route is live
- `POST https://staging.haven.digipomps.org/v1/resolver/starter-auth/intent` returns `200 OK` and a signed starter bootstrap intent
- `POST https://staging.haven.digipomps.org/v1/bridges/query` returns `200 OK` and a signed bridge descriptor
- `GET https://staging.haven.digipomps.org/admin/api/scaffold-owner` returns `401`, which proves the operator endpoint is present and protected

Verified on host/container:

- `RP_ID=staging.haven.digipomps.org`
- `RP_ORIGIN=https://staging.haven.digipomps.org`
- `SPROUT_ENTITY_ANCHOR_SNAPSHOT_PATH=/app/CellsContainer/sprout/entity-anchor-snapshot.json`
- no `SPROUT_RESOLVER_BEARER_TOKEN` in the running container environment

Consequence:

- staging exposes the resolver API surface
- staging exposes a published scaffold-admin trust root
- staging exposes live starter bootstrap intent publication
- staging exposes live signed bridge discovery
- staging resolver now resolves entity membership against a signed anchor snapshot
- live resolver bootstrap reaches `Done` for the anchored staging subject identity
- live resolver bootstrap with trust-root auto-fetch reaches:
  - `Done` for an anchored starter identity
  - explicit `entityUnresolved(...)` for a fresh starter identity that is not in the accepted anchor snapshot

### Dev

Verified directly:

- `https://dev.haven.digipomps.org` has a self-signed TLS certificate
- with TLS verification disabled, `GET /health` returns `404`
- with TLS verification disabled, `POST /v1/resolver/starter-auth/register` returns `404`

Consequence:

- `dev.haven.digipomps.org` is not a valid Sprout bootstrap target in its current state
- it needs both TLS and app/runtime upgrade work

## Current Executable Status

The current CLI is functional and builds cleanly:

- `swift build --product sprout`
- `swift build --product sprout-updater`
- `swift test`

Verified command surface in the executable:

- `bootstrap join`
- `bridges list`
- `federation init|show|list`
- `link export|import`
- `porthole web-bootstrap|native-spec`
- `verify`
- `economics ...`
- `update` planning

This means `sprout` is currently broader than the intended narrow bootstrap role.

## What `sprout bootstrap join` Actually Requires Today

From the shipped CLI and state machine:

1. explicit `--domain`
2. explicit `--purpose`
3. explicit `--goal`
4. explicit `--interests`
5. a signed `StarterAuthPayload` file via `--starter`
6. a signed bridge catalog or bridge descriptor via `--catalog`
7. one of:
   - live HTTP resolver
   - local entity-anchor snapshot
   - mock resolved entity

This is enforced by:

- `Apps/sprout-cli/Sources/sprout-cli/main.swift`
- `Packages/SproutCore/Sources/SproutCore/SproutBootstrapStateMachine.swift`

## Main Gaps Against the Intended Sprout Role

### G-001: Fresh starter identities are still unresolved unless admitted by the entity anchor

Current state:

- `sprout` now auto-fetches trust root and starter bootstrap intent
- it can materialize a local `StarterAuthPayload` without `--starter`
- a fresh starter identity still fails correctly at entity resolution unless:
  - the anchor snapshot already contains it, or
  - accepted entity-link evidence ties it to an anchored identity

Why this matters:

- Sprout is now low-friction for trust establishment, but not yet low-friction for first-time entity admission
- first-touch bootstrap for a brand new user/device still needs an explicit admission flow

Needed change:

- define an explicit admission path for fresh starter identities
- likely inputs:
  - scaffold-owner decision
  - accepted entity-link evidence
  - later: QR or binding-assisted proof flow

### G-002: Purpose routing after bootstrap is still missing

Current state:

- trust root, starter intent, bridge discovery and live resolver are now all usable from `bootstrap join`
- Sprout still stops after porthole contract issuance
- there is no shipped purpose-router contract telling Sprout which next scaffold/cell/binding should satisfy the user's goal

Why this matters:

- the user still has to know what to do after bootstrap
- this is the remaining friction point relative to the intended role

Needed change:

- define and implement a post-bootstrap purpose-router contract
- let the scaffold or matching cell return:
  - the next scaffold recommendation
  - the next cell or assistant binding
  - the required porthole mode

### G-003: `sprout` is still broader than the intended minimal bootstrap executable

Current state:

- planner logic is now in shipped `SproutCore`
- trust-root auto-fetch is in the shipped CLI
- the executable still includes economics/update/admin-adjacent commands that are broader than strict bootstrap

Why this matters:

- the bootstrap path is now correct enough
- the remaining reduction should be about executable surface, not missing bootstrap primitives

Needed change:

- consider splitting economics and other non-bootstrap commands out of the default binary
- keep `sprout` focused on:
  - trust root
  - starter identity
  - bridge discovery
  - entity admission
  - porthole handoff

### G-004: Staging resolver is live, but not yet authoritative for entity membership

Current state:

- staging exposes `/v1/resolver/*`
- resolver entity resolution requires a configured anchor snapshot
- staging currently has no `SPROUT_ENTITY_ANCHOR_SNAPSHOT_PATH`

Why this matters:

- live `bootstrap join` cannot reach `Done` through the authoritative entity-resolution path
- `sprout` can register starter auth, but cannot prove entity membership against staging as currently deployed

Needed change:

- configure and maintain a signed anchor snapshot on staging
- or replace file-backed anchor resolution with the authoritative HAVEN entity source

### G-005: The scaffold admin trust root is still implicit

Current state:

- `sprout` derives scaffold admin identity from `BridgeDescriptor.owner_pubkey`
- staging currently does not publish a separate signed scaffold-admin descriptor

Why this matters:

- this is usable as a bootstrap bridge, but not a hardened trust root
- the user wants `sprout` to collect the right identities and make the right choices

Needed change:

- expose a canonical scaffold-owner/admin descriptor
- bind it to the domain and bridge descriptors
- let `sprout` verify that descriptor before bridge selection

### G-006: No canonical remote “purpose help” path exists yet

Current state:

- `sprout` can carry explicit `purpose`, `goal`, and `interests`
- resolver uses them for checks and contract issuance
- there is no canonical post-bootstrap route for “take this purpose and ask the scaffold which helper scaffold/cell to load next”

Why this matters:

- that is the actual product goal
- currently the bootstrap ends with a porthole contract, not with remote help orchestration

Needed change:

- define a minimal purpose-routing contract
- likely destination:
  - matching cell
  - AI assistant cell
  - configuration catalog purpose matcher
- output should be a small recommendation set:
  - next scaffold
  - next porthole
  - next helper cell
  - required grants/capabilities

### G-007: CLI-first and binding-assisted flows are not yet one canonical flow

Current state:

- CLI can output/import contracts
- macOS client can consume signed porthole contracts
- federation-contact identities exist
- there is not yet a single bootstrap flow that says:
  - start in CLI
  - optionally hand off to phone/laptop binding
  - continue over the same signed bootstrap contract/evidence model

Why this matters:

- the user explicitly wants everything possible from CLI, with binding app as an optional assist path

Needed change:

- CLI generates or receives a signed bootstrap handoff object
- phone/laptop binding consumes that same object
- both continue using the same entity evidence, scaffold admin identity and purpose contract

### G-008: The current `sprout` binary is larger in scope than it should be

Current state:

- the binary includes economics, pricing simulation, rollups, verification helpers and update planning

Why this matters:

- the desired role is a minimal bootstrap executable
- extra tool surface increases maintenance, audit and trust surface

Needed change:

- keep `sprout` small:
  - environment probe
  - local identity bootstrap
  - federation-contact bootstrap
  - bridge discovery
  - scaffold admin trust-root verification
  - entity evidence collection
  - bootstrap join
  - porthole handoff
- move non-bootstrap tooling into separate executables if retained:
  - `sprout-updater`
  - `sprout-admin`
  - `sprout-economics`

## Environment-Specific Conclusion

### Staging

Staging is close enough to serve as the first real Sprout target, but it is not complete yet.

What staging already has:

- correct canonical domain
- working TLS
- live resolver routes
- protected scaffold-owner operator route

What staging still lacks for real end-to-end `sprout bootstrap join`:

1. signed bridge descriptor publication/discovery
2. authoritative entity membership source wired into resolver
3. explicit scaffold admin descriptor/trust root
4. canonical post-bootstrap purpose-routing endpoint

### Dev

`dev.haven.digipomps.org` should currently be treated as non-target.

It needs:

1. valid TLS certificate
2. current `CellScaffold` deployment with Sprout resolver routes
3. same resolver/bootstrap config as staging

## Recommended Narrowing of Sprout

The executable should be reduced toward this role:

1. detect runtime profile
2. determine available bootstrap channels
3. create/load the minimum required identities:
   - local subject identity
   - local scaffold owner identity when applicable
   - federation-contact identity for remote HAVEN installations
4. discover and verify scaffold admin trust root
5. discover and verify signed bridge descriptor
6. carry explicit purpose/goal/interests
7. obtain entity evidence or entity inclusion proof
8. obtain a signed porthole handoff
9. optionally hand off to:
   - CLI porthole
   - web porthole
   - native/binding porthole
10. ask the scaffold what next scaffold/cell should be used to fulfill the purpose

That is enough. The rest should be separate tooling.

## Concrete Next Steps

### N-001: Make bridge discovery real

Implement one canonical scaffold-facing route:

- `POST /v1/bridges/query`

or one canonical signed descriptor endpoint:

- `GET /.well-known/haven-bridge-descriptor.json`

Then wire `sprout bootstrap join` to use it instead of requiring `--catalog`.

### N-002: Move bootstrap planning into the shipped core

Promote `BootstrapPlanner` into `SproutCore` and let the CLI use it as the first stage.

This is the missing piece for:

- environment awareness
- low-friction identity acquisition
- purpose-driven next actions

### N-003: Make staging authoritative for entity resolution

Configure one of:

- `SPROUT_ENTITY_ANCHOR_SNAPSHOT_PATH`
- authoritative entity resolver integration

Without this, live resolver bootstrap remains incomplete.

### N-004: Publish scaffold admin trust root

Expose a signed descriptor for scaffold owner/admin identity and bind bridge discovery to it.

### N-005: Define the post-bootstrap purpose-router contract

After porthole issuance, `sprout` should be able to ask:

- given this `purpose`
- given this `goal`
- given these `interests`
- what scaffold or helper cell should be loaded next

This is the product-critical missing contract.

### N-006: Upgrade `dev.haven.digipomps.org`

Bring `dev` to at least staging parity:

- valid TLS
- current `CellScaffold`
- resolver routes
- scaffold-owner runtime support
- same bootstrap config model

## Bottom Line

The current `sprout` executable is strong as a protocol-checked bootstrap core, but not yet as the final low-friction product bootstrap.

The main blockers are not crypto or state-machine logic anymore. The blockers are:

1. discovery publication
2. authoritative entity resolution on the target scaffold
3. explicit scaffold admin trust root
4. purpose-driven post-bootstrap routing
5. narrowing the shipped CLI surface to the actual bootstrap job
