import Foundation

public enum TransportKind: String, Codable, Sendable {
    case https
    case wss
    case grpc
    case quic
}

public enum TransportError: Error, Equatable, Sendable {
    case invalidEndpoint(String)
    case unsupportedTransport(String)
    case insecureTransportNotAllowed(String)
    case channelClosed
    case noPendingPayload
    case noDataAvailable
    case notImplemented(String)
}

public protocol Channel: Sendable {
    func send(_ bytes: Data) async throws
    func receive() async throws -> Data
    func close() async
}

public protocol TransportClient: Sendable {
    var kind: TransportKind { get }
    func connect(endpoint: URL) async throws -> any Channel
}

public struct TransportAdapterRegistry: Sendable {
    private let adapters: [TransportKind: any TransportClient]

    public init(adapters: [any TransportClient]) {
        var map = [TransportKind: any TransportClient]()
        for adapter in adapters {
            map[adapter.kind] = adapter
        }
        self.adapters = map
    }

    public func adapter(for endpoint: URL) throws -> any TransportClient {
        guard let scheme = endpoint.scheme?.lowercased() else {
            throw TransportError.invalidEndpoint("Missing URL scheme")
        }

        switch scheme {
        case "https":
            guard let adapter = adapters[.https] else {
                throw TransportError.unsupportedTransport("No HTTPS adapter registered")
            }
            return adapter
        case "wss":
            guard let adapter = adapters[.wss] else {
                throw TransportError.unsupportedTransport("No WSS adapter registered")
            }
            return adapter
        case "grpc", "http2":
            guard let adapter = adapters[.grpc] else {
                throw TransportError.unsupportedTransport("No gRPC adapter registered")
            }
            return adapter
        case "quic", "https3", "h3":
            guard let adapter = adapters[.quic] else {
                throw TransportError.unsupportedTransport("No QUIC adapter registered")
            }
            return adapter
        default:
            throw TransportError.unsupportedTransport("Unsupported scheme: \(scheme)")
        }
    }
}
