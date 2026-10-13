import Foundation
import SproutCore
import SproutResolverAdapter

extension SproutCLI {
    @MainActor
    static func runIdentityLinkEnrollment(profile: OnboardingProfile,
                                          descriptor: ScaffoldAdminTrustRootDescriptor,
                                          identityRoot: URL) async throws -> Bool {
        guard let domain = profile.domain, let pin = profile.trustedAdminKeys[domain] else {
            throw OnboardingError.invalidInput
        }
        let client = IdentityLinkClient()
        if try await client.loadReceipt(domain: domain, identityRoot: identityRoot) != nil {
            terminalLinkSay("En lagret koblingskvittering finnes. Tjenesten maa bekrefte at koblingen fortsatt er gyldig; tilbakekalte koblinger gir ingen tilgang.")
            return true
        }
        var progress = try await client.loadProgress(domain: domain, identityRoot: identityRoot)
        if progress?.hasCompletion == true {
            terminalLinkSay("En tidligere signert fullfoering venter paa bekreftelse. Proever samme fullfoering igjen uten aa bytte noekkel eller godkjenning.")
            try OnboardingTrust.validate(descriptor, domain: domain, pinnedKey: pin)
            do {
                _ = try await client.retryCompletion(domain: domain, identityRoot: identityRoot)
                return true
            } catch IdentityLinkError.expiredCompletionUnavailable {
                terminalLinkSay("Tjenesten avviser gjenopptakelse av den utloepte fullfoeringen. Den gamle koblingen kan likevel ha blitt opprettet; kontroller enhetene paa https://\(domain)/link#devices.")
                terminalLinkSay("En ny invitasjon bevarer samme noekkel og UUID, arkiverer den gamle fullfoeringen privat og krever ny passkey-godkjenning. Ingen gammel kobling blir tilbakekalt automatisk.")
                guard terminalLinkAnswer("Vil du arkivere forsoeket og starte med ny invitasjon? Skriv ny invitasjon for aa fortsette:")?.lowercased() == "ny invitasjon" else { return false }
                _ = try await client.archiveExpiredCompletionForNewInvitation(domain: domain, identityRoot: identityRoot)
                progress = nil
            }
        }
        let pending: IdentityLinkPending
        if let saved = progress?.pending,
           let expiry = ISO8601DateFormatter().date(from: saved.ticket.expiresAt), expiry > Date() {
            terminalLinkSay("Fortsetter den lagrede forespoerselen med samme noekkel og kontrollord.")
            pending = saved
        } else {
            if progress != nil {
                terminalLinkSay("Den lagrede invitasjonen er utloept. En ny invitasjon vil bruke samme lokale noekkel.")
            }
            terminalLinkSay("Aapne https://\(domain)/link paa en enhet der du kan logge inn og bruke passkey for Entiteten du vil koble til.")
            terminalLinkSay("Opprett invitasjonen der. Lim bare haven://identity-link-lenken i denne terminalen, aldri passord eller private noekler. Lenken sendes ikke til en AI-tjeneste av Sprout.")
            terminalLinkSay("Et lokalt Entity-utkast oppretter ikke en personkonto paa tjenesten. Du maa ha tilgang til en Entitet der for aa godkjenne koblingen.")
            guard let link = terminalLinkAnswer("Invitasjonslenke (tomt svar eller /pause avbryter):"),
                  !link.isEmpty, link != "/pause" else { return false }
            guard link.utf8.count <= 16_384,
                  !link.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw OnboardingError.invalidInput
            }
            pending = try await client.prepare(deepLink: link, domain: domain, identityRoot: identityRoot,
                                                   descriptor: descriptor, pinnedKey: pin)
        }
        try OnboardingTrust.validate(descriptor, domain: domain, pinnedKey: pin)
        try await client.submit(pending)
        terminalLinkSay("Sammenlign kontrollordene med HAVEN: \(pending.controlWords.joined(separator: " · "))")
        terminalLinkSay("Godkjenn bare hvis ordene samsvarer, og bruk passkey i HAVEN. Invitasjonen utloeper \(pending.ticket.expiresAt).")
        for _ in 0..<4 {
            guard let answer = terminalLinkAnswer("Er kontrollordene sammenlignet og forespoerselen godkjent i HAVEN? [ja/pause]"),
                  answer.lowercased() == "ja" else { return false }
            try OnboardingTrust.validate(descriptor, domain: domain, pinnedKey: pin)
            guard let package = try await client.poll(pending) else {
                terminalLinkSay("Tjenesten venter fortsatt paa godkjenning. Ingen kobling er fullfoert.")
                continue
            }
            try OnboardingTrust.validate(descriptor, domain: domain, pinnedKey: pin)
            _ = try await client.complete(pending, package: package, identityRoot: identityRoot)
            terminalLinkSay("Koblingsreferansen er lagret privat. Kontrollerer naa Entity-tilknytningen mot tjenesten.")
            return true
        }
        terminalLinkSay("Godkjenningen er fortsatt ikke klar. Oppsett og noekler er beholdt.")
        return false
    }

    @MainActor
    private static func terminalLinkSay(_ message: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
    }

    @MainActor
    private static func terminalLinkAnswer(_ prompt: String) -> String? {
        terminalLinkSay(prompt + "\n> ")
        return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
