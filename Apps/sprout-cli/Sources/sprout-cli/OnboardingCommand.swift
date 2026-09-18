import Foundation
import SproutCore
import SproutStorage

extension SproutCLI {
    @MainActor
    static func runOnboarding(arguments: [String]) async throws {
        if arguments == ["--help"] || arguments == ["-h"] {
            print("sprout [onboard|chat] [--domain HOST] [--entity-mode new|existing] [--goal TEXT] [--purpose URI] [--interests LIST] [--state-dir DIRECTORY]")
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
        let domain = try flags["--domain"].map(StarterIdentityStore.validateDomain)
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
        })
        do {
            try await dialogue.run(defaults: .init(
                domain: domain, entityIntent: mode,
                purpose: flags["--purpose"] ?? "purpose://contact.communication",
                goal: flags["--goal"] ?? "Opprette en privat samtalekanal.",
                interests: flags["--interests"]?.split(separator: ",").map(String.init) ?? ["correspondence"]
            ))
        } catch PrivateStateError.busy {
            print("En annen Sprout-prosess bruker dette oppsettet. Avslutt den eller proev igjen senere.")
            throw OnboardingError.paused
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
