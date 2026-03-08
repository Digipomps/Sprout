import Foundation
import SproutCore

#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

#if canImport(CellBase) && canImport(CellApple)
@preconcurrency import CellBase
@preconcurrency import CellApple

public enum NativePortholeBindingRuntimeError: Error, Equatable, Sendable {
    case unsupportedMode
    case descriptorUnavailable
    case resolverUnavailable
    case identityUnavailable
    case connectionFailed(String)
}

@MainActor
public final class NativePortholeBindingRuntime: ObservableObject {
    @Published public private(set) var skeleton: SkeletonElement?
    @Published public private(set) var statusMessage = "Idle"
    @Published public private(set) var errorMessage: String?

    private var flowCancellable: AnyCancellable?
    private var currentRequester: Identity?
    private var currentEmit: Emit?

    public init() {}

    public func connect(using session: PortholeClientSession) async {
        do {
            guard session.mode == .native else {
                throw NativePortholeBindingRuntimeError.unsupportedMode
            }
            guard let descriptor = session.nativeDescriptor else {
                throw NativePortholeBindingRuntimeError.descriptorUnavailable
            }

            statusMessage = "Initializing CellProtocol runtime"
            await AppInitializer.initialize()

            guard let resolver = await runtimeResolver() else {
                throw NativePortholeBindingRuntimeError.resolverUnavailable
            }
            guard let vault = await identityVault(),
                  let requester = await vault.identity(for: "private", makeNewIfNotFound: true) else {
                throw NativePortholeBindingRuntimeError.identityUnavailable
            }

            currentRequester = requester
            statusMessage = "Connecting native porthole bridge"

            let remotePorthole = try await resolver.cellAtEndpoint(
                endpoint: descriptor.bridge_websocket_url,
                requester: requester
            )
            currentEmit = remotePorthole

            if let meddle = remotePorthole as? Meddle {
                try await fetchInitialSkeleton(from: meddle, requester: requester)
            }

            flowCancellable = try await remotePorthole.flow(requester: requester)
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { [weak self] completion in
                        guard let self else { return }
                        self.statusMessage = "Bridge completed: \(completion)"
                    },
                    receiveValue: { [weak self] flowElement in
                        guard let self else { return }
                        self.consume(flowElement: flowElement)
                    }
                )

            statusMessage = "Connected to native porthole"
            errorMessage = nil
        } catch {
            currentRequester = nil
            currentEmit = nil
            flowCancellable?.cancel()
            flowCancellable = nil
            errorMessage = String(describing: error)
            statusMessage = "Native bridge failed"
        }
    }

    public func disconnect() {
        flowCancellable?.cancel()
        flowCancellable = nil
        if let requester = currentRequester, let emit = currentEmit {
            emit.close(requester: requester)
        }
        currentRequester = nil
        currentEmit = nil
        statusMessage = "Disconnected"
    }

    private func fetchInitialSkeleton(from meddle: Meddle, requester: Identity) async throws {
        if let skeleton = try await loadSkeleton(keypath: "skeleton", from: meddle, requester: requester) {
            self.skeleton = skeleton
            return
        }
        if let skeleton = try await loadSkeleton(keypath: "state", from: meddle, requester: requester) {
            self.skeleton = skeleton
            return
        }
        self.skeleton = SkeletonDescriptions.skeletonDescriptionFromJson().skeleton
    }

    private func loadSkeleton(
        keypath: String,
        from meddle: Meddle,
        requester: Identity
    ) async throws -> SkeletonElement? {
        let value = try await meddle.get(keypath: keypath, requester: requester)
        guard case let .object(object) = value,
              let skeletonObject = extractSkeletonObject(from: object) else {
            return nil
        }
        return try decodeSkeleton(from: skeletonObject)
    }

    private func consume(flowElement: FlowElement) {
        guard case let .object(object) = flowElement.content,
              let skeletonObject = extractSkeletonObject(from: object),
              let decoded = try? decodeSkeleton(from: skeletonObject) else {
            return
        }
        skeleton = decoded
        statusMessage = "Received live native porthole update"
    }

    private func extractSkeletonObject(from object: Object) -> Object? {
        let skeletonRootKeys: Set<String> = [
            "List", "Object", "Spacer", "Image", "Text", "TextField", "TextArea",
            "HStack", "VStack", "Reference", "Button", "Divider", "ScrollView",
            "Section", "ZStack", "Grid", "Toggle"
        ]

        if object.keys.contains(where: { skeletonRootKeys.contains($0) }) {
            return object
        }
        if case let .object(nested)? = object["skeleton"],
           nested.keys.contains(where: { skeletonRootKeys.contains($0) }) {
            return nested
        }
        return nil
    }

    private func decodeSkeleton(from object: Object) throws -> SkeletonElement {
        let data = try JSONEncoder().encode(object)
        return try JSONDecoder().decode(SkeletonElement.self, from: data)
    }

    private func runtimeResolver() async -> CellResolver? {
        await MainActor.run {
            CellBase.defaultCellResolver as? CellResolver
        }
    }

    private func identityVault() async -> IdentityVault? {
        await MainActor.run {
            CellBase.defaultIdentityVault as? IdentityVault
        }
    }
}
#endif
