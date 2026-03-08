import Foundation

public actor MockChannel: Channel {
    private var queuedResponses: [Data]
    private var sentPayloads: [Data] = []
    private var closed = false

    public init(queuedResponses: [Data] = []) {
        self.queuedResponses = queuedResponses
    }

    public func send(_ bytes: Data) async throws {
        guard !closed else {
            throw TransportError.channelClosed
        }
        sentPayloads.append(bytes)
    }

    public func receive() async throws -> Data {
        guard !closed else {
            throw TransportError.channelClosed
        }
        guard !queuedResponses.isEmpty else {
            throw TransportError.noDataAvailable
        }
        return queuedResponses.removeFirst()
    }

    public func close() async {
        closed = true
    }

    public func observedSentPayloads() -> [Data] {
        sentPayloads
    }
}

public struct MockTransportClient: TransportClient {
    public let kind: TransportKind
    private let channelFactory: @Sendable (URL) throws -> MockChannel

    public init(kind: TransportKind = .https, channelFactory: @escaping @Sendable (URL) throws -> MockChannel) {
        self.kind = kind
        self.channelFactory = channelFactory
    }

    public func connect(endpoint: URL) async throws -> any Channel {
        try channelFactory(endpoint)
    }
}
