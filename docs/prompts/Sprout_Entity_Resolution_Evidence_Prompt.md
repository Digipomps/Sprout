# Prompt: Entity Resolution and Inclusion Proof

Du jobber i repoet `sprout` for HAVEN. Dagens implementasjon har:
- `EntityLinkEvidence` som wrapper rundt mutual `EntityLinkContract`
- `EntityResolutionDecision` som eksplisitt `resolved` eller `unresolved`
- `EntityAnchorSnapshot` som signert, filbasert projeksjon av entity anchor state
- `EntityInclusionProof` som resolver-signert medlemskapsbevis
- `EntityAnchorResolverAdapter` som kan løse direkte medlemskap eller anchor-akseptert link evidence

## Problem
Den grunnleggende proof-kjeden finnes nå, men den er fortsatt filbasert. Vi trenger en reell HAVEN-resolver-integrasjon og en revokasjonsmodell som ikke bryter dagens kontrakter.

## Relevante filer
- `Packages/SproutCore/Sources/SproutCore/EntityLinkContract.swift`
- `Packages/SproutCore/Sources/SproutCore/BootstrapModels.swift`
- `Packages/SproutCore/Sources/SproutCore/SproutBootstrapStateMachine.swift`
- `Packages/SproutResolverAdapter/Sources/SproutResolverAdapter/ResolverAdapter.swift`
- `Packages/SproutResolverAdapter/Sources/SproutResolverAdapter/MockResolverAdapter.swift`
- `Packages/SproutResolverAdapter/Sources/SproutResolverAdapter/EntityAnchorResolverAdapter.swift`
- `docs/entity_bootstrap_and_porthole_access.md`
- `docs/Sprout_Status_And_Entity_Bootstrap_Evaluation_2026-03-07.md`

## Oppgave
1. Design integrasjonen mellom Sprout og en autoritativ HAVEN resolver API uten å endre de allerede implementerte proof-kontraktene unødvendig.
2. Basér forslaget på HAVENs entity anchor / agreements / resolver-modell.
3. Spesifiser hvordan revocation/unlink og stale anchor state skal håndteres.
4. Hold mutual `EntityLinkContract` som bare ett input-signal, ikke som endelig membership proof.
5. Legg til tester for:
   - revoked inclusion proof
   - stale or mismatched anchor snapshot
   - cross-domain mismatch

## Constraints
- Ingen global identitet
- Ingen implicit linkage
- Resolver må fortsatt være enforcement point
- Klient må aldri syntetisere `entity_id`

## Akseptansekriterier
- Bootstrap kan hente eller verifisere inclusion proof eksplisitt mot en autoritativ resolver.
- Resolver kan avvise mutual link proof uten gyldig inclusion proof eller gyldig anchor state.
- Dokumentasjon forklarer tydelig forskjellen på link proof, anchor state og resolver-issued inclusion proof.
