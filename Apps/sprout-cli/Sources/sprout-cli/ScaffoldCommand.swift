import Foundation
import SproutCore
import SproutCrypto
import SproutResolverAdapter
import SproutStorage

extension SproutCLI {
    /// Local scaffold administration does not confer remote Entity rights.
    @MainActor
    static func runScaffold(arguments: [String]) async throws {
        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
            sprout scaffold [purposes|plan|install|status] --domain HOST [--purpose ID,ID] [--channel stable|beta]
              [--catalog FILE | --catalog-url HTTPS_URL] [--trusted-publisher-key KEY] [--root DIRECTORY] [--yes] [--offline] [--download-only]
              [--instance NAME] [--port PORT] [--public-origin https://HOST]
              [--admin-port PORT] [--admin-public-origin https://ADMIN_HOST]
            Uten underkommando: velg formaal fra den signerte katalogen og bekreft installasjonsplanen.
            plan laster ingen bilder; install henter bilder og starter tjenesten paa Linux som root.
            --public-origin er tjenestens HTTPS-adresse; --port (9089) bindes bare til 127.0.0.1.
            --download-only stopper etter bildeinstallasjon. Ingen eier eller tjeneste opprettes da.
            --yes godkjenner planen; foerstegangstillit krever fortsatt en festet utgivernoekkel.
            status kontrollerer bilder; status --instance NAME kontrollerer den faktisk installerte tjenesten.
            """)
            return
        }
        var rest = arguments
        let command = rest.first.map { !$0.hasPrefix("--") } == true ? rest.removeFirst() : "dialogue"
        guard ["dialogue", "purposes", "plan", "install", "status"].contains(command) else { throw OnboardingError.invalidInput }
        let allowed: Set<String> = ["domain", "purpose", "channel", "catalog", "catalog-url", "trusted-publisher-key", "root", "yes", "offline", "download-only", "instance", "port", "public-origin", "admin-port", "admin-public-origin"]
        var flags: [String: String] = [:]
        while !rest.isEmpty {
            let flag = rest.removeFirst()
            guard flag.hasPrefix("--") else { throw OnboardingError.invalidInput }
            let key = String(flag.dropFirst(2))
            guard allowed.contains(key), flags[key] == nil else { throw OnboardingError.invalidInput }
            if key == "yes" || key == "offline" || key == "download-only" { flags[key] = "true"; continue }
            guard !rest.isEmpty, !rest[0].hasPrefix("--") else { throw OnboardingError.invalidInput }
            flags[key] = rest.removeFirst()
        }
        let root = URL(fileURLWithPath: flags["root"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/haven/sprout/scaffolds").path)
        let installs = root.appendingPathComponent("installations")
        if command == "status" {
            if let instance = flags["instance"] {
                let receipt = try await ScaffoldServiceController.run(ScaffoldServiceRequest.status(instance: instance))
                print(String(decoding: receipt, as: UTF8.self))
                return
            }
            try scaffoldJSON(await ScaffoldInstaller(root: installs, runtime: DockerScaffoldRuntime()).inspect())
            return
        }
        let domainText = try flags["domain"] ?? scaffoldAnswer("Hvilket HAVEN-domene skal levere scaffold-katalogen?")
        let domain = try StarterIdentityStore.validateDomain(domainText)
        let channel = flags["channel"] ?? "stable"
        guard ["stable", "beta"].contains(channel), !(flags["catalog"] != nil && flags["catalog-url"] != nil) else { throw OnboardingError.invalidInput }
        var publisher = flags["trusted-publisher-key"]
        let pinURL = root.appendingPathComponent("publisher-pins.json")
        var pins: [String: String] = [:]
        if PrivateStateFiles.exists(pinURL) {
            try PrivateStateFiles.validateDirectory(root)
            pins = try JSONDecoder().decode([String: String].self, from: PrivateStateFiles.read(pinURL))
            if let supplied = publisher, let old = pins[domain], supplied != old { throw OnboardingError.trustChanged }
            publisher = publisher ?? pins[domain]
        }
        let catalog: ScaffoldExecutableCatalog
        if let file = flags["catalog"] {
            guard let publisher else { throw ScaffoldInstallationError.publisherPinRequired }
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 1_048_577) ?? Data()
            guard bytes.count <= 1_048_576 else { throw ScaffoldInstallationError.invalidCatalog }
            catalog = try JSONDecoder().decode(ScaffoldExecutableCatalog.self, from: bytes)
            try ScaffoldExecutableCatalogValidator().validate(catalog: catalog, context: .init(expectedDomain: domain, trustedPublisherPublicKeys: [publisher]))
        } else {
            let descriptor = try await OnboardingHTTPService().discover(domain: domain)
            try OnboardingTrust.validate(descriptor, domain: domain, pinnedKey: publisher)
            if publisher == nil {
                guard flags["yes"] == nil else { throw ScaffoldInstallationError.publisherPinRequired }
                print("HTTPS-domenet \(domain) oppgir admin-noekkelen \(descriptor.scaffold_admin_public_key).")
                guard try scaffoldAnswer("Feste denne noekkelen som utgiver av installerbar programvare? [ja/nei]").lowercased() == "ja" else { return }
                publisher = descriptor.scaffold_admin_public_key
            }
            guard let publisher else { throw ScaffoldInstallationError.publisherPinRequired }
            let endpointText = flags["catalog-url"] ?? descriptor.software_catalog_url ?? ScaffoldExecutableCatalogHTTPClient.defaultEndpoint(scaffoldDomain: domain).absoluteString
            guard let endpoint = URL(string: endpointText) else { throw OnboardingError.unsafeEndpoint }
            catalog = try await ScaffoldExecutableCatalogHTTPClient(endpoint: endpoint).fetch(expectedDomain: domain, trustedPublisherPublicKeys: [publisher])
        }
        guard let publisher else { throw ScaffoldInstallationError.publisherPinRequired }
        // Persist trust after a verified catalog. Serialize with other trust writers.
        if pins[domain] == nil {
            let pinLock = try PrivateStateLock(directory: root)
            defer { withExtendedLifetime(pinLock) {} }
            if PrivateStateFiles.exists(pinURL) {
                pins = try JSONDecoder().decode([String: String].self, from: PrivateStateFiles.read(pinURL))
                if let old = pins[domain], old != publisher { throw OnboardingError.trustChanged }
            }
            pins[domain] = publisher
            try PrivateStateFiles.write(JSONEncoder().encode(pins), to: pinURL)
        }
        let platform = ScaffoldInstallationPlan.hostPlatform
        let purposes = Array(Set(catalog.artifacts.filter { $0.platform == platform && $0.channel == channel }.flatMap { $0.purpose_ids ?? [] })).sorted()
        guard catalog.version == "1.1", purposes.allSatisfy(ScaffoldInstallationPlan.validPurpose) else { throw ScaffoldInstallationError.invalidCatalog }
        if command == "purposes" { try scaffoldJSON(purposes); return }
        let requested: [String]
        if let purpose = flags["purpose"] {
            requested = purpose.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            guard command == "dialogue" else { throw ScaffoldInstallationError.invalidPurpose }
            guard !purposes.isEmpty else { throw ScaffoldInstallationError.purposeUnavailable(platform) }
            print("Hvilke formaal skal denne maskinens scaffolds oppfylle?")
            for (index, purpose) in purposes.enumerated() { print("\(index + 1). \(purpose)") }
            let values = try scaffoldAnswer("Velg ett eller flere numre, skilt med komma:").split(separator: ",")
            requested = try values.map { value in
                guard let number = Int(value.trimmingCharacters(in: .whitespaces)), purposes.indices.contains(number - 1) else { throw ScaffoldInstallationError.invalidPurpose }
                return purposes[number - 1]
            }
        }
        let plan = try ScaffoldInstallationPlan.make(catalog: catalog, domain: domain, publisherKeys: [publisher], purposes: requested, platform: platform, channel: channel)
        try scaffoldJSON(plan)
        if command == "plan" { return }
        let service: ScaffoldServiceRequest?
        if flags["download-only"] == "true" {
            service = nil
        } else {
            let origin: String
            if let value = flags["public-origin"] { origin = value }
            else if flags["yes"] == "true" { throw ScaffoldServiceError.invalidConfiguration }
            else { origin = try scaffoldAnswer("Hvilken HTTPS-adresse skal denne scaffold-tjenesten bruke? (https://HOST)") }
            guard let port = Int(flags["port"] ?? "9089") else { throw ScaffoldServiceError.invalidConfiguration }
            let adminOrigin: String
            if let value = flags["admin-public-origin"] { adminOrigin = value }
            else if flags["yes"] == "true" { throw ScaffoldServiceError.invalidConfiguration }
            else { adminOrigin = try scaffoldAnswer("Hvilken separat HTTPS-adresse skal den nye AdminScaffold bruke?") }
            let adminPortText: String
            if let value = flags["admin-port"] { adminPortText = value }
            else if flags["yes"] == "true" { throw ScaffoldServiceError.invalidConfiguration }
            else { adminPortText = try scaffoldAnswer("Hvilken ledig loopback-port skal AdminScaffold bruke?") }
            guard let adminPort = Int(adminPortText) else { throw ScaffoldServiceError.invalidConfiguration }
            service = try ScaffoldServiceRequest.make(plan: plan, instance: flags["instance"] ?? "scaffold",
                                                      port: port, publicOrigin: origin, adminPort: adminPort, adminPublicOrigin: adminOrigin)
            try ScaffoldServiceController.requireHostAccess()
            try scaffoldJSON(service!)
        }
        if flags["yes"] == nil {
            let prompt = service == nil ? "Hente og installere disse \(plan.artifacts.count) scaffold-bildene med Docker? [ja/nei]"
                : "Hente og installere web, egen AdminScaffold og signert node-agent, med separate lokale eiere og begrensede ressurser? [ja/nei]"
            guard try scaffoldAnswer(prompt).lowercased() == "ja" else { return }
        }
        if var preflight = service {
            preflight.operation = "preflight"
            _ = try await ScaffoldServiceController.run(preflight)
        }
        let receipts = try await ScaffoldInstaller(root: installs, runtime: DockerScaffoldRuntime(localDaemon: service != nil)).install(
            catalog: catalog, domain: domain, publisherKeys: [publisher], purposes: requested, platform: platform, channel: channel, offline: flags["offline"] == "true")
        try scaffoldJSON(receipts)
        if flags["offline"] == "true" { print("Offline: bare allerede tilgjengelige og digest-kontrollerte bilder er brukt. Ingen nedlasting ble utfoert.") }
        if let service {
            // Authorization must still hold immediately before executing the
            // signed image's fixed activation profile.
            _ = try ScaffoldInstallationPlan.make(catalog: catalog, domain: domain, publisherKeys: [publisher],
                                                  purposes: requested, platform: platform, channel: channel)
            let result = try await ScaffoldServiceController.run(service)
            print(String(decoding: result, as: UTF8.self))
            print("Tjenesten er startet og kontrollert paa loopback. HTTPS-proxy og offentlig tilgjengelighet kontrolleres separat.")
        } else {
            print("Installert og digest-kontrollert. --download-only: ingen tjeneste er startet.")
        }
        print("Kvitteringer: \(installs.path)")
    }

    private static func scaffoldAnswer(_ prompt: String) throws -> String {
        try FileHandle.standardOutput.write(contentsOf: Data((prompt + "\n> ").utf8))
        guard let answer = readLine(), answer != "/pause", OnboardingProfile.validAnswer(answer) else { throw OnboardingError.paused }
        return answer
    }

    private static func scaffoldJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
