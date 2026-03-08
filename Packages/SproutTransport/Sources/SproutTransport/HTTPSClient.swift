import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPSTransportClient: TransportClient {
    public let kind: TransportKind = .https
    private let allowInsecureHTTP: Bool
    private let sessionConfiguration: URLSessionConfiguration

    public init(
        allowInsecureHTTP: Bool = false,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.allowInsecureHTTP = allowInsecureHTTP
        self.sessionConfiguration = sessionConfiguration
    }

    public func connect(endpoint: URL) async throws -> any Channel {
        guard let scheme = endpoint.scheme?.lowercased() else {
            throw TransportError.invalidEndpoint("Missing URL scheme")
        }

        switch scheme {
        case "https":
            return HTTPSChannel(endpoint: endpoint, session: URLSession(configuration: sessionConfiguration))
        case "http":
            if allowInsecureHTTP {
                return HTTPSChannel(endpoint: endpoint, session: URLSession(configuration: sessionConfiguration))
            }
            throw TransportError.insecureTransportNotAllowed("HTTP is disabled. Use HTTPS/TLS1.3.")
        default:
            throw TransportError.invalidEndpoint("HTTPS adapter received unsupported scheme: \(scheme)")
        }
    }
}

public actor HTTPSChannel: Channel {
    private let endpoint: URL
    private let session: URLSession
    private var pendingPayload: Data?
    private var closed = false

    init(endpoint: URL, session: URLSession) {
        self.endpoint = endpoint
        self.session = session
    }

    public func send(_ bytes: Data) async throws {
        guard !closed else {
            throw TransportError.channelClosed
        }
        pendingPayload = bytes
    }

    public func receive() async throws -> Data {
        guard !closed else {
            throw TransportError.channelClosed
        }
        guard let payload = pendingPayload else {
            throw TransportError.noPendingPayload
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TransportError.invalidEndpoint("Non-HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TransportError.invalidEndpoint("HTTP status \(httpResponse.statusCode)")
        }
        return data
    }

    public func close() async {
        closed = true
    }
}
