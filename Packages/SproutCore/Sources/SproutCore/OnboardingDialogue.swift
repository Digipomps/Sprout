import Foundation
import SproutStorage

public struct OnboardingDefaults: Sendable {
    public var domain: String?
    public var entityIntent: OnboardingEntityIntent?
    public var purpose: String
    public var goal: String
    public var interests: [String]

    public init(domain: String? = nil, entityIntent: OnboardingEntityIntent? = nil,
                purpose: String = "purpose://contact.communication",
                goal: String = "Opprette en privat samtalekanal.", interests: [String] = ["correspondence"]) {
        self.domain = domain
        self.entityIntent = entityIntent
        self.purpose = purpose
        self.goal = goal
        self.interests = interests
    }
}

/// A deterministic terminal conversation. No LLM, transcript collection or implicit approvals.
@MainActor
public final class OnboardingDialogue {
    private let store: OnboardingProfileStore
    private let service: any OnboardingService
    private let ask: (String) -> String?
    private let say: (String) -> Void
    private var profile: OnboardingProfile?

    public init(root: URL, service: any OnboardingService,
                ask: @escaping (String) -> String?, say: @escaping (String) -> Void) {
        store = OnboardingProfileStore(root: root)
        self.service = service
        self.ask = ask
        self.say = say
    }

    public func run(defaults: OnboardingDefaults = .init()) async throws {
        say("Sprout: lokalt oppsett og identitetskontroll. /help, /status eller /pause virker ved alle spoersmaal.")
        say("Ikke skriv passord, private noekler eller beviser i chatten. Sprout sender ikke chatten til en AI-tjeneste.")
        say("Assistenten du selv bruker kan sende eller lagre terminalteksten etter sine egne regler.")
        say("Lokal lagring: \(Self.display(store.root.path)). Her beholdes noekler, svar og offentlige tillitsreferanser til du sletter dem. Sprout lagrer ingen samtalelogg.")
        say("Filene beskyttes av OS-brukerens tilgang, ikke av et maskinvarehvelv. Ingen nettverkstilgang uten egen bekreftelse.")
        do {
            guard try confirm("Tillat lokal lagring og gjenopptakelse? [ja/nei]") else { return }
            let lock = try PrivateStateLock(directory: store.root)
            defer { withExtendedLifetime(lock) {} }
            profile = try await store.loadOrCreate()
            say("En lokal startidentitet er klar. Dette er et Entity-utkast, ikke en registrert Entity eller scaffold-eier.")
            while true {
                try collectAnswers(defaults: defaults)
                showStatus()
                let review = try answer("Er svarene riktige? [ja/endre/nei]")
                if review == "endre" {
                    // Keep identity and trust pins when editing preferences; never silently rotate trust.
                    profile?.entityIntent = nil
                    profile?.purpose = nil
                    profile?.goal = nil
                    profile?.interests = nil
                    profile?.domain = nil
                    profile?.lastOutcome = .localOnly
                    try save()
                    continue
                }
                if review == "nei" { throw OnboardingError.paused }
                if review == "ja" { break }
                say("Svar ja, endre eller nei.")
            }
            guard let domain = profile?.domain else {
                say("Oppsettet er lagret lokalt. Start sprout igjen naar du vet hvilken tjeneste du vil bruke.")
                return
            }
            say("Foerste nettverkssteg: GET https://\(domain)/.well-known/haven-scaffold-admin-trust-root.json. Tjenesten ser IP-adressen din, men faar ikke svarene eller identiteten din.")
            guard try confirm("Hente offentlig tjenestebeskrivelse naa? [ja/nei]") else { throw OnboardingError.paused }
            let descriptor = try await service.discover(domain: domain)
            try OnboardingTrust.validate(descriptor, domain: domain, pinnedKey: profile?.trustedAdminKeys[domain])
            if profile?.trustedAdminKeys[domain] == nil {
                say("Tilliten bygger foreloepig paa HTTPS til domenet du valgte, ikke en uavhengig HAVEN-godkjenning. Admin-noekkelen festes lokalt og kan ikke byttes stille.")
                guard try confirm("Godta denne foerstegangstilliten? [ja/nei]") else { throw OnboardingError.paused }
                profile?.trustedAdminKeys[domain] = descriptor.scaffold_admin_public_key
                try save()
            }
            say("Neste steg sender formaal, maal, interesser, runtime, en domenespesifikk offentlig noekkel og en signert engangsutfordring til \(domain). Den lokale utkastnoekkelen sendes aldri.")
            say("POST \(Self.display(descriptor.starter_bootstrap_url)); POST https://\(domain)/v1/resolver/starter-auth/register; POST https://\(domain)/v1/resolver/entities/resolve.")
            say("Dette ber bare om registrering og identitetskontroll, ikke sammenslaaing, kanaltilgang eller betaling. Tjenestens oppbevaring er ikke verifisert av Sprout; den kan beholde forespoerslene.")
            guard try confirm("Sende dette og kontrollere identiteten naa? [ja/nei]") else { throw OnboardingError.paused }
            guard let current = profile else { throw OnboardingError.recoveryRequired }
            let outcome = try await service.resolve(
                profile: current, descriptor: descriptor,
                identityRoot: store.root.appendingPathComponent("scaffold-identities", isDirectory: true)
            )
            profile?.lastOutcome = outcome
            try save()
            switch outcome {
            case .localOnly:
                say("Bare lokalt oppsett er fullfoert.")
            case .awaitingApproval:
                say("Startidentiteten er registrert, men mangler verifisert Entity-tilknytning. Godkjenning fra en eksisterende enhet eller opprettelse hos tjenesten er ikke koblet inn i denne dialogen ennaa. Ingen filer skal flyttes; oppsettet kan gjenopptas etter at tjenesten har stoette for godkjenningen.")
            case .identityVerified:
                say("Tjenesten har levert et kontrollert bevis for identitetens Entity-tilknytning. Dette er ikke en aktiv kanal eller fullverdig nettverksmedlemskap. Bridge, Agreement og Grants maa fortsatt kobles til kanalstarten.")
            }
        } catch OnboardingError.paused {
            say(profile == nil ? "Avsluttet uten oppsett eller nettverkskall." : "Pauset. Lagrede svar og noekler beholdes; neste start ber om nytt nettverkssamtykke.")
        }
    }

    private func collectAnswers(defaults: OnboardingDefaults) throws {
        if profile?.entityIntent == nil {
            while true {
                let value = try answer("Starte et nytt lokalt Entity-utkast, eller knytte til en eksisterende Entity? [ny/eksisterende]", defaultValue: defaults.entityIntent.map { $0 == .newLocal ? "ny" : "eksisterende" })
                if value == "ny" { profile?.entityIntent = .newLocal; break }
                if value == "eksisterende" { profile?.entityIntent = .existing; break }
                say("Velg ny eller eksisterende. Et navn eller en Entity-ID alene gir aldri tilgang.")
            }
            try save()
        }
        if profile?.goal == nil {
            let goal = try answer("Hva vil du oppnaa? Unngaa personnavn og andre private detaljer.", defaultValue: defaults.goal)
            profile?.goal = goal
            try save()
        }
        if profile?.purpose == nil {
            let purpose = try answer("Hvilket formaal skal tilgangen begrenses til?", defaultValue: defaults.purpose)
            profile?.purpose = purpose
            try save()
        }
        if profile?.interests == nil {
            while true {
                let raw = try answer("Hvilke interesser skal matches? Bruk komma mellom flere.", defaultValue: defaults.interests.joined(separator: ","))
                let values = raw.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                guard values.count <= 16, values.allSatisfy(OnboardingProfile.validAnswer) else {
                    say("Oppgi 1 til 16 ikke-tomme interesser."); continue
                }
                profile?.interests = Array(Set(values)).sorted()
                try save()
                break
            }
        }
        if profile?.domain == nil {
            while true {
                let raw = try answer("Hvilket scaffold-domene vil du bruke? Skriv bare vertsnavnet, eller senere.", defaultValue: defaults.domain ?? "senere")
                if raw == "senere" { break }
                guard let domain = try? StarterIdentityStore.validateDomain(raw) else {
                    say("Bruk et vertsnavn uten sti, port eller https://, eller skriv senere."); continue
                }
                profile?.domain = domain
                try save()
                break
            }
        }
    }

    private func confirm(_ prompt: String) throws -> Bool {
        while true {
            switch try answer(prompt).lowercased() {
            case "ja", "yes": return true
            case "nei", "no": return false
            default: say("Skriv ja eller nei. Tomt svar gir aldri samtykke.")
            }
        }
    }

    private func answer(_ prompt: String, defaultValue: String? = nil) throws -> String {
        while true {
            let suffix = defaultValue.map { " [\(Self.display($0))]" } ?? ""
            guard let raw = ask(prompt + suffix) else { throw OnboardingError.paused }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch value {
            case "/pause", "/quit": throw OnboardingError.paused
            case "/status": showStatus(); continue
            case "/help":
                say("Svar med tekst. Enter bruker bare viste standardverdier, aldri samtykke. /status viser lagrede svar. /pause avslutter trygt. Ingen innliming av filer, beviser eller hemmeligheter er noedvendig.")
                continue
            default: break
            }
            let result = value.isEmpty ? (defaultValue ?? "") : value
            guard OnboardingProfile.validAnswer(result) else {
                say("Skriv et svar paa 1 til 512 byte uten kontrolltegn, eller /pause."); continue
            }
            return result
        }
    }

    private func showStatus() {
        guard let profile else { say("Ingen lokal lagring er aapnet."); return }
        say("Lagret oenske: \(profile.entityIntent?.rawValue ?? "ikke valgt"); maal: \(Self.display(profile.goal ?? "ikke valgt")); formaal: \(Self.display(profile.purpose ?? "ikke valgt")); interesser: \(Self.display(profile.interests?.joined(separator: ", ") ?? "ikke valgt")); domene: \(profile.domain ?? "senere").")
        say("Forrige kontroll: \(profile.lastOutcome.rawValue). Dette er historikk, ikke aktiv tilgang.")
    }

    private func save() throws {
        guard let profile else { throw OnboardingError.recoveryRequired }
        try store.save(profile)
    }

    private static func display(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
    }
}
