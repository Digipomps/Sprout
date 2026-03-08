# Prompt: Scaffold Admin Trust Root Hardening

Du jobber i repoet `sprout` for HAVEN. Dagens kode gjør `ScaffoldAdminIdentity` eksplisitt i bootstrap state machine og derivere den fra signert `BridgeDescriptor.owner_pubkey`.

## Mål
Herd denne modellen uten å bryte disse constraints:
- domain-scoped identities
- entity != identity
- ingen implicit cross-domain linkage
- capability/contract-basert tilgang, resolver-enforced
- semantics-neutral transport
- ingen skjult privilege escalation

## Nåværende relevante filer
- `Packages/SproutCore/Sources/SproutCore/BootstrapModels.swift`
- `Packages/SproutCore/Sources/SproutCore/SproutBootstrapStateMachine.swift`
- `Packages/SproutBridge/Sources/SproutBridge/BridgeDescriptor.swift`
- `Packages/SproutBridge/Sources/SproutBridge/BridgeDescriptorValidator.swift`
- `Packages/SproutResolverAdapter/Sources/SproutResolverAdapter/ResolverAdapter.swift`
- `Packages/SproutResolverAdapter/Sources/SproutResolverAdapter/MockResolverAdapter.swift`
- `docs/entity_bootstrap_and_porthole_access.md`

## Oppgave
1. Evaluer om `BridgeDescriptor.owner_pubkey` er nok som scaffold admin trust root i HAVEN.
2. Hvis ikke, implementer en bedre modell med eksplisitt signert admin descriptor eller chain-of-trust.
3. Behold bakoverkompatibilitet i P1 via feature flag eller adapter.
4. Legg til negative tester for mismatch mellom bridge owner og admin identity.
5. Oppdater docs og verification checklist.

## Akseptansekriterier
- Bootstrap stopper hvis scaffold admin identity ikke kan verifiseres mot autoritativ metadata.
- Ingen porthole contract kan utstedes med annen scaffold admin key enn den validerte trust root.
- `swift test` grønn.
