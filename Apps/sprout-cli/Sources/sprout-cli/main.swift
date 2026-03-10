import Foundation
import SproutCore
import SproutBridge
import SproutCrypto
import SproutEconomics
import SproutResolverAdapter
import SproutStorage

@main
struct SproutCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            printUsage()
            exit(1)
        }

        do {
            switch arguments[0] {
            case "bootstrap":
                try await runBootstrap(arguments: Array(arguments.dropFirst()))
            case "bridges":
                try runBridges(arguments: Array(arguments.dropFirst()))
            case "federation":
                try await runFederation(arguments: Array(arguments.dropFirst()))
            case "link":
                try runLink(arguments: Array(arguments.dropFirst()))
            case "porthole":
                try runPorthole(arguments: Array(arguments.dropFirst()))
            case "verify":
                try runVerify(arguments: Array(arguments.dropFirst()))
            case "economics":
                try await runEconomics(arguments: Array(arguments.dropFirst()))
            case "update":
                try runUpdate(arguments: Array(arguments.dropFirst()))
            default:
                printUsage()
                exit(1)
            }
        } catch {
            writeStandardError("error: \(error)\n")
            exit(2)
        }
    }

    private static func writeStandardError(_ message: String) {
        let data = Data(message.utf8)
        try? FileHandle.standardError.write(contentsOf: data)
    }

    private static func runBootstrap(arguments: [String]) async throws {
        guard let subcommand = arguments.first else {
            throw CLIError.invalidArguments("Expected: bootstrap join|plan")
        }

        let flags = try parseFlags(Array(arguments.dropFirst()))
        let domain = try requiredFlag("domain", flags)
        let environment = ProcessInfo.processInfo.environment
        let runtime = try parseBootstrapRuntime(flags["runtime"] ?? environment["SPROUT_BOOTSTRAP_RUNTIME"])
        let purposeGoal = parseBootstrapPurposeGoal(flags)
        let nowDate = try parseNow(flags["now"])
        let requestedPortholeKind = try parsePortholeKind(flags["porthole"] ?? "cli")
        let starterSource = try resolveStarterAuthSource(flags: flags, environment: environment, domain: domain)
        let plan = try makeBootstrapPlan(
            flags: flags,
            environment: environment,
            runtime: runtime,
            purposeGoal: purposeGoal,
            requestedPortholeKind: requestedPortholeKind,
            starterSource: starterSource
        )

        if subcommand == "plan" || flags["plan-only"] == "true" {
            try emitJSON(
                BootstrapPlanOutput(
                    domain: domain,
                    runtime: runtime.rawValue,
                    starter_source: starterSource,
                    bootstrap_plan: plan
                ),
                outPath: flags["out"] ?? flags["plan-out"]
            )
            return
        }

        guard subcommand == "join" else {
            throw CLIError.invalidArguments("Expected: bootstrap join|plan")
        }

        guard plan.readyForFirstConnection else {
            let output = BootstrapCommandOutput(
                final_state: SproutBootstrapState.error.rawValue,
                event_count: 0,
                resolver_mode: try resolverMode(flags: flags).rawValue,
                requested_porthole_kind: requestedPortholeKind.rawValue,
                starter_source: starterSource,
                bootstrap_plan: plan,
                entity_resolution_status: nil,
                resolved_entity_id: nil,
                entity_inclusion_proof_id: nil,
                scaffold_admin_public_key: nil,
                porthole_contract_id: nil,
                porthole_protocol: nil,
                declared_deposit_rau: nil,
                pricing_outcome: nil,
                error: "bootstrap plan is blocked"
            )
            print(String(data: try JSONEncoder.pretty.encode(output), encoding: .utf8) ?? "{}")
            exit(2)
        }

        guard let starterSource else {
            throw CLIError.invalidArguments("No starter auth payload could be located.")
        }
        guard let purposeGoal else {
            throw CLIError.invalidArguments("Purpose, goal, and interests must be set explicitly.")
        }

        let starterData = try Data(contentsOf: starterSource.url)
        let starterPayload = try JSONDecoder().decode(StarterAuthPayload.self, from: starterData)
        let entityLinkContract = try flags["entity-link"].map { path in
            try EntityLinkContractIO.load(from: URL(fileURLWithPath: path))
        }
        let entityAnchorSnapshot = try flags["entity-anchor"].map { path in
            try JSONDecoder().decode(EntityAnchorSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        let pricingContract = try flags["pricing-contract"].map { path in
            try JSONDecoder().decode(CloudBridgePricingContract.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        let declaredDepositRAU = try flags["deposit-rau"].map { value in
            try parseInt64(value, name: "deposit-rau")
        }

        let auditPath = flags["audit"] ?? ".sprout/audit.log"
        let auditLog = AuditLogStore(fileURL: URL(fileURLWithPath: auditPath))

        let bridgeManager = BridgeManager()
        let catalogPath = flags["catalog"]
        let discoveryService = try makeBridgeDiscoveryService(flags: flags, domain: domain)

        let resolver = try makeResolver(
            flags: flags,
            domain: domain,
            starterPayload: starterPayload,
            entityLinkContract: entityLinkContract,
            entityAnchorSnapshot: entityAnchorSnapshot,
            nowDate: nowDate
        )

        let dependencies = SproutBootstrapDependencies(
            identityProvider: { context in
                guard let payload = context.starterAuthPayload else {
                    throw BootstrapError.invalidContext("starter payload missing")
                }
                return BootstrapIdentity(
                    domain: payload.domain,
                    identity_public_key: payload.identity_public_key
                )
            },
            entityEvidenceProvider: { _ in
                guard let entityLinkContract else {
                    return nil
                }
                return EntityLinkEvidence(
                    evidence_kind: .mutualLinkContract,
                    contract: entityLinkContract,
                    note: "loaded from CLI --entity-link"
                )
            },
            environmentProbe: { _ in
                BootstrapEnvironmentReport(
                    discovery_modes: [catalogPath == nil ? "remote-http-discovery" : "offline-catalog"],
                    available_transports: ["https", "wss"]
                )
            },
            bridgeDiscovery: { context in
                if let catalogPath {
                    let descriptors = try bridgeManager.loadCatalog(from: URL(fileURLWithPath: catalogPath))
                    return descriptors.filter { $0.scaffold_domain == context.domain }
                }
                guard let purposeGoal = context.purposeGoal, purposeGoal.isExplicitlySet else {
                    throw BootstrapError.networkCallWithoutPurposeGoal
                }
                let descriptors = try await discoveryService.queryBridges(
                    BridgeDiscoveryQuery(
                        scaffold_domain: context.domain,
                        purpose: purposeGoal.purpose,
                        interests: purposeGoal.interests
                    )
                )
                return descriptors
            },
            scaffoldAdminIdentityProvider: { descriptor, _ in
                ScaffoldAdminIdentity(
                    scaffold_domain: descriptor.scaffold_domain,
                    admin_public_key: descriptor.owner_pubkey,
                    source_descriptor_id: descriptor.descriptor_id,
                    trust_origin: "bridge_descriptor_signature"
                )
            },
            bridgeConnector: { descriptor, _ in
                guard URL(string: descriptor.bridge_endpoint) != nil else {
                    throw BootstrapError.missingBridgeRoute
                }
            },
            resolver: resolver,
            persistence: { context in
                let outputPath = flags["state-out"] ?? ".sprout/bootstrap_state.json"
                let outputURL = URL(fileURLWithPath: outputPath)
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder.pretty.encode(context)
                try data.write(to: outputURL, options: [.atomic])
            }
        )

        let stateMachine = SproutBootstrapStateMachine(
            dependencies: dependencies,
            bridgeManager: bridgeManager,
            auditLog: auditLog,
            now: { nowDate }
        )

        let context = BootstrapExecutionContext(
            runtime: runtime,
            domain: domain,
            requestedPortholeKind: requestedPortholeKind,
            purposeGoal: purposeGoal,
            starterAuthPayload: starterPayload,
            economics: BootstrapEconomicsContext(
                declared_deposit_rau: declaredDepositRAU,
                pricing_contract: pricingContract
            )
        )

        let result = await stateMachine.run(initialContext: context)
        let output = BootstrapCommandOutput(
            final_state: result.finalState.rawValue,
            event_count: result.events.count,
            resolver_mode: try resolverMode(flags: flags).rawValue,
            requested_porthole_kind: requestedPortholeKind.rawValue,
            starter_source: starterSource,
            bootstrap_plan: plan,
            entity_resolution_status: result.context.entityResolution?.status.rawValue,
            resolved_entity_id: result.context.entityResolution?.entity_id,
            entity_inclusion_proof_id: result.context.entityResolution?.inclusion_proof?.proof_id,
            scaffold_admin_public_key: result.context.scaffoldAdminIdentity?.admin_public_key,
            porthole_contract_id: result.context.portholeAccessContract?.contract_id,
            porthole_protocol: result.context.portholeAccessContract?.porthole_protocol.rawValue,
            declared_deposit_rau: result.context.portholeAccessContract?.declared_deposit_rau,
            pricing_outcome: result.context.portholeAccessContract?.pricing_plan?.outcome.rawValue,
            error: result.error.map { String(describing: $0) }
        )

        print(String(data: try JSONEncoder.pretty.encode(output), encoding: .utf8) ?? "{}")
        if result.finalState != SproutBootstrapState.done {
            exit(2)
        }
    }

    private static func runBridges(arguments: [String]) throws {
        guard arguments.first == "list" else {
            throw CLIError.invalidArguments("Expected: bridges list")
        }
        let flags = try parseFlags(Array(arguments.dropFirst()))
        let catalog = try requiredFlag("catalog", flags)

        let manager = BridgeManager()
        let descriptors = try manager.loadCatalog(from: URL(fileURLWithPath: catalog))

        for descriptor in descriptors {
            print("\(descriptor.descriptor_id) \(descriptor.bridge_endpoint) domain=\(descriptor.scaffold_domain) expires=\(descriptor.expires_at)")
        }
    }

    private static func runFederation(arguments: [String]) async throws {
        guard let subcommand = arguments.first else {
            throw CLIError.invalidArguments("Expected: federation init|show|list")
        }
        let flags = try parseFlags(Array(arguments.dropFirst()))
        let storeRoot = URL(fileURLWithPath: flags["root"] ?? ".sprout/federation-contacts")
        let store = FederationContactIdentityStore(root: storeRoot)

        switch subcommand {
        case "init":
            let record = try await store.initialize(
                remoteDomain: try requiredFlag("remote-domain", flags),
                localScaffoldDomain: flags["local-domain"],
                note: flags["note"],
                overwrite: flags["overwrite"] == "true"
            )
            try emitJSON(record, outPath: flags["out"])
        case "show":
            let record = try await store.load(remoteDomain: try requiredFlag("remote-domain", flags))
            try emitJSON(record, outPath: flags["out"])
        case "list":
            let records = try await store.list()
            try emitJSON(records, outPath: flags["out"])
        default:
            throw CLIError.invalidArguments("Expected: federation init|show|list")
        }
    }

    private static func runLink(arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw CLIError.invalidArguments("Expected: link export|import")
        }
        let flags = try parseFlags(Array(arguments.dropFirst()))
        let file = try requiredFlag("file", flags)

        switch subcommand {
        case "export":
            let contract = try EntityLinkContractIO.load(from: URL(fileURLWithPath: file))
            let outPath = flags["out"] ?? ".sprout/entity_link_canonical.json"
            try EntityLinkContractIO.saveCanonical(contract, to: URL(fileURLWithPath: outPath))
            print("exported canonical entity-link payload to \(outPath)")
        case "import":
            let contract = try EntityLinkContractIO.load(from: URL(fileURLWithPath: file))
            let valid = try contract.verifyMutualSignatures()
            print(valid ? "entity-link valid" : "entity-link invalid")
            if !valid {
                exit(2)
            }
        default:
            throw CLIError.invalidArguments("Expected: link export|import")
        }
    }

    private static func runPorthole(arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw CLIError.invalidArguments("Expected: porthole web-bootstrap|native-spec")
        }
        let flags = try parseFlags(Array(arguments.dropFirst()))
        let contractPath = try requiredFlag("contract", flags)
        let contract = try JSONDecoder().decode(
            PortholeAccessContract.self,
            from: Data(contentsOf: URL(fileURLWithPath: contractPath))
        )
        let nowDate = try parseNow(flags["now"])

        switch subcommand {
        case "web-bootstrap":
            let descriptor = try PortholeContractConsumer.makeWebBootstrap(contract: contract, now: nowDate)
            try emitJSON(descriptor, outPath: flags["out"])
        case "native-spec":
            let descriptor = try PortholeContractConsumer.makeNativeBindingDescriptor(contract: contract, now: nowDate)
            try emitJSON(descriptor, outPath: flags["out"])
        default:
            throw CLIError.invalidArguments("Expected: porthole web-bootstrap|native-spec")
        }
    }

    private static func runVerify(arguments: [String]) throws {
        guard let file = arguments.first else {
            throw CLIError.invalidArguments("Expected: verify <file>")
        }
        let flags = try parseFlags(Array(arguments.dropFirst()))
        let nowDate = try parseNow(flags["now"])

        let url = URL(fileURLWithPath: file)
        let data = try Data(contentsOf: url)

        if let starter = try? JSONDecoder().decode(StarterAuthPayload.self, from: data) {
            let valid = try starter.verifySignature() && !starter.isExpired(now: nowDate)
            print(valid ? "StarterAuthPayload valid" : "StarterAuthPayload invalid (signature or expiry)")
            exit(valid ? 0 : 2)
        }

        if let bridge = try? JSONDecoder().decode(BridgeDescriptor.self, from: data) {
            let context = BridgeDescriptorValidationContext(
                expectedDomain: bridge.scaffold_domain,
                requiredPurpose: bridge.purpose_constraints.first ?? "",
                now: nowDate
            )
            do {
                try BridgeDescriptorValidator().validate(descriptor: bridge, context: context)
                print("BridgeDescriptor valid")
                exit(0)
            } catch {
                print("BridgeDescriptor invalid: \(error)")
                exit(2)
            }
        }

        if let contract = try? JSONDecoder().decode(EntityLinkContract.self, from: data) {
            let valid = try contract.verifyMutualSignatures()
            print(valid ? "EntityLinkContract valid" : "EntityLinkContract invalid")
            exit(valid ? 0 : 2)
        }

        if let snapshot = try? JSONDecoder().decode(EntityAnchorSnapshot.self, from: data) {
            let valid = try snapshot.verifySignature() && !snapshot.isExpired(now: nowDate)
            print(valid ? "EntityAnchorSnapshot valid" : "EntityAnchorSnapshot invalid (signature or expiry)")
            exit(valid ? 0 : 2)
        }

        if let proof = try? JSONDecoder().decode(EntityInclusionProof.self, from: data) {
            let valid = try proof.verifySignature() && !proof.isExpired(now: nowDate)
            print(valid ? "EntityInclusionProof valid" : "EntityInclusionProof invalid (signature or expiry)")
            exit(valid ? 0 : 2)
        }

        if let contract = try? JSONDecoder().decode(PortholeAccessContract.self, from: data) {
            let valid = try contract.verifySignature() && !contract.isExpired(now: nowDate)
            print(valid ? "PortholeAccessContract valid" : "PortholeAccessContract invalid (signature or expiry)")
            exit(valid ? 0 : 2)
        }

        if let _ = try? JSONDecoder().decode(CloudBridgePricingContract.self, from: data) {
            print("CloudBridgePricingContract parsed")
            exit(0)
        }

        if let _ = try? JSONDecoder().decode(UpdateGrantPolicy.self, from: data) {
            print("UpdateGrantPolicy parsed")
            exit(0)
        }

        throw CLIError.invalidArguments("Unsupported file type")
    }

    private static func runUpdate(arguments: [String]) throws {
        let flags = try parseFlags(arguments)
        let policyPath = try requiredFlag("policy", flags)

        let data = try Data(contentsOf: URL(fileURLWithPath: policyPath))
        let policy = try JSONDecoder().decode(UpdateGrantPolicy.self, from: data)

        let request = UpdateRequest(
            artifact_name: try requiredFlag("artifact", flags),
            artifact_sha256_b64url: try requiredFlag("hash", flags),
            artifact_semver: try requiredFlag("version", flags),
            channel: try requiredFlag("channel", flags),
            trigger_identity: try requiredFlag("trigger", flags),
            is_automatic: (flags["auto"] == "true")
        )

        let decision = UpdatePolicyEnforcer.evaluate(request: request, policy: policy)
        switch decision {
        case .allow:
            print("update allowed by policy. Use sprout-updater for installation.")
            exit(0)
        case let .deny(reason):
            print("update denied: \(reason)")
            exit(2)
        }
    }

    private static func runEconomics(arguments: [String]) async throws {
        guard let subcommand = arguments.first else {
            throw CLIError.invalidArguments("Expected: economics units|compile-contract|stripe-sim|rollup|suggest-rate")
        }
        let flags = try parseFlags(Array(arguments.dropFirst()))

        switch subcommand {
        case "units":
            let amount: RAUAmount
            if let rau = flags["rau"] {
                amount = RAUAmount(try parseInt64(rau, name: "rau"))
            } else if let imu = flags["imu"] {
                amount = .fromIMU(try parseInt64(imu, name: "imu"))
            } else if let ore = flags["ore"] {
                amount = .fromOre(try parseInt64(ore, name: "ore"))
            } else if let nok = flags["nok"] {
                amount = .fromNOK(try parseInt64(nok, name: "nok"))
            } else {
                throw CLIError.invalidArguments("economics units requires --rau, --imu, --ore or --nok")
            }
            try emitJSON(UnitConversionOutput(rau: amount.rawValue, imu: amount.imuView, ore: amount.oreView, nok: amount.nokView), outPath: flags["out"])
        case "compile-contract":
            let contractPath = try requiredFlag("contract", flags)
            let contract = try JSONDecoder.economics.decode(
                CloudBridgePricingContract.self,
                from: Data(contentsOf: URL(fileURLWithPath: contractPath))
            )
            let depositRAU = try parseInt64(flags["deposit-rau"] ?? "0", name: "deposit-rau")
            let requestedCapabilities = parseSetFlag(flags["requested-capabilities"])
            let compiled = CloudBridgePricingCompiler.compile(contract: contract, declaredDepositRAU: depositRAU, requestedCapabilities: requestedCapabilities)
            try emitJSON(compiled, outPath: flags["out"])
            if compiled.outcome == .deny {
                exit(2)
            }
        case "stripe-sim":
            let topUps = parseSetFlag(flags["topups-nok"] ?? "20,50,100,300").compactMap { Int64($0) }
            let dailySpendNOK = try parseInt64(flags["daily-spend-nok"] ?? "5", name: "daily-spend-nok")
            let results = StripeTopUpSimulator.simulate(topUpNOK: topUps, dailySpendOre: dailySpendNOK * 100)
            try emitJSON(results, outPath: flags["out"])
        case "rollup":
            let usagePath = try requiredFlag("usage", flags)
            let deltas = try JSONDecoder.economics.decode(
                [CloudBridgeUsageDelta].self,
                from: Data(contentsOf: URL(fileURLWithPath: usagePath))
            )
            let pricingContract = try flags["contract"].map { path in
                try JSONDecoder.economics.decode(
                    CloudBridgePricingContract.self,
                    from: Data(contentsOf: URL(fileURLWithPath: path))
                )
            }
            let aggregator = CloudBridgeRollupAggregator(pricingContract: pricingContract)
            var entries: [CloudBridgeLedgerEntry] = []
            for delta in deltas {
                entries.append(contentsOf: await aggregator.record(delta))
            }
            entries.append(contentsOf: await aggregator.close())
            try emitJSON(entries, outPath: flags["out"])
        case "suggest-rate":
            let recordsPath = try requiredFlag("records", flags)
            let records = try JSONDecoder.economics.decode(
                [CloudBridgeSessionRecord].self,
                from: Data(contentsOf: URL(fileURLWithPath: recordsPath))
            )
            let calibration = SessionRateCalibration(
                rau_per_thread_minute: try parseInt64(flags["rau-per-thread-minute"] ?? "100000", name: "rau-per-thread-minute"),
                rau_per_gib_minute: try parseInt64(flags["rau-per-gib-minute"] ?? "1000000", name: "rau-per-gib-minute"),
                rau_per_cpu_second: try parseInt64(flags["rau-per-cpu-second"] ?? "50000", name: "rau-per-cpu-second"),
                rau_per_message: try parseInt64(flags["rau-per-message"] ?? "1000", name: "rau-per-message"),
                rau_per_audit_event: try parseInt64(flags["rau-per-audit-event"] ?? "2000", name: "rau-per-audit-event"),
                target_margin_bps: try parseInt64(flags["target-margin-bps"] ?? "2500", name: "target-margin-bps")
            )
            let suggestion = SessionRateEstimator.suggest(records: records, calibration: calibration)
            try emitJSON(suggestion, outPath: flags["out"])
        default:
            throw CLIError.invalidArguments("Expected: economics units|compile-contract|stripe-sim|rollup|suggest-rate")
        }
    }

    private static func makeResolver(
        flags: [String: String],
        domain: String,
        starterPayload: StarterAuthPayload,
        entityLinkContract: EntityLinkContract?,
        entityAnchorSnapshot: EntityAnchorSnapshot?,
        nowDate: Date
    ) throws -> any SproutResolverAdapter {
        let mode = try resolverMode(flags: flags)
        if mode == .liveHTTP {
            let environment = ProcessInfo.processInfo.environment
            let resolverBaseURL = try requiredResolverBaseURL(flags: flags, environment: environment)
            let trustedResolverKeys = parseSetFlag(
                flags["trusted-resolver-key"] ?? environment["SPROUT_RESOLVER_TRUSTED_KEYS"]
            )
            let bearerToken = flags["resolver-bearer"] ?? environment["SPROUT_RESOLVER_BEARER_TOKEN"]
            let pathPrefix = flags["resolver-path-prefix"] ?? environment["SPROUT_RESOLVER_PATH_PREFIX"] ?? "/v1/resolver"

            return try HavenResolverHTTPAdapter(
                configuration: HavenResolverHTTPAdapterConfiguration(
                    baseURL: resolverBaseURL,
                    pathPrefix: pathPrefix,
                    bearerToken: bearerToken,
                    allowInsecureHTTP: flags["allow-insecure-resolver-http"] == "true",
                    trustedResolverPublicKeys: Set(trustedResolverKeys)
                ),
                now: { nowDate }
            )
        }

        if let entityAnchorSnapshot {
            return EntityAnchorResolverAdapter(
                anchorSnapshot: entityAnchorSnapshot,
                scenario: EntityAnchorResolverScenario(
                    allowedDomains: [domain],
                    deniedCapabilities: Set(flags["deny-capability"]?.split(separator: ",").map(String.init) ?? []),
                    requireFreshPayload: false
                ),
                now: { nowDate }
            )
        }

        var entityBindings = [String: String]()
        if let resolvedEntity = flags["resolved-entity"] {
            entityBindings[starterPayload.identity_public_key] = resolvedEntity
            if let entityLinkContract {
                entityBindings[entityLinkContract.pubkey_a] = resolvedEntity
                entityBindings[entityLinkContract.pubkey_b] = resolvedEntity
            }
        }

        return MockResolverAdapter(
            scenario: MockResolverScenario(
                allowedDomains: [domain],
                deniedCapabilities: Set(flags["deny-capability"]?.split(separator: ",").map(String.init) ?? []),
                entityBindings: entityBindings,
                requireFreshPayload: false
            ),
            now: { nowDate }
        )
    }

    private static func makeBridgeDiscoveryService(
        flags: [String: String],
        domain: String
    ) throws -> any BridgeDiscoveryService {
        let environment = ProcessInfo.processInfo.environment
        let endpoint = try resolveDiscoveryEndpoint(flags: flags, environment: environment, domain: domain)
        return BridgeDiscoveryHTTPClient(endpoint: endpoint)
    }

    private static func resolverMode(flags: [String: String]) throws -> ResolverMode {
        let environment = ProcessInfo.processInfo.environment
        let liveFlag = flags["enable-live-resolver"] == "true" || environment["SPROUT_ENABLE_LIVE_RESOLVER"] == "1"
        let hasResolverBaseURL = flags["resolver-base-url"] != nil || environment["SPROUT_RESOLVER_BASE_URL"] != nil

        if liveFlag {
            guard hasResolverBaseURL else {
                throw CLIError.invalidArguments("Live resolver requires --resolver-base-url or SPROUT_RESOLVER_BASE_URL.")
            }
            return .liveHTTP
        }
        if hasResolverBaseURL {
            throw CLIError.invalidArguments("Resolver base URL requires --enable-live-resolver or SPROUT_ENABLE_LIVE_RESOLVER=1.")
        }
        if flags["entity-anchor"] != nil {
            return .entityAnchorSnapshot
        }
        return .mock
    }

    private static func requiredResolverBaseURL(flags: [String: String], environment: [String: String]) throws -> URL {
        let raw = flags["resolver-base-url"] ?? environment["SPROUT_RESOLVER_BASE_URL"] ?? ""
        guard let url = URL(string: raw), !raw.isEmpty else {
            throw CLIError.invalidArguments("Invalid resolver base URL.")
        }
        return url
    }

    private static func resolveDiscoveryEndpoint(
        flags: [String: String],
        environment: [String: String],
        domain: String
    ) throws -> URL {
        if let raw = flags["discovery-url"] ?? environment["SPROUT_DISCOVERY_URL"], !raw.isEmpty {
            guard let url = URL(string: raw) else {
                throw CLIError.invalidArguments("Invalid discovery URL.")
            }
            return url
        }

        if let resolverRaw = flags["resolver-base-url"] ?? environment["SPROUT_RESOLVER_BASE_URL"],
           let resolverURL = URL(string: resolverRaw),
           let scheme = resolverURL.scheme,
           let host = resolverURL.host {
            var components = URLComponents()
            components.scheme = scheme
            components.host = host
            components.port = resolverURL.port
            components.path = "/v1/bridges/query"
            guard let url = components.url else {
                throw CLIError.invalidArguments("Invalid discovery URL derived from resolver base URL.")
            }
            return url
        }

        guard let url = URL(string: "https://\(domain)/v1/bridges/query") else {
            throw CLIError.invalidArguments("Invalid discovery URL derived from scaffold domain.")
        }
        return url
    }

    private static func parseBootstrapRuntime(_ rawValue: String?) throws -> SproutRuntimeProfile {
        guard let rawValue, !rawValue.isEmpty else {
            return .cliService
        }

        switch rawValue {
        case "cliService", "cli-service":
            return .cliService
        case "onPremService", "on-prem-service":
            return .onPremService
        case "macOSApp", "macos-app":
            return .macOSApp
        case "iOSApp", "ios-app":
            return .iOSApp
        default:
            throw CLIError.invalidArguments("Invalid --runtime value. Expected cli-service|on-prem-service|macos-app|ios-app.")
        }
    }

    private static func parseBootstrapPurposeGoal(_ flags: [String: String]) -> BootstrapPurposeGoal? {
        let purpose = flags["purpose"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let goal = flags["goal"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let interests = parseSetFlag(flags["interests"])

        guard !purpose.isEmpty || !goal.isEmpty || !interests.isEmpty else {
            return nil
        }

        return BootstrapPurposeGoal(purpose: purpose, goal: goal, interests: interests)
    }

    private static func resolveStarterAuthSource(
        flags: [String: String],
        environment: [String: String],
        domain: String
    ) throws -> StarterAuthSource? {
        if let path = flags["starter"], !path.isEmpty {
            return try validateStarterAuthSource(path: path, origin: "flag")
        }

        if let path = environment["SPROUT_STARTER_AUTH_PATH"], !path.isEmpty {
            return try validateStarterAuthSource(path: path, origin: "environment")
        }

        let candidates = [
            StarterAuthSource(origin: "domain-cache", path: ".sprout/starters/\(domain).json"),
            StarterAuthSource(origin: "default-cache", path: ".sprout/starter_auth_payload.json")
        ]

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private static func validateStarterAuthSource(path: String, origin: String) throws -> StarterAuthSource {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError.invalidArguments("Starter auth payload not found at \(path).")
        }
        return StarterAuthSource(origin: origin, path: path)
    }

    private static func makeBootstrapPlan(
        flags: [String: String],
        environment: [String: String],
        runtime: SproutRuntimeProfile,
        purposeGoal: BootstrapPurposeGoal?,
        requestedPortholeKind: PortholeClientKind,
        starterSource: StarterAuthSource?
    ) throws -> BootstrapPlan {
        var capabilities: Set<BootstrapPlanningCapability> = [
            .remoteHostRouting,
            .portholeAttachment,
            .signedBridgeDiscoveryHTTP
        ]

        if starterSource != nil {
            capabilities.insert(.localStarterAuthPayload)
        }
        if flags["catalog"] != nil {
            capabilities.insert(.offlineBridgeCatalog)
        }

        switch try resolverMode(flags: flags) {
        case .liveHTTP:
            capabilities.insert(.liveResolverHTTP)
        case .entityAnchorSnapshot:
            capabilities.insert(.entityAnchorSnapshot)
        case .mock:
            if flags["resolved-entity"] != nil {
                capabilities.insert(.mockResolver)
            }
        }

        let discoveryPreference: BridgeDiscoveryPreference = if flags["catalog"] != nil {
            .offlineCatalog
        } else {
            .auto
        }

        let entityResolutionPreference: EntityResolutionPreference = switch try resolverMode(flags: flags) {
        case .liveHTTP:
            .liveHTTP
        case .entityAnchorSnapshot:
            .entityAnchorSnapshot
        case .mock:
            .mock
        }

        let planner = BootstrapPlanner()
        return planner.plan(
            environment: BootstrapPlanningEnvironment(
                runtime: runtime,
                availableCapabilities: capabilities
            ),
            request: BootstrapPlanningRequest(
                purposeGoal: purposeGoal,
                requestedPortholeKind: requestedPortholeKind,
                discoveryPreference: discoveryPreference,
                entityResolutionPreference: entityResolutionPreference
            )
        )
    }

    private static func parseSetFlag(_ rawValue: String?) -> [String] {
        guard let rawValue, !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func parseFlags(_ arguments: [String]) throws -> [String: String] {
        var flags = [String: String]()
        var index = 0
        while index < arguments.count {
            let current = arguments[index]
            if current.hasPrefix("--") {
                let key = String(current.dropFirst(2))
                let nextIndex = index + 1
                if nextIndex < arguments.count, !arguments[nextIndex].hasPrefix("--") {
                    flags[key] = arguments[nextIndex]
                    index += 2
                } else {
                    flags[key] = "true"
                    index += 1
                }
            } else {
                throw CLIError.invalidArguments("Unexpected argument: \(current)")
            }
        }
        return flags
    }

    private static func requiredFlag(_ name: String, _ flags: [String: String]) throws -> String {
        guard let value = flags[name], !value.isEmpty else {
            throw CLIError.invalidArguments("Missing --\(name)")
        }
        return value
    }

    private static func parsePortholeKind(_ value: String) throws -> PortholeClientKind {
        guard let kind = PortholeClientKind(rawValue: value) else {
            throw CLIError.invalidArguments("Invalid --porthole value. Expected web|cli|native.")
        }
        return kind
    }

    private static func parseInt64(_ value: String, name: String) throws -> Int64 {
        guard let parsed = Int64(value) else {
            throw CLIError.invalidArguments("Invalid --\(name) value. Expected int64.")
        }
        return parsed
    }

    private static func emitJSON<T: Encodable>(_ value: T, outPath: String?) throws {
        let data = try JSONEncoder.pretty.encode(value)
        if let outPath {
            let outURL = URL(fileURLWithPath: outPath)
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outURL, options: [.atomic])
        } else {
            print(String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    private static func printUsage() {
        let text = """
        sprout commands:
          sprout bootstrap plan --domain <d> [--purpose <p>] [--goal <g>] [--interests <i1,i2>] [--runtime <cli-service|on-prem-service|macos-app|ios-app>] [--starter <file>] [--catalog <file>] [--enable-live-resolver --resolver-base-url <https://resolver.example>] [--entity-anchor <file>] [--resolved-entity <entity-id>] [--porthole <web|cli|native>] [--out <json>]
          sprout bootstrap join --domain <d> [--purpose <p>] [--goal <g>] [--interests <i1,i2>] [--runtime <cli-service|on-prem-service|macos-app|ios-app>] [--starter <file>] [--catalog <file>] [--discovery-url <https://domain/v1/bridges/query>] [--entity-link <file>] [--entity-anchor <file>] [--enable-live-resolver --resolver-base-url <https://resolver.example>] [--trusted-resolver-key <pubkey1,pubkey2>] [--resolver-bearer <token>] [--resolved-entity <entity-id>] [--porthole <web|cli|native>] [--audit <file>] [--state-out <file>] [--plan-only] [--plan-out <json>] [--now <ISO8601>]
          sprout bridges list --catalog <file>
          sprout federation init --remote-domain <domain> [--local-domain <domain>] [--note <text>] [--root <dir>] [--overwrite] [--out <json>]
          sprout federation show --remote-domain <domain> [--root <dir>] [--out <json>]
          sprout federation list [--root <dir>] [--out <json>]
          sprout link export --file <entity-link.json> [--out <canonical.json>]
          sprout link import --file <entity-link.json>
          sprout porthole web-bootstrap --contract <porthole-access-contract.json> [--out <descriptor.json>] [--now <ISO8601>]
          sprout porthole native-spec --contract <porthole-access-contract.json> [--out <descriptor.json>] [--now <ISO8601>]
          sprout verify <file> [--now <ISO8601>]
          sprout economics units --rau <int64>|--imu <int64>|--ore <int64>|--nok <int64> [--out <json>]
          sprout economics compile-contract --contract <pricing-contract.json> [--deposit-rau <int64>] [--requested-capabilities <cap1,cap2>] [--out <json>]
          sprout economics stripe-sim [--topups-nok <20,50,100,300>] [--daily-spend-nok <int64>] [--out <json>]
          sprout economics rollup --usage <usage-deltas.json> [--contract <pricing-contract.json>] [--out <json>]
          sprout economics suggest-rate --records <session-records.json> [--rau-per-thread-minute <int64>] [--rau-per-gib-minute <int64>] [--rau-per-cpu-second <int64>] [--rau-per-message <int64>] [--rau-per-audit-event <int64>] [--target-margin-bps <int64>] [--out <json>]
          sprout update --policy <policy.json> --artifact <name> --hash <sha256_b64url> --version <semver> --channel <stable|beta> --trigger <pubkey-or-contract> [--auto]

        starter auth lookup order for bootstrap:
          1. --starter <file>
          2. SPROUT_STARTER_AUTH_PATH
          3. .sprout/starters/<domain>.json
          4. .sprout/starter_auth_payload.json
        """
        print(text)
    }

    private static func parseNow(_ value: String?) throws -> Date {
        guard let value else { return Date() }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else {
            throw CLIError.invalidArguments("Invalid --now value. Expected ISO8601 date-time.")
        }
        return date
    }
}

private struct BootstrapCommandOutput: Codable {
    var final_state: String
    var event_count: Int
    var resolver_mode: String
    var requested_porthole_kind: String
    var starter_source: StarterAuthSource?
    var bootstrap_plan: BootstrapPlan?
    var entity_resolution_status: String?
    var resolved_entity_id: String?
    var entity_inclusion_proof_id: String?
    var scaffold_admin_public_key: String?
    var porthole_contract_id: String?
    var porthole_protocol: String?
    var declared_deposit_rau: Int64?
    var pricing_outcome: String?
    var error: String?
}

private struct UnitConversionOutput: Codable {
    var rau: Int64
    var imu: Decimal
    var ore: Decimal
    var nok: Decimal
}

private struct BootstrapPlanOutput: Codable {
    var domain: String
    var runtime: String
    var starter_source: StarterAuthSource?
    var bootstrap_plan: BootstrapPlan
}

private struct StarterAuthSource: Codable {
    var origin: String
    var path: String

    var url: URL {
        URL(fileURLWithPath: path)
    }
}

private enum CLIError: Error {
    case invalidArguments(String)
}

private enum ResolverMode: String {
    case mock
    case entityAnchorSnapshot = "entity-anchor-snapshot"
    case liveHTTP = "live-http"
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
