import Foundation

enum SproutRuntimeProfile: String, CaseIterable, Sendable {
    case cloudService
    case onPremService
    case desktopPersonal
    case mobilePersonal

    var requiresExternalOwnerBootstrap: Bool {
        switch self {
        case .cloudService, .onPremService:
            return true
        case .desktopPersonal, .mobilePersonal:
            return false
        }
    }
}

enum SproutBootstrapCapability: String, Hashable, Sendable {
    case ownerContextEnvironment
    case ownerUUIDEnvironment
    case bonjourDiscovery
    case qrBootstrapURL
    case localSecureVault
    case remoteHostRouting
    case portholeAttachment
}

struct PurposeGoalDefinition: Equatable, Sendable {
    var purpose: String
    var goal: String
    var requiredCapabilities: Set<SproutBootstrapCapability>
}

struct HelperCellDescriptor: Equatable, Sendable {
    var name: String
    var capabilities: Set<SproutBootstrapCapability>
}

struct BootstrapEnvironment: Equatable, Sendable {
    var runtime: SproutRuntimeProfile
    var availableCapabilities: Set<SproutBootstrapCapability>
}

enum BootstrapActionID: String, Sendable {
    case validatePurposeGoals = "validate-purpose-goals"
    case missingHelperCoverage = "missing-helper-coverage"
    case resolveOwnerFromContext = "resolve-owner-from-context"
    case discoverOwnerViaBonjour = "discover-owner-via-bonjour"
    case discoverOwnerViaQR = "discover-owner-via-qr"
    case initializeLocalOwnerIdentity = "initialize-local-owner-identity"
    case manualOwnerBootstrap = "manual-owner-bootstrap"
    case configureRemoteHostRouting = "configure-remote-host-routing"
    case attachPorthole = "attach-porthole"
}

struct BootstrapAction: Equatable, Sendable {
    var id: BootstrapActionID
    var description: String
    var blocking: Bool
}

struct BootstrapPlan: Equatable, Sendable {
    var runtime: SproutRuntimeProfile
    var actions: [BootstrapAction]
    var missingCapabilities: Set<SproutBootstrapCapability>

    var readyForFirstConnection: Bool {
        !actions.contains(where: \.blocking)
    }
}

struct BootstrapPlanner {
    func plan(
        environment: BootstrapEnvironment,
        purposes: [PurposeGoalDefinition],
        helperCells: [HelperCellDescriptor]
    ) -> BootstrapPlan {
        var actions = [BootstrapAction]()
        var missingCapabilities = Set<SproutBootstrapCapability>()

        let helperCapabilities = helperCells.reduce(into: Set<SproutBootstrapCapability>()) { partialResult, helper in
            partialResult.formUnion(helper.capabilities)
        }

        if purposes.isEmpty {
            actions.append(BootstrapAction(
                id: .validatePurposeGoals,
                description: "No Purpose/Goal definitions were provided for bootstrap.",
                blocking: true
            ))
        } else {
            var uncoveredCapabilities = Set<SproutBootstrapCapability>()
            for purpose in purposes {
                let uncovered = purpose.requiredCapabilities.subtracting(helperCapabilities)
                uncoveredCapabilities.formUnion(uncovered)
            }

            if uncoveredCapabilities.isEmpty {
                actions.append(BootstrapAction(
                    id: .validatePurposeGoals,
                    description: "Purpose/Goal definitions are covered by available helper-cell capabilities.",
                    blocking: false
                ))
            } else {
                missingCapabilities.formUnion(uncoveredCapabilities)
                actions.append(BootstrapAction(
                    id: .missingHelperCoverage,
                    description: "At least one Purpose/Goal cannot be fulfilled by current helper-cell capabilities.",
                    blocking: true
                ))
            }
        }

        actions.append(ownerBootstrapAction(environment: environment, missingCapabilities: &missingCapabilities))
        actions.append(routeConfigurationAction(environment: environment, missingCapabilities: &missingCapabilities))
        actions.append(portholeAction(environment: environment, missingCapabilities: &missingCapabilities))

        return BootstrapPlan(
            runtime: environment.runtime,
            actions: actions,
            missingCapabilities: missingCapabilities
        )
    }

    private func ownerBootstrapAction(
        environment: BootstrapEnvironment,
        missingCapabilities: inout Set<SproutBootstrapCapability>
    ) -> BootstrapAction {
        if environment.runtime.requiresExternalOwnerBootstrap {
            if environment.availableCapabilities.contains(.ownerUUIDEnvironment) || environment.availableCapabilities.contains(.ownerContextEnvironment) {
                return BootstrapAction(
                    id: .resolveOwnerFromContext,
                    description: "Resolve scaffold owner identity from explicit startup context/environment.",
                    blocking: false
                )
            }

            if environment.availableCapabilities.contains(.bonjourDiscovery) {
                return BootstrapAction(
                    id: .discoverOwnerViaBonjour,
                    description: "Discover scaffold owner identity through zero-config local discovery.",
                    blocking: false
                )
            }

            if environment.availableCapabilities.contains(.qrBootstrapURL) {
                return BootstrapAction(
                    id: .discoverOwnerViaQR,
                    description: "Bootstrap owner identity from a signed QR/deeplink payload.",
                    blocking: false
                )
            }

            return BootstrapAction(
                id: .manualOwnerBootstrap,
                description: "No owner bootstrap channel available for service runtime.",
                blocking: true
            )
        }

        if environment.availableCapabilities.contains(.localSecureVault) {
            return BootstrapAction(
                id: .initializeLocalOwnerIdentity,
                description: "Create or load local owner identity from secure platform vault.",
                blocking: false
            )
        }

        missingCapabilities.insert(.localSecureVault)
        return BootstrapAction(
            id: .initializeLocalOwnerIdentity,
            description: "Local secure vault capability is missing for personal runtime bootstrap.",
            blocking: true
        )
    }

    private func routeConfigurationAction(
        environment: BootstrapEnvironment,
        missingCapabilities: inout Set<SproutBootstrapCapability>
    ) -> BootstrapAction {
        if environment.availableCapabilities.contains(.remoteHostRouting) {
            return BootstrapAction(
                id: .configureRemoteHostRouting,
                description: "Configure remote cell host routing for scaffold-to-scaffold connectivity.",
                blocking: false
            )
        }

        missingCapabilities.insert(.remoteHostRouting)
        return BootstrapAction(
            id: .configureRemoteHostRouting,
            description: "Remote host routing is missing.",
            blocking: true
        )
    }

    private func portholeAction(
        environment: BootstrapEnvironment,
        missingCapabilities: inout Set<SproutBootstrapCapability>
    ) -> BootstrapAction {
        if environment.availableCapabilities.contains(.portholeAttachment) {
            return BootstrapAction(
                id: .attachPorthole,
                description: "Attach and activate Porthole for resolver and helper-cell orchestration.",
                blocking: false
            )
        }

        missingCapabilities.insert(.portholeAttachment)
        return BootstrapAction(
            id: .attachPorthole,
            description: "Porthole attachment capability is missing.",
            blocking: true
        )
    }
}
