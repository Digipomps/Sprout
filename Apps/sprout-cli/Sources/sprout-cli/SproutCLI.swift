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
        do {
            guard !arguments.isEmpty else {
                try await runOnboarding(arguments: [])
                return
            }
            switch arguments[0] {
            case "entity":
                guard arguments.dropFirst().first == "connect" else {
                    throw CLIError.invalidArguments("Expected: entity connect [--place app|haven|staging]")
                }
                try PersonEntityCommands.connect(Array(arguments.dropFirst(2)))
            case "nearby":
                try PersonEntityCommands.nearby(Array(arguments.dropFirst()))
            case "doctor":
                guard arguments.count == 1 || arguments == ["doctor", "--json"] else {
                    throw CLIError.invalidArguments("Expected: doctor [--json]")
                }
                let report = try SproutDoctor.inspect()
                if arguments.count == 2 {
                    print(String(decoding: try JSONEncoder.pretty.encode(report), as: UTF8.self))
                } else {
                    print("Sprout: \(report.platform)/\(report.architecture), \(report.cRuntime). Crypto self-test: \(report.cryptography).")
                    print("No network contact or stored identities inspected. Channel readiness is not verified.")
                }
            case "onboard", "chat":
                try await runOnboarding(arguments: Array(arguments.dropFirst()))
            case "--help", "-h", "help":
                printUsage()
            case "bootstrap":
                try await runBootstrap(arguments: Array(arguments.dropFirst()))
            case "bridges":
                try runBridges(arguments: Array(arguments.dropFirst()))
            case "owner":
                try await runOwner(arguments: Array(arguments.dropFirst()))
            case "software":
                try await runSoftware(arguments: Array(arguments.dropFirst()))
            case "federation":
                try await runFederation(arguments: Array(arguments.dropFirst()))
            case "admission":
                try await runAdmission(arguments: Array(arguments.dropFirst()))
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
        let requestedCapabilities = parseSetFlag(flags["requested-capabilities"])
        let wantsPlanOutput = subcommand == "plan" || flags["plan-only"] == "true"
        var trustRootSource = try resolveScaffoldTrustRootSource(flags: flags, environment: environment, domain: domain)
        var trustRootDescriptor: ScaffoldAdminTrustRootDescriptor?

        if subcommand == "join",
           !wantsPlanOutput,
           trustRootSource == nil,
           let purposeGoal,
           purposeGoal.isExplicitlySet {
            trustRootSource = try await materializeScaffoldTrustRootSource(
                flags: flags,
                environment: environment,
                domain: domain,
                nowDate: nowDate
            )
        }

        if let trustRootSource, subcommand == "join", !wantsPlanOutput {
            trustRootDescriptor = try loadScaffoldTrustRootDescriptor(
                source: trustRootSource,
                expectedDomain: domain,
                nowDate: nowDate
            )
        }

        var starterSource = try resolveStarterAuthSource(flags: flags, environment: environment, domain: domain)

        if subcommand == "join",
           !wantsPlanOutput,
           starterSource == nil,
           let purposeGoal,
           purposeGoal.isExplicitlySet {
            starterSource = try await materializeStarterAuthSource(
                flags: flags,
                environment: environment,
                domain: domain,
                runtime: runtime,
                purposeGoal: purposeGoal,
                trustRootDescriptor: trustRootDescriptor
            )
        }

        let plan = try makeBootstrapPlan(
            flags: flags,
            environment: environment,
            runtime: runtime,
            purposeGoal: purposeGoal,
            requestedPortholeKind: requestedPortholeKind,
            starterSource: starterSource,
            trustRootSource: trustRootSource
        )

        if wantsPlanOutput {
            try emitJSON(
                BootstrapPlanOutput(
                    domain: domain,
                    runtime: runtime.rawValue,
                    scaffold_trust_root_source: trustRootSource,
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
                scaffold_trust_root_source: trustRootSource,
                starter_source: starterSource,
                bootstrap_plan: plan,
                entity_resolution_status: nil,
                resolved_entity_id: nil,
                entity_inclusion_proof_id: nil,
                scaffold_trust_root_descriptor_id: trustRootDescriptor?.descriptor_id,
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
        let continuityProof = try flags["continuity-proof"].map { path in
            try JSONDecoder().decode(
                CrossScaffoldEntityContinuityProof.self,
                from: Data(contentsOf: URL(fileURLWithPath: path))
            )
        }
        let entityAdmissionContract = try flags["admission-contract"].map { path in
            try JSONDecoder().decode(
                EntityAdmissionContract.self,
                from: Data(contentsOf: URL(fileURLWithPath: path))
            )
        }
        if continuityProof != nil, entityAdmissionContract == nil {
            throw CLIError.invalidArguments("--continuity-proof requires --admission-contract during bootstrap join.")
        }
        if entityLinkContract != nil, entityAdmissionContract != nil {
            throw CLIError.invalidArguments("Use either --entity-link or --admission-contract, not both.")
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
        let discoveryService = try makeBridgeDiscoveryService(
            flags: flags,
            domain: domain,
            trustRootDescriptor: trustRootDescriptor
        )

        let resolver = try makeResolver(
            flags: flags,
            domain: domain,
            starterPayload: starterPayload,
            entityLinkContract: entityLinkContract,
            entityAnchorSnapshot: entityAnchorSnapshot,
            trustRootDescriptor: trustRootDescriptor,
            nowDate: nowDate
        )
        let resolvedTrustRootDescriptor = trustRootDescriptor

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
            entityAdmissionEvidenceProvider: { _ in
                guard let entityAdmissionContract else {
                    return nil
                }
                return EntityAdmissionEvidence(
                    contract: entityAdmissionContract,
                    continuityProof: continuityProof,
                    note: "loaded from CLI --admission-contract"
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
                if let resolvedTrustRootDescriptor {
                    return ScaffoldAdminIdentity(
                        scaffold_domain: resolvedTrustRootDescriptor.scaffold_domain,
                        admin_public_key: resolvedTrustRootDescriptor.scaffold_admin_public_key,
                        source_descriptor_id: resolvedTrustRootDescriptor.descriptor_id,
                        trust_origin: "scaffold_admin_trust_root_descriptor"
                    )
                }
                return ScaffoldAdminIdentity(
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
            requestedCapabilities: requestedCapabilities,
            purposeGoal: purposeGoal,
            starterAuthPayload: starterPayload,
            economics: BootstrapEconomicsContext(
                declared_deposit_rau: declaredDepositRAU,
                pricing_contract: pricingContract
            ),
            scaffoldTrustRootDescriptor: trustRootDescriptor
        )

        let result = await stateMachine.run(initialContext: context)
        let output = BootstrapCommandOutput(
            final_state: result.finalState.rawValue,
            event_count: result.events.count,
            resolver_mode: try resolverMode(flags: flags).rawValue,
            requested_porthole_kind: requestedPortholeKind.rawValue,
            scaffold_trust_root_source: trustRootSource,
            starter_source: starterSource,
            bootstrap_plan: plan,
            entity_resolution_status: result.context.entityResolution?.status.rawValue,
            resolved_entity_id: result.context.entityResolution?.entity_id,
            entity_inclusion_proof_id: result.context.entityResolution?.inclusion_proof?.proof_id,
            entity_admission_contract_id: result.context.entityAdmissionEvidence?.contract.contract_id,
            continuity_proof_id: result.context.entityAdmissionEvidence?.continuityProof?.proof_id,
            scaffold_trust_root_descriptor_id: result.context.scaffoldTrustRootDescriptor?.descriptor_id,
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

    private static func runOwner(arguments: [String]) async throws {
        guard let subcommand = arguments.first else {
            throw CLIError.invalidArguments("Expected: owner init|show|list|trust-root")
        }
        let flags = try parseFlags(Array(arguments.dropFirst()))
        let storeRoot = URL(fileURLWithPath: flags["root"] ?? ".sprout/scaffold-owners")
        let store = ScaffoldOwnerIdentityStore(root: storeRoot)

        switch subcommand {
        case "init":
            let record = try await store.initialize(
                scaffoldDomain: try requiredFlag("domain", flags),
                displayName: flags["display-name"],
                note: flags["note"],
                overwrite: flags["overwrite"] == "true"
            )
            try emitJSON(record, outPath: flags["out"])
        case "show":
            let record = try await store.load(scaffoldDomain: try requiredFlag("domain", flags))
            try emitJSON(record, outPath: flags["out"])
        case "list":
            let records = try await store.list()
            try emitJSON(records, outPath: flags["out"])
        case "trust-root":
            let descriptor = try await makeOwnerTrustRootDescriptor(flags: flags, store: store)
            try emitJSON(descriptor, outPath: flags["out"] ?? ".sprout/trust-roots/\(descriptor.scaffold_domain).json")
        default:
            throw CLIError.invalidArguments("Expected: owner init|show|list|trust-root")
        }
    }

    private static func makeOwnerTrustRootDescriptor(
        flags: [String: String],
        store: ScaffoldOwnerIdentityStore
    ) async throws -> ScaffoldAdminTrustRootDescriptor {
        let domain = try requiredFlag("domain", flags)
        let owner = try await store.load(scaffoldDomain: domain)
        let ownerSeed = try await store.seedBase64URL(scaffoldDomain: domain)
        let nowDate = try parseNow(flags["now"])
        let issuedAt = try parseOptionalNow(flags["issued-at"]) ?? nowDate
        let expiresAt = try parseOptionalNow(flags["expires-at"]) ?? issuedAt.addingTimeInterval(86_400 * 30)
        guard expiresAt > issuedAt else {
            throw CLIError.invalidArguments("--expires-at must be later than --issued-at.")
        }

        let resolverPublicKeys = parseSetFlag(flags["resolver-public-keys"])
        let bridgeOwnerPublicKeys = parseSetFlag(flags["bridge-owner-public-keys"])
        let resolverBaseURL = try parseURLFlag(flags["resolver-base-url"], name: "resolver-base-url")
            ?? URL(string: "https://\(domain)")!
        let starterBootstrapURL = try parseURLFlag(flags["starter-bootstrap-url"], name: "starter-bootstrap-url")
            ?? resolverBaseURL
                .appendingPathComponent("v1")
                .appendingPathComponent("resolver")
                .appendingPathComponent("starter-auth")
                .appendingPathComponent("intent")
        let bridgeDiscoveryURL = try parseURLFlag(flags["bridge-discovery-url"], name: "bridge-discovery-url")
            ?? resolverBaseURL
                .appendingPathComponent("v1")
                .appendingPathComponent("bridges")
                .appendingPathComponent("query")
        let softwareCatalogURL = try parseURLFlag(flags["software-catalog-url"], name: "software-catalog-url")
            ?? resolverBaseURL
                .appendingPathComponent(".well-known")
                .appendingPathComponent("haven-executable-catalog.json")

        let formatter = ISO8601DateFormatter()
        var descriptor = ScaffoldAdminTrustRootDescriptor(
            version: "1.0",
            descriptor_id: flags["descriptor-id"] ?? "trd_\(domain.replacingOccurrences(of: ".", with: "_"))_\(Int(issuedAt.timeIntervalSince1970))",
            scaffold_domain: owner.scaffold_domain,
            scaffold_admin_public_key: owner.identity_public_key,
            resolver_public_keys: resolverPublicKeys.isEmpty ? [owner.identity_public_key] : resolverPublicKeys,
            bridge_owner_public_keys: bridgeOwnerPublicKeys.isEmpty ? [owner.identity_public_key] : bridgeOwnerPublicKeys,
            starter_bootstrap_url: starterBootstrapURL.absoluteString,
            bridge_discovery_url: bridgeDiscoveryURL.absoluteString,
            resolver_base_url: resolverBaseURL.absoluteString,
            software_catalog_url: softwareCatalogURL.absoluteString,
            issued_at: formatter.string(from: issuedAt),
            expires_at: formatter.string(from: expiresAt),
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )
        descriptor.signature = ResolverSignatureEnvelope(
            alg: "Ed25519",
            sig: try Ed25519.signBase64URL(
                data: try descriptor.canonicalPayloadData(),
                seedBase64URL: ownerSeed
            )
        )
        return descriptor
    }

    private static func runSoftware(arguments: [String]) async throws {
        guard let subcommand = arguments.first else {
            throw CLIError.invalidArguments("Expected: software fetch|verify|select|sign-catalog")
        }
        let flags = try parseFlags(Array(arguments.dropFirst()))
        let nowDate = try parseNow(flags["now"])

        switch subcommand {
        case "fetch":
            let domain = try requiredFlag("domain", flags)
            let trustRoot = try flags["trust-root"].map { path in
                try loadScaffoldTrustRootDescriptor(
                    source: TrustRootSource(origin: "flag", path: path),
                    expectedDomain: domain,
                    nowDate: nowDate
                )
            }
            let endpoint = try resolveExecutableCatalogEndpoint(
                flags: flags,
                domain: domain,
                trustRootDescriptor: trustRoot
            )
            let trustedPublishers = trustedSoftwareCatalogPublisherKeys(
                flags: flags,
                trustRootDescriptor: trustRoot
            )
            let client = ScaffoldExecutableCatalogHTTPClient(endpoint: endpoint, now: { nowDate })
            let catalog = try await client.fetch(
                expectedDomain: domain,
                trustedPublisherPublicKeys: trustedPublishers
            )
            try emitJSON(catalog, outPath: flags["out"] ?? ".sprout/software-catalogs/\(domain).json")
        case "verify":
            _ = try loadAndValidateExecutableCatalog(flags: flags, nowDate: nowDate)
            print("ScaffoldExecutableCatalog valid")
        case "select":
            let catalog = try loadAndValidateExecutableCatalog(flags: flags, nowDate: nowDate)
            let kind = try requiredFlag("kind", flags)
            let platform = try requiredFlag("platform", flags)
            let channel = flags["channel"] ?? "stable"
            guard let artifact = catalog.selectArtifact(
                kind: kind,
                platform: platform,
                channel: channel,
                name: flags["name"]
            ) else {
                throw CLIError.invalidArguments("No matching artifact in executable catalog.")
            }
            try emitJSON(artifact, outPath: flags["out"])
        case "sign-catalog":
            let domain = try requiredFlag("domain", flags)
            let unsignedPath = try requiredFlag("unsigned", flags)
            let storeRoot = URL(fileURLWithPath: flags["root"] ?? ".sprout/scaffold-owners")
            let store = ScaffoldOwnerIdentityStore(root: storeRoot)
            let owner = try await store.load(scaffoldDomain: domain)
            let ownerSeed = try await store.seedBase64URL(scaffoldDomain: domain)
            var catalog = try JSONDecoder().decode(
                ScaffoldExecutableCatalog.self,
                from: Data(contentsOf: URL(fileURLWithPath: unsignedPath))
            )
            guard catalog.scaffold_domain == owner.scaffold_domain else {
                throw CLIError.invalidArguments("Executable catalog scaffold_domain does not match owner domain.")
            }
            catalog.issued_by = owner.identity_public_key
            catalog.signature = ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
            catalog.signature = ResolverSignatureEnvelope(
                alg: "Ed25519",
                sig: try Ed25519.signBase64URL(
                    data: try catalog.canonicalPayloadData(),
                    seedBase64URL: ownerSeed
                )
            )
            try ScaffoldExecutableCatalogValidator().validate(
                catalog: catalog,
                context: ScaffoldExecutableCatalogValidationContext(
                    expectedDomain: owner.scaffold_domain,
                    trustedPublisherPublicKeys: [owner.identity_public_key],
                    now: nowDate
                )
            )
            try emitJSON(catalog, outPath: flags["out"] ?? ".sprout/software-catalogs/\(domain).json")
        default:
            throw CLIError.invalidArguments("Expected: software fetch|verify|select|sign-catalog")
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

    private static func runAdmission(arguments: [String]) async throws {
        guard let subcommand = arguments.first else {
            throw CLIError.invalidArguments("Expected: admission create-request")
        }
        let flags = try parseFlags(Array(arguments.dropFirst()))

        switch subcommand {
        case "create-request":
            let proofPath = try requiredFlag("continuity-proof", flags)
            let proof = try JSONDecoder().decode(
                CrossScaffoldEntityContinuityProof.self,
                from: Data(contentsOf: URL(fileURLWithPath: proofPath))
            )
            let nowDate = try parseNow(flags["now"])
            guard !proof.isExpired(now: nowDate) else {
                throw CLIError.invalidArguments("Cross-scaffold continuity proof is expired.")
            }
            guard try proof.verifySignature() else {
                throw CLIError.invalidArguments("Cross-scaffold continuity proof signature is invalid.")
            }

            let targetDomain = flags["domain"] ?? proof.target_scaffold_domain
            guard targetDomain == proof.target_scaffold_domain else {
                throw CLIError.invalidArguments("Admission request domain does not match continuity proof target scaffold.")
            }

            let createdAt = try parseOptionalNow(flags["created-at"]) ?? nowDate
            let expiresAt = try parseOptionalNow(flags["expires-at"]) ?? createdAt.addingTimeInterval(300)
            guard expiresAt > createdAt else {
                throw CLIError.invalidArguments("--expires-at must be later than --created-at.")
            }

            let identityRoot = URL(fileURLWithPath: flags["starter-identity-root"] ?? ".sprout/starter-identities")
            let identityStore = StarterIdentityStore(root: identityRoot)
            let record = try await identityStore.loadOrCreate(scaffoldDomain: targetDomain)
            let seedBase64URL = try await identityStore.seedBase64URL(scaffoldDomain: targetDomain)
            let continuityHash = try proof.payloadHashBase64URL()
            let requestID = flags["request-id"] ?? "ear_\(Hashing.sha256Base64URL(Data([targetDomain, record.identity_public_key, continuityHash].joined(separator: "|").utf8)).prefix(16))"

            var request = EntityAdmissionRequest(
                version: "1.0",
                request_id: requestID,
                target_scaffold_domain: targetDomain,
                target_identity_public_key: record.identity_public_key,
                target_identity_domain: record.scaffold_domain,
                continuity_proof_id: proof.proof_id,
                continuity_proof_sha256_b64url: continuityHash,
                source_scaffold_domain: proof.source_scaffold_domain,
                source_entity_id: proof.source_entity_id,
                source_identity_public_key: proof.source_identity_public_key,
                purpose: proof.purpose,
                goal: proof.goal,
                interests: proof.interests.sorted(),
                created_at: ISO8601DateFormatter().string(from: createdAt),
                expires_at: ISO8601DateFormatter().string(from: expiresAt),
                signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
            )
            request.signature = ResolverSignatureEnvelope(
                alg: "Ed25519",
                sig: try Ed25519.signBase64URL(
                    data: try request.canonicalPayloadData(),
                    seedBase64URL: seedBase64URL
                )
            )
            try emitJSON(request, outPath: flags["out"] ?? ".sprout/admission-requests/\(targetDomain).json")
        default:
            throw CLIError.invalidArguments("Expected: admission create-request")
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

        if let trustRoot = try? JSONDecoder().decode(ScaffoldAdminTrustRootDescriptor.self, from: data) {
            do {
                try ScaffoldAdminTrustRootDescriptorValidator().validate(
                    descriptor: trustRoot,
                    context: ScaffoldAdminTrustRootDescriptorValidationContext(
                        expectedDomain: trustRoot.scaffold_domain,
                        now: nowDate
                    )
                )
                print("ScaffoldAdminTrustRootDescriptor valid")
                exit(0)
            } catch {
                print("ScaffoldAdminTrustRootDescriptor invalid: \(error)")
                exit(2)
            }
        }

        if let catalog = try? JSONDecoder().decode(ScaffoldExecutableCatalog.self, from: data) {
            do {
                try ScaffoldExecutableCatalogValidator().validate(
                    catalog: catalog,
                    context: ScaffoldExecutableCatalogValidationContext(
                        expectedDomain: catalog.scaffold_domain,
                        now: nowDate
                    )
                )
                print("ScaffoldExecutableCatalog valid")
                exit(0)
            } catch {
                print("ScaffoldExecutableCatalog invalid: \(error)")
                exit(2)
            }
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

        if let proof = try? JSONDecoder().decode(CrossScaffoldEntityContinuityProof.self, from: data) {
            let valid = try proof.verifySignature() && !proof.isExpired(now: nowDate)
            print(valid ? "CrossScaffoldEntityContinuityProof valid" : "CrossScaffoldEntityContinuityProof invalid (signature or expiry)")
            exit(valid ? 0 : 2)
        }

        if let request = try? JSONDecoder().decode(EntityAdmissionRequest.self, from: data) {
            let valid = try request.verifySignature() && !request.isExpired(now: nowDate)
            print(valid ? "EntityAdmissionRequest valid" : "EntityAdmissionRequest invalid (signature or expiry)")
            exit(valid ? 0 : 2)
        }

        if let contract = try? JSONDecoder().decode(EntityAdmissionContract.self, from: data) {
            let valid = try contract.verifySignature() && !contract.isExpired(now: nowDate)
            print(valid ? "EntityAdmissionContract valid" : "EntityAdmissionContract invalid (signature or expiry)")
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
        trustRootDescriptor: ScaffoldAdminTrustRootDescriptor?,
        nowDate: Date
    ) throws -> any SproutResolverAdapter {
        let mode = try resolverMode(flags: flags)
        if mode == .liveHTTP {
            let environment = ProcessInfo.processInfo.environment
            let resolverBaseURL = try requiredResolverBaseURL(
                flags: flags,
                environment: environment,
                trustRootDescriptor: trustRootDescriptor
            )
            let trustedResolverKeys = Set(parseSetFlag(
                flags["trusted-resolver-key"] ?? environment["SPROUT_RESOLVER_TRUSTED_KEYS"]
            )).union(trustRootDescriptor?.resolver_public_keys ?? [])
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
        domain: String,
        trustRootDescriptor: ScaffoldAdminTrustRootDescriptor?
    ) throws -> any BridgeDiscoveryService {
        let environment = ProcessInfo.processInfo.environment
        let endpoint = try resolveDiscoveryEndpoint(
            flags: flags,
            environment: environment,
            domain: domain,
            trustRootDescriptor: trustRootDescriptor
        )
        return BridgeDiscoveryHTTPClient(endpoint: endpoint)
    }

    private static func resolverMode(flags: [String: String]) throws -> ResolverMode {
        let environment = ProcessInfo.processInfo.environment
        let liveFlag = flags["enable-live-resolver"] == "true" || environment["SPROUT_ENABLE_LIVE_RESOLVER"] == "1"
        let hasResolverBaseURL = flags["resolver-base-url"] != nil || environment["SPROUT_RESOLVER_BASE_URL"] != nil

        if liveFlag {
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

    private static func requiredResolverBaseURL(
        flags: [String: String],
        environment: [String: String],
        trustRootDescriptor: ScaffoldAdminTrustRootDescriptor?
    ) throws -> URL {
        let raw = flags["resolver-base-url"]
            ?? environment["SPROUT_RESOLVER_BASE_URL"]
            ?? trustRootDescriptor?.resolver_base_url
            ?? ""
        guard let url = URL(string: raw), !raw.isEmpty else {
            throw CLIError.invalidArguments("Invalid resolver base URL.")
        }
        return url
    }

    private static func resolveScaffoldTrustRootEndpoint(
        flags: [String: String],
        environment: [String: String],
        domain: String
    ) throws -> URL {
        if let raw = flags["trust-root-url"] ?? environment["SPROUT_TRUST_ROOT_URL"], !raw.isEmpty {
            guard let url = URL(string: raw) else {
                throw CLIError.invalidArguments("Invalid scaffold trust root URL.")
            }
            return url
        }

        guard let url = URL(string: "https://\(domain)/.well-known/haven-scaffold-admin-trust-root.json") else {
            throw CLIError.invalidArguments("Invalid scaffold trust root URL derived from scaffold domain.")
        }
        return url
    }

    private static func resolveDiscoveryEndpoint(
        flags: [String: String],
        environment: [String: String],
        domain: String,
        trustRootDescriptor: ScaffoldAdminTrustRootDescriptor?
    ) throws -> URL {
        if let raw = flags["discovery-url"] ?? environment["SPROUT_DISCOVERY_URL"], !raw.isEmpty {
            guard let url = URL(string: raw) else {
                throw CLIError.invalidArguments("Invalid discovery URL.")
            }
            return url
        }

        if let raw = trustRootDescriptor?.bridge_discovery_url, !raw.isEmpty {
            guard let url = URL(string: raw) else {
                throw CLIError.invalidArguments("Invalid discovery URL from scaffold trust root descriptor.")
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

    private static func resolveStarterBootstrapEndpoint(
        flags: [String: String],
        environment: [String: String],
        domain: String,
        trustRootDescriptor: ScaffoldAdminTrustRootDescriptor?
    ) throws -> URL {
        if let raw = flags["starter-bootstrap-url"] ?? environment["SPROUT_STARTER_BOOTSTRAP_URL"], !raw.isEmpty {
            guard let url = URL(string: raw) else {
                throw CLIError.invalidArguments("Invalid starter bootstrap URL.")
            }
            return url
        }

        if let raw = trustRootDescriptor?.starter_bootstrap_url, !raw.isEmpty {
            guard let url = URL(string: raw) else {
                throw CLIError.invalidArguments("Invalid starter bootstrap URL from scaffold trust root descriptor.")
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
            components.path = "/v1/resolver/starter-auth/intent"
            guard let url = components.url else {
                throw CLIError.invalidArguments("Invalid starter bootstrap URL derived from resolver base URL.")
            }
            return url
        }

        guard let url = URL(string: "https://\(domain)/v1/resolver/starter-auth/intent") else {
            throw CLIError.invalidArguments("Invalid starter bootstrap URL derived from scaffold domain.")
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

    private static func resolveScaffoldTrustRootSource(
        flags: [String: String],
        environment: [String: String],
        domain: String
    ) throws -> TrustRootSource? {
        if let path = flags["trust-root"], !path.isEmpty {
            return try validateTrustRootSource(path: path, origin: "flag")
        }

        if let path = environment["SPROUT_TRUST_ROOT_PATH"], !path.isEmpty {
            return try validateTrustRootSource(path: path, origin: "environment")
        }

        let candidates = [
            TrustRootSource(origin: "domain-cache", path: ".sprout/trust-roots/\(domain).json"),
            TrustRootSource(origin: "default-cache", path: ".sprout/scaffold_admin_trust_root.json")
        ]

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        return nil
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

    private static func validateTrustRootSource(path: String, origin: String) throws -> TrustRootSource {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError.invalidArguments("Scaffold trust root descriptor not found at \(path).")
        }
        return TrustRootSource(origin: origin, path: path)
    }

    private static func makeBootstrapPlan(
        flags: [String: String],
        environment: [String: String],
        runtime: SproutRuntimeProfile,
        purposeGoal: BootstrapPurposeGoal?,
        requestedPortholeKind: PortholeClientKind,
        starterSource: StarterAuthSource?,
        trustRootSource: TrustRootSource?
    ) throws -> BootstrapPlan {
        var capabilities: Set<BootstrapPlanningCapability> = [
            .remoteHostRouting,
            .portholeAttachment,
            .signedBridgeDiscoveryHTTP
        ]

        if trustRootSource != nil {
            capabilities.insert(.localScaffoldTrustRootDescriptor)
        }
        if starterSource != nil {
            capabilities.insert(.localStarterAuthPayload)
        }
        if purposeGoal?.isExplicitlySet == true {
            capabilities.insert(.scaffoldTrustRootHTTP)
            capabilities.insert(.starterBootstrapIntentHTTP)
        }
        if flags["catalog"] != nil {
            capabilities.insert(.offlineBridgeCatalog)
        }
        if flags["admission-contract"] != nil {
            capabilities.insert(.mockResolver)
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

    private static func materializeStarterAuthSource(
        flags: [String: String],
        environment: [String: String],
        domain: String,
        runtime: SproutRuntimeProfile,
        purposeGoal: BootstrapPurposeGoal,
        trustRootDescriptor: ScaffoldAdminTrustRootDescriptor?
    ) async throws -> StarterAuthSource {
        let endpoint = try resolveStarterBootstrapEndpoint(
            flags: flags,
            environment: environment,
            domain: domain,
            trustRootDescriptor: trustRootDescriptor
        )
        let client = try StarterBootstrapHTTPClient(endpoint: endpoint)
        let intent = try await client.issueIntent(
            StarterBootstrapIntentRequest(
                scaffold_domain: domain,
                purpose: purposeGoal.purpose,
                goal: purposeGoal.goal,
                interests: purposeGoal.interests,
                runtime: runtime.rawValue
            )
        )
        if let trustRootDescriptor, !trustRootDescriptor.trustsResolver(intent.issued_by) {
            throw CLIError.invalidArguments("Starter bootstrap intent issuer is not trusted by the scaffold trust root descriptor.")
        }

        let identityRoot = URL(fileURLWithPath: flags["starter-identity-root"] ?? ".sprout/starter-identities")
        let identityStore = StarterIdentityStore(root: identityRoot)
        let record = try await identityStore.loadOrCreate(scaffoldDomain: domain)
        let seedBase64URL = try await identityStore.seedBase64URL(scaffoldDomain: domain)

        var payload = StarterAuthPayload(
            version: "1.0",
            domain: intent.scaffold_domain,
            identity_public_key: record.identity_public_key,
            created_at: intent.created_at,
            expires_at: intent.expires_at,
            nonce: intent.nonce,
            purpose_interest: StarterPurposeInterest(
                purpose: intent.purpose,
                interests: intent.interests
            ),
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )
        payload.signature = ResolverSignatureEnvelope(
            alg: "Ed25519",
            sig: try Ed25519.signBase64URL(
                data: try payload.canonicalPayloadData(),
                seedBase64URL: seedBase64URL
            )
        )

        let outputPath = flags["starter-out"] ?? ".sprout/starters/\(domain).json"
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder.pretty.encode(payload).write(to: outputURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        return StarterAuthSource(origin: "bootstrap-intent", path: outputURL.path)
    }

    private static func loadScaffoldTrustRootDescriptor(
        source: TrustRootSource,
        expectedDomain: String,
        nowDate: Date
    ) throws -> ScaffoldAdminTrustRootDescriptor {
        let descriptor = try JSONDecoder().decode(
            ScaffoldAdminTrustRootDescriptor.self,
            from: Data(contentsOf: source.url)
        )
        try ScaffoldAdminTrustRootDescriptorValidator().validate(
            descriptor: descriptor,
            context: ScaffoldAdminTrustRootDescriptorValidationContext(
                expectedDomain: expectedDomain,
                now: nowDate
            )
        )
        return descriptor
    }

    private static func loadAndValidateExecutableCatalog(
        flags: [String: String],
        nowDate: Date
    ) throws -> ScaffoldExecutableCatalog {
        let catalogPath = try requiredFlag("catalog", flags)
        let catalog = try JSONDecoder().decode(
            ScaffoldExecutableCatalog.self,
            from: Data(contentsOf: URL(fileURLWithPath: catalogPath))
        )
        let domain = flags["domain"] ?? catalog.scaffold_domain
        let trustRoot = try flags["trust-root"].map { path in
            try loadScaffoldTrustRootDescriptor(
                source: TrustRootSource(origin: "flag", path: path),
                expectedDomain: domain,
                nowDate: nowDate
            )
        }
        try ScaffoldExecutableCatalogValidator().validate(
            catalog: catalog,
            context: ScaffoldExecutableCatalogValidationContext(
                expectedDomain: domain,
                trustedPublisherPublicKeys: trustedSoftwareCatalogPublisherKeys(
                    flags: flags,
                    trustRootDescriptor: trustRoot
                ),
                now: nowDate
            )
        )
        return catalog
    }

    private static func resolveExecutableCatalogEndpoint(
        flags: [String: String],
        domain: String,
        trustRootDescriptor: ScaffoldAdminTrustRootDescriptor?
    ) throws -> URL {
        if let catalogURL = try parseURLFlag(flags["catalog-url"], name: "catalog-url") {
            return catalogURL
        }
        if let softwareCatalogURL = trustRootDescriptor?.software_catalog_url,
           let url = URL(string: softwareCatalogURL) {
            return url
        }
        return ScaffoldExecutableCatalogHTTPClient.defaultEndpoint(scaffoldDomain: domain)
    }

    private static func trustedSoftwareCatalogPublisherKeys(
        flags: [String: String],
        trustRootDescriptor: ScaffoldAdminTrustRootDescriptor?
    ) -> [String] {
        let explicit = parseSetFlag(flags["trusted-publisher-keys"])
        if !explicit.isEmpty {
            return explicit
        }
        if let trustRootDescriptor {
            return [trustRootDescriptor.scaffold_admin_public_key]
        }
        return []
    }

    private static func materializeScaffoldTrustRootSource(
        flags: [String: String],
        environment: [String: String],
        domain: String,
        nowDate: Date
    ) async throws -> TrustRootSource {
        let endpoint = try resolveScaffoldTrustRootEndpoint(flags: flags, environment: environment, domain: domain)
        let client = try ScaffoldTrustRootHTTPClient(endpoint: endpoint, now: { nowDate })
        let descriptor = try await client.fetch(expectedDomain: domain)

        let outputPath = flags["trust-root-out"] ?? ".sprout/trust-roots/\(domain).json"
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder.pretty.encode(descriptor).write(to: outputURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        return TrustRootSource(origin: "well-known-trust-root", path: outputURL.path)
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
        print("Start sprout uten argumenter for en gjenopptakbar terminaldialog. Se sprout onboard --help.")
        print("sprout doctor [--json] kontrollerer runtime og kryptografi lokalt, uten aa lese identiteter eller kontakte nettverket.")
        let text = """
        sprout commands:
          sprout bootstrap plan --domain <d> [--purpose <p>] [--goal <g>] [--interests <i1,i2>] [--requested-capabilities <cap1,cap2>] [--runtime <cli-service|on-prem-service|macos-app|ios-app>] [--trust-root <file>] [--starter <file>] [--catalog <file>] [--enable-live-resolver --resolver-base-url <https://resolver.example>] [--entity-anchor <file>] [--resolved-entity <entity-id>] [--porthole <web|cli|native>] [--out <json>]
          sprout bootstrap join --domain <d> [--purpose <p>] [--goal <g>] [--interests <i1,i2>] [--requested-capabilities <cap1,cap2>] [--runtime <cli-service|on-prem-service|macos-app|ios-app>] [--trust-root <file>] [--trust-root-url <https://domain/.well-known/haven-scaffold-admin-trust-root.json>] [--trust-root-out <file>] [--starter <file>] [--starter-bootstrap-url <https://domain/v1/resolver/starter-auth/intent>] [--starter-identity-root <dir>] [--starter-out <file>] [--catalog <file>] [--discovery-url <https://domain/v1/bridges/query>] [--entity-link <file>|--admission-contract <file> [--continuity-proof <file>]] [--entity-anchor <file>] [--enable-live-resolver --resolver-base-url <https://resolver.example>] [--trusted-resolver-key <pubkey1,pubkey2>] [--resolver-bearer <token>] [--resolved-entity <entity-id>] [--porthole <web|cli|native>] [--audit <file>] [--state-out <file>] [--plan-only] [--plan-out <json>] [--now <ISO8601>]
          sprout bridges list --catalog <file>
          sprout owner init --domain <local-scaffold-domain> [--display-name <name>] [--note <text>] [--root <dir>] [--overwrite] [--out <json>]
          sprout owner show --domain <local-scaffold-domain> [--root <dir>] [--out <json>]
          sprout owner list [--root <dir>] [--out <json>]
          sprout owner trust-root --domain <local-scaffold-domain> [--root <dir>] [--resolver-public-keys <k1,k2>] [--bridge-owner-public-keys <k1,k2>] [--resolver-base-url <https://domain>] [--starter-bootstrap-url <https://domain/v1/resolver/starter-auth/intent>] [--bridge-discovery-url <https://domain/v1/bridges/query>] [--software-catalog-url <https://domain/.well-known/haven-executable-catalog.json>] [--descriptor-id <id>] [--issued-at <ISO8601>] [--expires-at <ISO8601>] [--now <ISO8601>] [--out <json>]
          sprout software fetch --domain <d> [--trust-root <file>] [--catalog-url <https://domain/.well-known/haven-executable-catalog.json>] [--trusted-publisher-keys <k1,k2>] [--now <ISO8601>] [--out <json>]
          sprout software verify --catalog <file> [--domain <d>] [--trust-root <file>] [--trusted-publisher-keys <k1,k2>] [--now <ISO8601>]
          sprout software select --catalog <file> --kind <cellscaffold|sprout|scaffold-bundle> --platform <linux-x86_64|macos-arm64> [--channel <stable|beta>] [--name <artifact-name>] [--domain <d>] [--trust-root <file>] [--trusted-publisher-keys <k1,k2>] [--now <ISO8601>] [--out <json>]
          sprout software sign-catalog --domain <local-scaffold-domain> --unsigned <catalog.json> [--root <dir>] [--now <ISO8601>] [--out <json>]
          sprout federation init --remote-domain <domain> [--local-domain <domain>] [--note <text>] [--root <dir>] [--overwrite] [--out <json>]
          sprout federation show --remote-domain <domain> [--root <dir>] [--out <json>]
          sprout federation list [--root <dir>] [--out <json>]
          sprout admission create-request --continuity-proof <proof.json> [--domain <target-domain>] [--starter-identity-root <dir>] [--request-id <id>] [--created-at <ISO8601>] [--expires-at <ISO8601>] [--now <ISO8601>] [--out <file>]
          sprout link export --file <entity-link.json> [--out <canonical.json>]
          sprout link import --file <entity-link.json>
          sprout entity connect [--place app|haven|staging]
          sprout nearby browse [--seconds 1…120]
          sprout nearby inspect|advertise --offer-file <file>
          sprout porthole web-bootstrap --contract <porthole-access-contract.json> [--out <descriptor.json>] [--now <ISO8601>]
          sprout porthole native-spec --contract <porthole-access-contract.json> [--out <descriptor.json>] [--now <ISO8601>]
          sprout verify <file> [--now <ISO8601>]
          sprout economics units --rau <int64>|--imu <int64>|--ore <int64>|--nok <int64> [--out <json>]
          sprout economics compile-contract --contract <pricing-contract.json> [--deposit-rau <int64>] [--requested-capabilities <cap1,cap2>] [--out <json>]
          sprout economics stripe-sim [--topups-nok <20,50,100,300>] [--daily-spend-nok <int64>] [--out <json>]
          sprout economics rollup --usage <usage-deltas.json> [--contract <pricing-contract.json>] [--out <json>]
          sprout economics suggest-rate --records <session-records.json> [--rau-per-thread-minute <int64>] [--rau-per-gib-minute <int64>] [--rau-per-cpu-second <int64>] [--rau-per-message <int64>] [--rau-per-audit-event <int64>] [--target-margin-bps <int64>] [--out <json>]
          sprout update --policy <policy.json> --artifact <name> --hash <sha256_b64url> --version <semver> --channel <stable|beta> --trigger <pubkey-or-contract> [--auto]

        scaffold trust root lookup and acquisition order for bootstrap:
          1. --trust-root <file>
          2. SPROUT_TRUST_ROOT_PATH
          3. .sprout/trust-roots/<domain>.json
          4. .sprout/scaffold_admin_trust_root.json
          5. scaffold trust-root descriptor from .well-known when purpose/goal/interests are explicit

        starter auth lookup and acquisition order for bootstrap:
          1. --starter <file>
          2. SPROUT_STARTER_AUTH_PATH
          3. .sprout/starters/<domain>.json
          4. .sprout/starter_auth_payload.json
          5. starter bootstrap intent from scaffold when purpose/goal/interests are explicit

        note:
          bootstrap plan and bootstrap join --plan-only do not perform bootstrap network calls
        
        starter bootstrap intent endpoint resolution order:
          1. --starter-bootstrap-url
          2. SPROUT_STARTER_BOOTSTRAP_URL
          3. trust root descriptor starter_bootstrap_url
          4. resolver origin + /v1/resolver/starter-auth/intent
          5. https://<domain>/v1/resolver/starter-auth/intent

        scaffold trust root endpoint resolution order:
          1. --trust-root-url
          2. SPROUT_TRUST_ROOT_URL
          3. https://<domain>/.well-known/haven-scaffold-admin-trust-root.json

        executable catalog endpoint resolution order:
          1. --catalog-url
          2. trust root descriptor software_catalog_url
          3. https://<domain>/.well-known/haven-executable-catalog.json
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

    private static func parseOptionalNow(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else {
            throw CLIError.invalidArguments("Invalid ISO8601 date-time.")
        }
        return date
    }

    private static func parseURLFlag(_ value: String?, name: String) throws -> URL? {
        guard let value, !value.isEmpty else { return nil }
        guard let url = URL(string: value) else {
            throw CLIError.invalidArguments("Invalid --\(name) value.")
        }
        return url
    }
}

private struct BootstrapCommandOutput: Codable {
    var final_state: String
    var event_count: Int
    var resolver_mode: String
    var requested_porthole_kind: String
    var scaffold_trust_root_source: TrustRootSource?
    var starter_source: StarterAuthSource?
    var bootstrap_plan: BootstrapPlan?
    var entity_resolution_status: String?
    var resolved_entity_id: String?
    var entity_inclusion_proof_id: String?
    var entity_admission_contract_id: String?
    var continuity_proof_id: String?
    var scaffold_trust_root_descriptor_id: String?
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
    var scaffold_trust_root_source: TrustRootSource?
    var starter_source: StarterAuthSource?
    var bootstrap_plan: BootstrapPlan
}

private struct TrustRootSource: Codable {
    var origin: String
    var path: String

    var url: URL {
        URL(fileURLWithPath: path)
    }
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
