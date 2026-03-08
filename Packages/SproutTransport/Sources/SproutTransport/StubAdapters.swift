import Foundation

public struct GRPCTransportClient: TransportClient {
    public let kind: TransportKind = .grpc

    public init() {}

    public func connect(endpoint: URL) async throws -> any Channel {
        _ = endpoint
        throw TransportError.notImplemented("gRPC/HTTP2 adapter is a P1 stub")
    }
}

public struct QUICTransportClient: TransportClient {
    public let kind: TransportKind = .quic

    public init() {}

    public func connect(endpoint: URL) async throws -> any Channel {
        _ = endpoint
        throw TransportError.notImplemented("QUIC/HTTP3 adapter is a P2 stub")
    }
}
