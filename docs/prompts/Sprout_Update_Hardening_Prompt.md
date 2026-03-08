# Prompt: Update Hardening Without Expanding Sprout

Du jobber i repoet `sprout` for HAVEN. Nåværende implementasjon holder `sprout` smal og flytter update-verifikasjon til et separat `sprout-updater`-binær.

## Relevante filer
- `Packages/SproutCore/Sources/SproutCore/UpdateGrantPolicy.swift`
- `Tests/SproutCoreTests/UpdateGrantPolicyTests.swift`
- `Apps/sprout-updater/Sources/sprout-updater/main.swift`
- `Scripts/build_release_bundle.sh`
- `Scripts/sign_release_bundle.sh`
- `Scripts/verify_release_bundle.sh`
- `.github/workflows/release.yml`
- `RELEASE.md`
- `SECURITY.md`
- `THREAT_MODEL.md`
- `docs/update_hardening_strategy.md`
- `docs/tuf_p2_plan.md`
- `docs/github_release_runbook.md`

## Oppgave
1. Hardn dagens separate updater-path uten å trekke mutasjonsmakt tilbake inn i `sprout`.
2. Hold bootstrap trust path og update trust path separert.
3. Hvis du implementerer noe i kode, gjør det som en separat updater/installer-komponent eller tydelig feature flag, ikke som skjult selvmutasjon i `sprout`.
4. Legg til faktisk provenance/signature-verification i CI eller release docs der dagens plassholdere eller miljøavhengige steg er for svake.
5. Design TUF metadata og rollback-beskyttelse for P2.

## Constraints
- `UpdateGrantPolicy` default deny
- ingen skjult privilege escalation
- iOS bruker App Store, ikke custom updater
- macOS outside App Store krever codesigning + notarization

## Akseptansekriterier
- Det finnes en dokumentert, verifiserbar update-strategi for CLI og macOS.
- Ingen update kan trigges uten eksplisitt grant.
- Dokumentasjonen forklarer hvorfor Sprout holdes liten og hvorfor updateren ikke bør være samme trust boundary.
