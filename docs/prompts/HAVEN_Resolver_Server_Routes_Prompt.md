# Prompt: HAVEN Resolver Server Routes For Sprout

Du jobber i HAVEN server-repoet, ikke i `sprout`. Klientdelen i `sprout` har nå:
- `HavenResolverHTTPAdapter`
- `OpenAPI/resolver.openapi.yaml`
- state machine som krever resolver-issued `EntityInclusionProof` før `PortholeAccessContract`

## Problem
Sprout-klienten kan nå snakke en live resolver-kontrakt, men HAVEN server-side ruter som implementerer denne kontrakten finnes ikke ferdig.

## Relevante filer i sprout
- `OpenAPI/resolver.openapi.yaml`
- `Packages/SproutResolverAdapter/Sources/SproutResolverAdapter/HavenResolverHTTPAdapter.swift`
- `Packages/SproutCore/Sources/SproutCore/SproutBootstrapStateMachine.swift`
- `docs/live_resolver_integration.md`

## Oppgave
1. Implementer server-ruter som matcher resolver OpenAPI-kontrakten.
2. Bruk eksisterende HAVEN entity anchor / resolver / agreement-modell som autoritativ kilde.
3. Sørg for at `EntityLinkContract` aldri alene gir tilgang; serveren må utstede inclusion proof eksplisitt.
4. Sørg for at porthole-kontrakter og inclusion proofs signeres av en eksplisitt resolver trust root.
5. Legg til tester for unresolved entity, stale proof, wrong scaffold admin key og capability denial.

## Constraints
- Domain-scoped identities only
- `Entity != Identity`
- Ingen implicit cross-domain linkage
- Resolver forblir enforcement point
- Ingen capability widening

## Akseptansekriterier
- Sprout live adapter kan brukes mot staging uten klientendringer.
- Serveren returnerer samme proof/contract shape som Sprout allerede validerer.
- Feiltilstander er eksplisitte og testede.
