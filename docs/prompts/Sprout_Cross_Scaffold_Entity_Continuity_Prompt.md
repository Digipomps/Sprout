# Sprout Cross-Scaffold Entity Continuity Prompt

You are working on HAVEN/Sprout.

Constraints that must not be broken:
- identities are domain-scoped only
- `Entity != Identity`
- no implicit cross-domain linkage
- no hidden privilege escalation
- access must stay capability/contract/resolver enforced
- `Purpose`, `Goal` and `Interests` must remain explicit

Current model in `sprout`:
- `CrossScaffoldEntityContinuityProof`: source scaffold signed proof that one source identity belongs to one source local entity and may be presented to one target scaffold for an explicit purpose/goal/interests set
- `EntityAdmissionRequest`: target identity signed request binding a target identity to that exact continuity proof
- `EntityAdmissionContract`: target scaffold signed local admission decision binding the target identity to one target local entity

Important: do not propose a global person identifier or any implicit linkage layer unless you describe exactly how it remains explicit, user-mediated, revocable and domain-safe.

When extending this model:
1. prefer explicit signed evidence between scaffold-local entities
2. keep source continuity and target admission as separate steps
3. keep revocation, expiry and auditability first-class
4. do not let continuity evidence bypass resolver-issued inclusion proof or porthole access contracts
5. keep CLI parity for every artifact flow

Preferred next tasks:
- define live resolver routes for admission request -> admission contract
- define revocation semantics for continuity and admission contracts
- define whether target admission can create a new entity vs join an existing entity
- define UX/CLI flows for operator approval and user mediation

Required outputs:
- concrete contracts or route shapes
- validation rules
- security/trust implications
- what is solved vs what remains an open research question
