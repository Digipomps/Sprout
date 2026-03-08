# Sprout-konseptvurdering (2026-02-26)

## 1. Kort konklusjon
HAVEN-repoene har allerede sterke byggesteiner for Sprout: domeneskopet identitet, resolverbasert routing, Porthole-orientert orkestrering, Purpose/Goal-modell og signerte flow-envelopes.  
Det som mangler for et lavfriksjons distribusjonsprodukt er en samlet, runtime-uavhengig bootstrap-kontrakt med tydelig eier-onboarding (server), oppdateringspolicy med eksplisitte rettigheter, og hardere sikkerhets- og testdekning rundt bootstrap-løpet.

## 2. Hva som finnes i dag (evidens)

### 2.1 Konseptuelt grunnlag er tydelig
- Domene-skopet identitet, ingen global ID, transport-semantic-neutral:
  - `../CellProtocolDocuments/Book/01_CellProtocol_Core.md:23`
  - `../CellProtocolDocuments/Book/03_Identity_Model.md:9`
  - `../CellProtocolDocuments/Book/08_Bridging_Transport.md:6`
- Purpose/Goal som eksplisitt semantisk lag:
  - `../CellProtocolDocuments/Book/09_Purpose_Interests.md:29`
  - `../CellProtocolDocuments/Book/09_Purpose_Interests.md:36`

### 2.2 Runtime/bootstrap-komponenter er delvis implementert
- Apple bootstrap (`AppInitializer`) setter vault/resolver/transports/porthole:
  - `../CellProtocol/Sources/CellApple/Cells/Porthole/Utility Views/Skeleton/AppInitializer.swift:83`
  - `../CellProtocol/Sources/CellApple/Cells/Porthole/Utility Views/Skeleton/AppInitializer.swift:123`
- Server bootstrap (`configure.swift`) setter owner-context og lager scaffold-owner/porthole:
  - `../CellScaffold/Sources/App/configure.swift:246`
  - `../CellScaffold/Sources/App/configure.swift:381`
- Resolver støtter host-mapping `cell://host/...` -> `ws(s)://...`:
  - `../CellProtocol/Sources/CellBase/Cells/CellResolver/CellResolver.swift:323`
  - `../CellProtocol/Sources/CellBase/Cells/CellResolver/CellResolver.swift:701`

### 2.3 Purpose/Goal i operativ kode
- `ConfigurationCatalogCell` har `purpose`, `interests`, `goal` og bootstrap/sync:
  - `../CellScaffold/Sources/App/Cells/ConfigurationCatalog/ConfigurationCatalogCell.swift:26`
  - `../CellScaffold/Sources/App/Cells/ConfigurationCatalog/ConfigurationCatalogCell.swift:559`
  - `../CellScaffold/Sources/App/Cells/ConfigurationCatalog/ConfigurationCatalogCell.swift:605`

### 2.4 Kryptografiske byggesteiner finnes
- Flow-signering/verifisering:
  - `../CellProtocol/Sources/CellBase/Flow/FlowEnvelopeSigner.swift:3`
  - `../CellProtocol/Sources/CellBase/Flow/FlowEnvelopeVerifier.swift:3`
- Server/browser-vault bruker moderne AEAD + HKDF (ChaChaPoly):
  - `../CellProtocol/Sources/CellVapor/VaporIdentityVault.swift:177`
  - `../CellScaffold/Sources/App/common/BrowserClientIdentityVault.swift:187`

## 3. Gap mot Sprout-målbildet

### 3.1 Felles MCM-bootstrap mangler
- Ingen samlet runtime-uavhengig “MCM bootstrap protocol” som styrer første oppstart for cloud/on-prem/desktop/mobile med samme kontrakt.
- Dagens bootstrap er spredt i `AppInitializer`, `configure.swift`, enkelte celler og UI-flow.

### 3.2 Server-eier bootstrap er for snever
- Serverløpet er primært env/context-bundet (`CELL_SCAFFOLD_OWNER_*`) og mangler ferdig produktisert zero-config/QR-kanal.
- `Bridgehead` bruker hardkodet `"Scaffold"` i identity-oppslag:
  - `../CellScaffold/Sources/App/Controllers/VaporBridgehead.swift:64`

### 3.3 Discovery-kanaler er ikke konsolidert
- Apple har Multipeer discovery i `EntityRadar`, men dette er ikke en generell server bootstrap-kanal:
  - `../CellProtocol/Sources/CellApple/EntityRadar/ScannerService.swift:147`
- Ingen tydelig QR-bootstrap implementasjon for scaffold-owner-identity (kun “qr-scan” som domene-data i LeadVault harness):
  - `../CellScaffold/Public/js/lead-vault-harness.js:141`

### 3.4 Oppdateringsmodell mangler produktsikring
- Oppdatering fremstår i praksis som manuell deploy/build (docker/git pull), ikke policy-styrt executable update med eksplisitte rettigheter:
  - `../CellScaffold/README.md:16`
- Ingen tydelig dokumentert signert artifact + verifiserbar reproducerbar build-prosess for Sprout-executable.

### 3.5 Herding-gap i vault-lag
- Apple `IdentityVault` har fortsatt legacy-mønstre og sensitiv logging (nøkler/dekryptert data printes):
  - `../CellProtocol/Sources/CellApple/IdentityVault.swift:335`
  - `../CellProtocol/Sources/CellApple/IdentityVault.swift:379`
- Legacy fallback-nøkler finnes fortsatt i server/browser-vault (for migrering), og må styres strengere i prod:
  - `../CellProtocol/Sources/CellVapor/VaporIdentityVault.swift:40`
  - `../CellScaffold/Sources/App/common/BrowserClientIdentityVault.swift:47`

### 3.6 Testgap for bootstrap/distribusjon
- Det finnes tester for resolver-scope og flow-crypto, men ikke for:
  - owner-bootstrap-kanaler
  - remote host route/policy negativscenarier
  - oppdateringsrettigheter/deny-by-default
  - cross-runtime bootstrap parity
- Eksempel eksisterende tester:
  - `../CellProtocol/Tests/CellBaseTests/ResolverTests.swift:22`
  - `../CellProtocol/Tests/CellBaseTests/FlowEnvelopeCryptoTests.swift:24`

## 4. Anbefalt MCM for Sprout (minimalt)
1. Definer én normativ bootstrap-state-machine med eksplisitte steg:
   - `PurposeGoalValidation -> OwnerIdentityAcquisition -> RouteRegistration -> PortholeAttach -> HelperCellReady`
2. Lag runtime-adaptere per profil:
   - cloud/on-prem: owner via env/zeroconf/QR
   - desktop/mobile: self-init + secure vault
3. Standardiser owner bootstrap payload:
   - signert, tidsbegrenset, domene-bundet, replay-beskyttet
4. Innfør “update policy gate”:
   - operasjoner som `replaceExecutable` og `restartProcess` krever eksplisitt grant
5. Lukk sikkerhetshull:
   - fjern sensitiv logging
   - fjern/feature-gate legacy crypto paths i prod
6. Etabler dedikerte tester for bootstrap-kritiske stier.

## 5. Konkret levert i `sprout` nå
For å gjøre dette testbart i eget repo er følgende lagt til:
- Runtime-uavhengig bootstrap-planlegger:
  - `sprout/BootstrapPlanner.swift`
- Eksplisitt executable update-policy:
  - `sprout/ExecutableUpdatePolicy.swift`
- Enhetstester for bootstrapvalg og update-rights:
  - `sproutTests/BootstrapPlannerTests.swift`
