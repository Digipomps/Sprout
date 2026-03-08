# Prompt: Live HAVEN Resolver Integration

Du jobber i repoet `sprout` for HAVEN. Dagens kode har allerede:
- `EntityAnchorResolverAdapter` som filbasert bro for entity resolution
- `EntityInclusionProof` som resolver-signert proof-format
- state machine-validering av inclusion proof før `PortholeAccessContract`
- `HavenResolverHTTPAdapter` som feature-flagget live klientadapter
- `OpenAPI/resolver.openapi.yaml` som live resolver-kontrakt

## Problem
Det som mangler er HAVEN server-side implementasjon av resolverkontrakten og en produksjonsklar revokasjonsmodell.

## Relevante filer
- `Packages/SproutResolverAdapter/Sources/SproutResolverAdapter/ResolverAdapter.swift`
- `Packages/SproutResolverAdapter/Sources/SproutResolverAdapter/EntityAnchorResolverAdapter.swift`
- `Packages/SproutResolverAdapter/Sources/SproutResolverAdapter/HavenResolverHTTPAdapter.swift`
- `Packages/SproutCore/Sources/SproutCore/SproutBootstrapStateMachine.swift`
- `Packages/SproutTransport/Sources/SproutTransport/TransportInterfaces.swift`
- `OpenAPI/resolver.openapi.yaml`
- `OpenAPI/discovery.openapi.yaml`
- `docs/entity_bootstrap_and_porthole_access.md`
- `docs/live_resolver_integration.md`
- `docs/roadmap.md`
- `THREAT_MODEL.md`

## Oppgave
1. Implementer HAVEN server-side ruter som matcher den eksisterende live resolver-kontrakten.
2. Behold mappingen til dagens `EntityResolutionDecision`, `EntityInclusionProof` og `PortholeAccessContract`.
3. Beskriv autentisering, replay-beskyttelse, revocation og stale-proof håndtering.
4. Hvis API mangler i HAVEN i dag, spesifiser minimum nødvendige endringer i resolveren for å støtte denne flyten.
5. Legg til teststrategi for staging og failure modes.

## Constraints
- Domain-scoped identities only
- `Entity != Identity`
- Ingen implicit cross-domain linkage
- Resolver forblir enforcement point
- Ingen capability widening
- Ingen nettverkskall uten eksplisitt `Purpose/Goal`

## Akseptansekriterier
- Det finnes en konkret server-implementasjon som den allerede implementerte HTTP-adapteren kan bruke uten å endre bootstrap state machine-kontraktene.
- Dokumentasjonen forklarer hvordan inclusion proof utstedes, verifiseres og revokeres i produksjon.
- Failure modes er eksplisitt listet med testbare forventninger.
