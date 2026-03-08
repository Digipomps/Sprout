# Prompt: Porthole Access Contract Interop

Du jobber i repoet `sprout` for HAVEN. Dagens kode har en signert `PortholeAccessContract` som bootstrap output for `web`, `cli` og `native`, konkrete consumer outputs i `SproutCore`, og en faktisk macOS-klient som bruker web/native-handoff.

## Relevante filer
- `Packages/SproutResolverAdapter/Sources/SproutResolverAdapter/ResolverAdapter.swift`
- `Packages/SproutResolverAdapter/Sources/SproutResolverAdapter/MockResolverAdapter.swift`
- `Packages/SproutCore/Sources/SproutCore/SproutBootstrapStateMachine.swift`
- `Packages/SproutCore/Sources/SproutCore/PortholeContractConsumer.swift`
- `Packages/SproutAppSupport/Sources/SproutAppSupport/PortholeClientSession.swift`
- `Apps/sprout-macos/Sources/sprout-macos/SproutMacOSApp.swift`
- `Schemas/WebPortholeBootstrapDescriptor.schema.json`
- `Schemas/NativePortholeBindingDescriptor.schema.json`
- `Schemas/PortholeAccessContract.schema.json`
- `TestVectors/porthole_access_contract.example.json`
- `docs/entity_bootstrap_and_porthole_access.md`
- `docs/interop_matrix.md`

## Oppgave
1. Integrer neste faktiske consumer utenfor Sprout-repoet, siden macOS-klienten nå finnes her.
2. Behold Sprout sine consumer descriptors som adapterlag, ikke som ny trust boundary.
3. Legg til kontraktverifikasjon i consumer-path, inkludert expiry og capability subset checks.
4. Dokumenter hvilke felter som er normative, og hvilke som er advisory.

## Constraints
- Transport er semantics-neutral
- Resolver-issued contract må være enforcement boundary
- Ingen capability widening i consumer
- Web, CLI og native skal være forskjellige presentasjonsformer over samme tilgangsmodell

## Akseptansekriterier
- Minst én ekstern klienttype kan parse og verifisere samme kontrakt gjennom den implementerte consumer-descriptoren.
- Interop matrix oppdateres med faktisk implementert consumer-status.
- Negative tester dekker expired contract, invalid signature og protocol mismatch.
