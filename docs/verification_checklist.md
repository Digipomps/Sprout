# Verification Checklist (Exit Criteria)

Denne sjekklisten brukes som exit criteria før produksjonssetting.

Status per 2026-03-08:
- P0-kravene er implementert og testet lokalt.
- P1 bridge-kravene for file-backed entity resolution, porthole consumers, live resolver client path og separat updater er implementert i `sprout`.
- Native Linux CLI/updater-baseline er implementert som repo-scope: Ubuntu 22.04 `x86_64`, ingen Docker påkrevd.
- Lokalt verifisert i denne workspacen: `swift build --product sprout`, `swift build --product sprout-updater`, `swift build --product sprout-macos`, `swift test`, `bash Scripts/build_release_bundle.sh /tmp/sprout-dist-verify`, `bash Scripts/verify_release_bundle.sh /tmp/sprout-dist-verify`, `bash Scripts/build_release_bundle.sh /tmp/sprout-dist-linux linux-x86_64`, `bash Scripts/verify_release_bundle.sh /tmp/sprout-dist-linux "" /tmp/sprout-dist-linux/SHA256SUMS-linux-x86_64.b64url`.
- Ikke marker listen som fullført før autoritativ server-side resolver, produksjonssignering og runtime-spesifikke release-krav faktisk er verifisert.

## Correctness og interop
- [ ] Alle JSON schemas validerer eksempelobjekter (JSON Schema 2020-12).
- [ ] JCS canonicalization matcher RFC 8785 for de støttede datatypene, og avviser unsupported numbers deterministisk.
- [ ] Golden test vectors: signatur og sha256 matcher bit-for-bit for StarterAuthPayload, BridgeDescriptor, EntityLinkContract.
- [ ] `EntityAnchorSnapshot` og `EntityInclusionProof` validerer mot schema og verifiserer signatur/expiry.
- [ ] `PortholeAccessContract` schema + eksempelinstans validerer og signaturen verifiserer.
- [ ] Bootstrap state machine har deterministiske transitions og kan replayes fra auditlogg.
- [ ] Ingen klientkode genererer syntetisk `entity_id`; entity er alltid `resolved` eller `unresolved` eksplisitt.
- [ ] `ScaffoldAdminIdentity` blir derivert eksplisitt fra signert bridge metadata eller annen autoritativ kilde.
- [ ] Live resolver adapter er bak eksplisitt feature flag og har tester for issuer pinning og full bootstrap happy path.
- [ ] Negativtestene dekker: feil signatur, utløpt payload, feil domene, manglende route, capability denial, unresolved entity, invalid entity evidence, invalid inclusion proof.

## Sikkerhet og personvern
- [ ] Ingen nettverkskall uten eksplisitt Purpose/Goal i request-context; dokumentert i code review.
- [ ] Discovery er opt-in og minimerer metadata; alignment med innebygd personvern og personvern som standard.
- [ ] `EntityLinkContract` alene gir ikke tilgang; resolver må gi eksplisitt entity resolution.
- [ ] `PortholeAccessContract` er signert, tidsbegrenset og kan ikke utvide capabilities utover resolverens beslutning.
- [ ] Resolver-issued inclusion proof og porthole contract kommer fra samme issuer eller eksplisitt autorisert kjede.
- [ ] Nøkkellagring: Apple bruker Keychain/Secure Enclave; CLI har en sikker keystore-strategi dokumentert.
- [ ] Transport baseline TLS 1.3 (https/wss); eventuelle alternativer (HTTP/2, QUIC/HTTP3) er bak feature flags.
- [ ] Linux release-scope er eksplisitt begrenset når transportparitet mangler; WSS på Linux er ikke implisitt støttet.
- [ ] NSM-prinsipper brukt som sikkerhetsbaseline i THREAT_MODEL.md (risikobasert, tiltak, logging, adgangskontroll).

## Distribusjon og supply chain
- [ ] Reproducible build-prosedyre dokumentert og kan kjøres av tredjepart; target: bit-for-bit for CLI.
- [ ] Release bundle bygger både `sprout` og `sprout-updater`, genererer checksum manifest og kan verifiseres lokalt.
- [ ] Native Linux release bundle er dokumentert med plattform-suffikserte artefakter og operator-styrt installasjon.
- [ ] Signerte artefakter: minst én av (cosign keyless, GPG) er aktiv i CI, med dokumentert verifikasjon.
- [ ] Provenance/attestation generert (SLSA-minimum + in-toto statement), og bundet til artefakt, eller eksplisitt deaktivert med dokumentert plattformbegrunnelse.
- [ ] Update behavior er policy-gated via UpdateGrantPolicy (default deny), og tester verifiserer at updater aldri overskrider eksplisitte grants.
- [ ] Sprout kan distribueres uten self-update som default for CLI/server; hvis custom updater aktiveres, er den policy-gated og separert fra bootstrap trust path.
- [ ] Hvis macOS-app distribueres utenfor App Store: notarization og code signing er del av release-prosessen og dokumentert.
