import Foundation
import SproutCore
import SproutStorage
import SproutResolverAdapter

extension SproutCLI {
    @MainActor
    static func runOnboarding(arguments: [String]) async throws {
        if let role = arguments.firstIndex(of: "--role"), arguments.indices.contains(role + 1), arguments[role + 1] == "scaffoldadmin" {
            var scaffoldArguments = arguments
            scaffoldArguments.removeSubrange(role...(role + 1))
            try await runScaffold(arguments: scaffoldArguments)
            return
        }
        if arguments == ["--help"] || arguments == ["-h"] {
            print("sprout [onboard|chat] [--domain HOST] [--entity-mode new|existing] [--goal TEXT] [--purpose URI] [--interests LIST] [--state-dir DIRECTORY]")
            print("For lokal scaffold-administrasjon: sprout onboard --role scaffoldadmin --domain HOST (eller sprout scaffold --help).")
            print("Alle verdier kan gis i terminaldialogen. Argumenter gir forslag, aldri samtykke eller identitetsbevis.")
            return
        }
        let allowed: Set<String> = ["--domain", "--entity-mode", "--goal", "--purpose", "--interests", "--state-dir"]
        var flags: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard allowed.contains(key), flags[key] == nil, index + 1 < arguments.count else {
                throw OnboardingError.invalidInput
            }
            let value = arguments[index + 1]
            guard OnboardingProfile.validAnswer(value), !value.hasPrefix("--") else { throw OnboardingError.invalidInput }
            flags[key] = value
            index += 2
        }
        let domain: String?
        do { domain = try flags["--domain"].map(StarterIdentityStore.validateDomain) }
        catch { throw OnboardingError.invalidInput }
        let mode = flags["--entity-mode"].flatMap(OnboardingEntityIntent.init(rawValue:))
        if flags["--entity-mode"] != nil && mode == nil { throw OnboardingError.invalidInput }
        let environment = ProcessInfo.processInfo.environment
        let root: URL
        if let path = flags["--state-dir"] {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else if let xdg = environment["XDG_STATE_HOME"], xdg.hasPrefix("/") {
            root = URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("haven/sprout")
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/haven/sprout")
        }
        let dialogue = OnboardingDialogue(root: root, service: OnboardingHTTPService(), ask: { prompt in
            // FileHandle avoids stdio buffering when an assistant drives stdin/stdout pipes.
            try? FileHandle.standardOutput.write(contentsOf: Data((prompt + "\n> ").utf8))
            return readLine()
        }, say: { message in
            try? FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
        }, enroll: { profile, descriptor, identityRoot in
            try await runIdentityLinkEnrollment(profile: profile, descriptor: descriptor, identityRoot: identityRoot)
        })
        do {
            try await dialogue.run(defaults: .init(
                domain: domain, entityIntent: mode,
                purpose: flags["--purpose"] ?? OnboardingDefaults().purpose,
                goal: flags["--goal"] ?? OnboardingDefaults().goal,
                interests: flags["--interests"]?.split(separator: ",").map(String.init) ?? OnboardingDefaults().interests
            ))
        } catch OnboardingError.paused {
            print("Pauset. Oppsett og noekler er beholdt.")
        } catch IdentityLinkError.expired {
            print("Invitasjonen eller godkjenningen er utloept. Opprett en ny invitasjon fra HAVEN; samme lokale noekkel beholdes.")
            throw OnboardingError.paused
        } catch IdentityLinkError.recoveryRequired {
            print("En ufullfoert kobling trenger gjenopptakelse. Ikke slett identitetsfilene eller lag en ny noekkel.")
            throw OnboardingError.recoveryRequired
        } catch is IdentityLinkError {
            print("Koblingen kunne ikke bekreftes. Ingen Entity-tilgang er rapportert; lokale noekler og eventuell kvittering beholdes.")
            throw OnboardingError.invalidProof
        } catch PrivateStateError.busy {
            print("En annen Sprout-prosess bruker dette oppsettet. Avslutt den eller proev igjen senere.")
            throw OnboardingError.paused
        } catch OnboardingError.trustDescriptorExpired, ScaffoldAdminTrustRootDescriptorValidationError.expired {
            print("Tjenestens tillitsbeskrivelse er utloept. Kontroller systemklokken; tjenesteadministratoren maa fornye den signerte beskrivelsen. Lokale noekler og tillitsreferanser er beholdt. Ingen flere forespoersler sendes med den utloepte beskrivelsen. Proev igjen etter fornyelse; ikke slett oppsettet eller omgaa kontrollen.")
            throw OnboardingError.trustDescriptorExpired
        } catch OnboardingError.trustChanged {
            print("Tjenestens admin-noekkel er endret. Oppsettet er stoppet; ingen automatisk tillitsendring er tillatt.")
            throw OnboardingError.trustChanged
        } catch OnboardingError.recoveryRequired {
            print("Lokal lagring mangler eller er skadet. Oppsettet er stoppet uten aa erstatte noekler. Ikke slett eller nullstill oppsettet; gjenoppretting maa bevare identiteten.")
            throw OnboardingError.recoveryRequired
        } catch is PrivateStateError {
            print("Lagringen har utrygge filtyper eller tilganger. Ingen noekler er erstattet. Kontroller eier og private filtilganger foer du proever igjen.")
            throw OnboardingError.recoveryRequired
        } catch is StarterIdentityStoreError {
            print("Startidentiteten kunne ikke lastes sikkert. Ingen ny identitet erstatter den; oppsettet trenger gjenoppretting.")
            throw OnboardingError.recoveryRequired
        } catch {
            // Never echo server-controlled errors or credentials into the terminal.
            print("Tjenestekontrollen feilet eller svaret kunne ikke godtas. Dette betyr ikke at lokal lagring er skadet. Ingen tilgang er tildelt; start sprout igjen for aa proeve paa nytt med nytt samtykke.")
            throw OnboardingError.serviceUnavailable
        }
    }
}
