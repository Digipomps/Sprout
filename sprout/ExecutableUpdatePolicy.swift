import Foundation

enum ExecutableUpdateOperation: String, Hashable, Sendable {
    case checkForUpdate
    case downloadArtifact
    case verifyArtifactSignature
    case replaceExecutable
    case restartProcess
    case migrateRuntimeData
}

struct ExecutableUpdateDecision: Equatable, Sendable {
    var allowed: Bool
    var deniedOperations: Set<ExecutableUpdateOperation>
}

struct ExecutableUpdatePolicy: Equatable, Sendable {
    var grantedOperations: Set<ExecutableUpdateOperation>

    func evaluate(requested requestedOperations: Set<ExecutableUpdateOperation>) -> ExecutableUpdateDecision {
        let denied = requestedOperations.subtracting(grantedOperations)
        return ExecutableUpdateDecision(
            allowed: denied.isEmpty,
            deniedOperations: denied
        )
    }
}
