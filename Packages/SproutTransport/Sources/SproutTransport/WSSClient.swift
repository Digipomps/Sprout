import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct WSSTransportClient: TransportClient {
    public let kind: TransportKind = .wss
    private let allowInsecureWS: Bool
    private let sessionConfiguration: URLSessionConfiguration

    public init(
        allowInsecureWS: Bool = false,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.allowInsecureWS = allowInsecureWS
        self.sessionConfiguration = sessionConfiguration
    }

    public func connect(endpoint: URL) async throws -> any Channel {
        guard let scheme = endpoint.scheme?.lowercased() else {
            throw TransportError.invalidEndpoint("Missing URL scheme")
        }

        switch scheme {
        case "wss":
            return try WSSChannel(endpoint: endpoint, session: URLSession(configuration: sessionConfiguration))
        case "ws":
            if allowInsecureWS {
                return try WSSChannel(endpoint: endpoint, session: URLSession(configuration: sessionConfiguration))
            }
            throw TransportError.insecureTransportNotAllowed("WS is disabled. Use WSS/TLS1.3.")
        default:
            throw TransportError.invalidEndpoint("WSS adapter received unsupported scheme: \(scheme)")
        }
    }
}

public actor WSSChannel: Channel {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    private let task: URLSessionWebSocketTask
    #endif
    private var closed = false

    init(endpoint: URL, session: URLSession) throws {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        self.task = session.webSocketTask(with: endpoint)
        self.task.resume()
        #else
        throw TransportError.unsupportedTransport("WebSocket streaming is not enabled on this runtime")
        #endif
    }

    public func send(_ bytes: Data) async throws {
        guard !closed else {
            throw TransportError.channelClosed
        }

        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        try await task.send(.data(bytes))
        #else
        throw TransportError.unsupportedTransport("WebSocket streaming is not enabled on this runtime")
        #endif
    }

    public func receive() async throws -> Data {
        guard !closed else {
            throw TransportError.channelClosed
        }

        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        let message = try await task.receive()
        switch message {
        case let .data(data):
            return data
        case let .string(string):
            return Data(string.utf8)
        @unknown default:
            throw TransportError.noDataAvailable
        }
        #else
        throw TransportError.unsupportedTransport("WebSocket streaming is not enabled on this runtime")
        #endif
    }

    public func close() async {
        closed = true
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        task.cancel(with: .goingAway, reason: nil)
        #endif
    }
}
