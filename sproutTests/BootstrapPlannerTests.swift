import Testing
@testable import sprout

struct BootstrapPlannerTests {
    private let defaultPurposes = [
        PurposeGoalDefinition(
            purpose: "Connect to remote scaffold",
            goal: "Attach owner Porthole and sync helper cells",
            requiredCapabilities: [.remoteHostRouting, .portholeAttachment]
        )
    ]

    private let defaultHelpers = [
        HelperCellDescriptor(
            name: "BridgeAndPortholeHelper",
            capabilities: [.remoteHostRouting, .portholeAttachment]
        )
    ]

    @Test func serverRuntimeWithoutBootstrapChannelIsBlocked() {
        let planner = BootstrapPlanner()
        let environment = BootstrapEnvironment(
            runtime: .cloudService,
            availableCapabilities: [.remoteHostRouting, .portholeAttachment]
        )

        let plan = planner.plan(
            environment: environment,
            purposes: defaultPurposes,
            helperCells: defaultHelpers
        )

        #expect(plan.actions.contains(where: { $0.id == .manualOwnerBootstrap && $0.blocking }))
        #expect(plan.readyForFirstConnection == false)
    }

    @Test func serverRuntimeCanUseBonjourWhenOwnerContextIsMissing() {
        let planner = BootstrapPlanner()
        let environment = BootstrapEnvironment(
            runtime: .onPremService,
            availableCapabilities: [.bonjourDiscovery, .remoteHostRouting, .portholeAttachment]
        )

        let plan = planner.plan(
            environment: environment,
            purposes: defaultPurposes,
            helperCells: defaultHelpers
        )

        #expect(plan.actions.contains(where: { $0.id == .discoverOwnerViaBonjour && $0.blocking == false }))
        #expect(plan.actions.contains(where: { $0.id == .manualOwnerBootstrap }) == false)
        #expect(plan.readyForFirstConnection)
    }

    @Test func personalRuntimeInitializesIdentityFromSecureVault() {
        let planner = BootstrapPlanner()
        let environment = BootstrapEnvironment(
            runtime: .desktopPersonal,
            availableCapabilities: [.localSecureVault, .remoteHostRouting, .portholeAttachment]
        )

        let plan = planner.plan(
            environment: environment,
            purposes: defaultPurposes,
            helperCells: defaultHelpers
        )

        #expect(plan.actions.contains(where: { $0.id == .initializeLocalOwnerIdentity && $0.blocking == false }))
        #expect(plan.readyForFirstConnection)
    }

    @Test func updatePolicyDeniesUngrantableOperations() {
        let policy = ExecutableUpdatePolicy(
            grantedOperations: [.checkForUpdate, .downloadArtifact, .verifyArtifactSignature]
        )

        let requested: Set<ExecutableUpdateOperation> = [
            .downloadArtifact,
            .verifyArtifactSignature,
            .replaceExecutable
        ]

        let decision = policy.evaluate(requested: requested)

        #expect(decision.allowed == false)
        #expect(decision.deniedOperations == [.replaceExecutable])
    }
}
