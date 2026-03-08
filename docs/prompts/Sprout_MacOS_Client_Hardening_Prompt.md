# Prompt: Sprout macOS Client Hardening

Du jobber i repoet `sprout`. Det finnes nå en faktisk macOS-klient:
- `sprout-macos`
- `PortholeClientSession` i `SproutAppSupport`
- innebygd webvisning for `web` contracts
- live native CellProtocol-binding for `native` contracts via `NativePortholeBindingRuntime`

## Problem
Klienten fungerer, men trenger videre hardening og bedre brukerflyt for produksjonsbruk.

## Relevante filer
- `Apps/sprout-macos/Sources/sprout-macos/SproutMacOSApp.swift`
- `Apps/sprout-macos/Sources/sprout-macos/PortholeClientViewModel.swift`
- `Apps/sprout-macos/Sources/sprout-macos/PortholeWebView.swift`
- `Apps/sprout-macos/Sources/sprout-macos/NativePortholeHostView.swift`
- `Packages/SproutAppSupport/Sources/SproutAppSupport/PortholeClientSession.swift`
- `Packages/SproutAppSupport/Sources/SproutAppSupport/NativePortholeBindingRuntime.swift`
- `docs/entity_bootstrap_and_porthole_access.md`
- `docs/user_guide.md`

## Oppgave
1. Hardne macOS-klienten for produksjonsbruk.
2. Vurder kontraktimport via drag-and-drop, bedre error states og klarere trust-indikatorer.
3. Hvis du utvider web-klienten, ikke innfør ny trust boundary; bruk fortsatt den signerte kontrakten som enforcement artifact.
4. Behold dagens native CellProtocol-binding, men hardne den uten å bryte kontraktmodellen.

## Constraints
- Ingen capability widening i klient
- Ingen skjult bootstrap eller update-logikk i macOS-klienten
- Web/native-klienten er consumer av kontrakten, ikke autoritativ kilde

## Akseptansekriterier
- Klienten er tydelig på hvilken kontrakt som er lastet, hvem som utstedte den og når den utløper.
- Feiltilstander for invalid signature/expired contract blir presentert tydelig.
- Dokumentasjonen forklarer hva som fortsatt er advisory vs normative felt.
