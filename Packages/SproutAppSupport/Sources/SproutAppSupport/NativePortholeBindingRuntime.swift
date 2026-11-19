import Foundation
import SproutCore

#if canImport(Combine)
import Combine
#else
public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}
#endif

#if SPROUT_ENABLE_CELLPROTOCOL_RUNTIME && canImport(CellBase) && canImport(CellApple)
@preconcurrency import CellBase
@preconcurrency import CellApple
import SproutCrypto

public enum NativePortholeBindingRuntimeError: Error, Equatable, Sendable {
    case unsupportedMode
    case descriptorUnavailable
    case resolverUnavailable
    case identityUnavailable
    case connectionFailed(String)
    case bridgeEndpointRejected(String)
    case identityMismatch
}

@MainActor
public final class NativePortholeBindingRuntime: ObservableObject {
    @Published public private(set) var skeleton: SkeletonElement?
    @Published public private(set) var statusMessage = "Idle"
    @Published public private(set) var errorMessage: String?

    private var flowCancellable: AnyCancellable?
    private var currentRequester: Identity?
    private var currentEmit: Emit?

    private let contractPresenter: any NativePortholeContractPresenting

    public init(contractPresenter: any NativePortholeContractPresenting = URLSessionNativePortholeContractPresenter()) {
        self.contractPresenter = contractPresenter
    }

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

            // Both checks use CellProtocol's own types and run before the
            // contract leaves this process.
            try Self.validateBridgeEndpoint(descriptor.bridge_websocket_url)
            try Self.validateRequester(requester, matches: descriptor)

            currentRequester = requester
            statusMessage = "Presenting native porthole contract"
            // The contract goes in an HTTPS body; the bridge URL carries none.
            try await contractPresenter.present(descriptor)
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

    /// CellProtocol's resolver opens `endpoint` + "/" + bridge ID through
    /// `BridgeChannelAuthentication.Endpoint`; check that exact form here.
    static func validateBridgeEndpoint(_ endpoint: String) throws {
        guard let url = URL(string: endpoint), url.scheme == "ws" || url.scheme == "wss" else {
            throw NativePortholeBindingRuntimeError.bridgeEndpointRejected("not a ws/wss URL")
        }
        if url.scheme == "ws" && !CellBase.allowsInsecureWebSocket(toHost: url.host) {
            throw NativePortholeBindingRuntimeError.bridgeEndpointRejected("insecure WebSocket not allowed")
        }
        do {
            _ = try BridgeChannelAuthentication.Endpoint(
                url: url.appendingPathComponent(UUID().uuidString),
                domain: "bridge",
                allowInsecureLoopback: url.scheme == "ws"
            )
        } catch {
            throw NativePortholeBindingRuntimeError.bridgeEndpointRejected(String(describing: error))
        }
    }

    /// The scaffold binds the presented contract to `identity_public_key` and
    /// admits the WebSocket only when the channel-authenticated principal has
    /// that key, so the requester that signs the channel must hold it.
    static func validateRequester(_ requester: Identity, matches descriptor: NativePortholeBindingDescriptor) throws {
        let channelIdentity = try BridgeChannelAuthentication.PublicIdentity(requester)
        guard channelIdentity.algorithm == .EdDSA, channelIdentity.curve == .Curve25519,
              let contractKey = try? Base64URL.decode(descriptor.identity_public_key),
              channelIdentity.publicKey == contractKey else {
            throw NativePortholeBindingRuntimeError.identityMismatch
        }
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

    /// CellProtocol's `SkeletonElement` decoder decides what a skeleton is;
    /// it maps unknown element names to `.Unsupported`, which is not taken as
    /// a skeleton here. No local list of element names.
    private func extractSkeletonObject(from object: Object) -> Object? {
        if Self.isSkeleton(object) {
            return object
        }
        if case let .object(nested)? = object["skeleton"], Self.isSkeleton(nested) {
            return nested
        }
        return nil
    }

    private static func isSkeleton(_ object: Object) -> Bool {
        guard let data = try? JSONEncoder().encode(object),
              let element = try? JSONDecoder().decode(SkeletonElement.self, from: data) else {
            return false
        }
        if case .Unsupported = element { return false }
        return true
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
#else
public enum NativePortholeBindingRuntimeError: Error, Equatable, Sendable {
    case unsupportedMode
    case descriptorUnavailable
    case resolverUnavailable
    case identityUnavailable
    case connectionFailed(String)
}

@MainActor
public final class NativePortholeBindingRuntime: ObservableObject {
    @Published public private(set) var skeleton: Any?
    @Published public private(set) var statusMessage = "Native runtime unavailable in standalone build"
    @Published public private(set) var errorMessage: String?

    public init() {}

    public func connect(using session: PortholeClientSession) async {
        guard session.mode == .native else {
            errorMessage = String(describing: NativePortholeBindingRuntimeError.unsupportedMode)
            statusMessage = "Unsupported contract mode"
            return
        }

        guard session.nativeDescriptor != nil else {
            errorMessage = String(describing: NativePortholeBindingRuntimeError.descriptorUnavailable)
            statusMessage = "Missing native descriptor"
            return
        }

        errorMessage = "This build does not embed CellProtocol. Native contracts can be inspected and copied, but live native binding requires a workspace-coupled build."
        statusMessage = "Native runtime unavailable in standalone build"
    }

    public func disconnect() {
        statusMessage = "Disconnected"
    }
}
#endif
