import Testing
@testable import SproutCore

struct BootstrapPlannerTests {
    @Test
    func blocksWhenPurposeGoalIsNotExplicit() {
        let planner = BootstrapPlanner()
        let environment = BootstrapPlanningEnvironment(
            runtime: .cliService,
            availableCapabilities: [
                .localStarterAuthPayload,
                .signedBridgeDiscoveryHTTP,
                .liveResolverHTTP,
                .remoteHostRouting,
                .portholeAttachment
            ]
        )

        let plan = planner.plan(
            environment: environment,
            request: BootstrapPlanningRequest(
                purposeGoal: nil,
                requestedPortholeKind: .cli
            )
        )

        #expect(plan.actions.contains(where: { $0.id == .validateExplicitPurposeGoal && $0.blocking }))
        #expect(plan.readyForFirstConnection == false)
    }

    @Test
    func blocksWhenStarterAuthPayloadIsMissing() {
        let planner = BootstrapPlanner()
        let environment = BootstrapPlanningEnvironment(
            runtime: .cliService,
            availableCapabilities: [
                .signedBridgeDiscoveryHTTP,
                .liveResolverHTTP,
                .remoteHostRouting,
                .portholeAttachment
            ]
        )

        let plan = planner.plan(
            environment: environment,
            request: BootstrapPlanningRequest(
                purposeGoal: BootstrapPurposeGoal(
                    purpose: "bootstrap.join_scaffold",
                    goal: "Connect to staging and request a CLI porthole",
                    interests: ["haven.core.bootstrap", "haven.core.bridge"]
                ),
                requestedPortholeKind: .cli
            )
        )

        #expect(plan.actions.contains(where: { $0.id == .manualStarterBootstrap && $0.blocking }))
        #expect(plan.missingCapabilities.contains(.localStarterAuthPayload))
        #expect(plan.readyForFirstConnection == false)
    }

    @Test
    func prefersOfflineCatalogWhenAvailableInAutoMode() {
        let planner = BootstrapPlanner()
        let environment = BootstrapPlanningEnvironment(
            runtime: .cliService,
            availableCapabilities: [
                .localStarterAuthPayload,
                .offlineBridgeCatalog,
                .signedBridgeDiscoveryHTTP,
                .entityAnchorSnapshot,
                .remoteHostRouting,
                .portholeAttachment
            ]
        )

        let plan = planner.plan(
            environment: environment,
            request: BootstrapPlanningRequest(
                purposeGoal: BootstrapPurposeGoal(
                    purpose: "bootstrap.join_scaffold",
                    goal: "Connect to a scaffold using the local signed catalog",
                    interests: ["haven.core.bootstrap"]
                ),
                requestedPortholeKind: .cli
            )
        )

        #expect(plan.actions.contains(where: { $0.id == .loadOfflineBridgeCatalog && $0.blocking == false }))
        #expect(plan.actions.contains(where: { $0.id == .resolveEntityViaSnapshot && $0.blocking == false }))
        #expect(plan.readyForFirstConnection)
    }

    @Test
    func explicitOfflinePreferenceBlocksWithoutCatalog() {
        let planner = BootstrapPlanner()
        let environment = BootstrapPlanningEnvironment(
            runtime: .cliService,
            availableCapabilities: [
                .localStarterAuthPayload,
                .signedBridgeDiscoveryHTTP,
                .liveResolverHTTP,
                .remoteHostRouting,
                .portholeAttachment
            ]
        )

        let plan = planner.plan(
            environment: environment,
            request: BootstrapPlanningRequest(
                purposeGoal: BootstrapPurposeGoal(
                    purpose: "bootstrap.join_scaffold",
                    goal: "Connect using only offline discovery",
                    interests: ["haven.core.bootstrap"]
                ),
                requestedPortholeKind: .cli,
                discoveryPreference: .offlineCatalog
            )
        )

        #expect(plan.actions.contains(where: { $0.id == .missingBridgeDiscovery && $0.blocking }))
        #expect(plan.missingCapabilities.contains(.offlineBridgeCatalog))
        #expect(plan.readyForFirstConnection == false)
    }
}
