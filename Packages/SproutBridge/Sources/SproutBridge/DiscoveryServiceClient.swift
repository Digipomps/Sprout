import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SproutTransport

public struct BridgeDiscoveryQuery: Codable, Equatable, Sendable {
    public var scaffold_domain: String
    public var purpose: String
    public var interests: [String]

    public init(scaffold_domain: String, purpose: String, interests: [String]) {
        self.scaffold_domain = scaffold_domain
        self.purpose = purpose
        self.interests = interests
    }
}

public struct BridgeDiscoveryResponse: Codable, Equatable, Sendable {
    public var bridges: [BridgeDescriptor]

    public init(bridges: [BridgeDescriptor]) {
        self.bridges = bridges
    }
}

public protocol BridgeDiscoveryService: Sendable {
    func queryBridges(_ query: BridgeDiscoveryQuery) async throws -> [BridgeDescriptor]
}

public struct BridgeDiscoveryHTTPClient: BridgeDiscoveryService {
    private let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func queryBridges(_ query: BridgeDiscoveryQuery) async throws -> [BridgeDescriptor] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(query)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw TransportError.invalidEndpoint("Discovery query failed")
        }

        return try JSONDecoder().decode(BridgeDiscoveryResponse.self, from: data).bridges
    }
}

public struct OfflineBridgeDiscoveryService: BridgeDiscoveryService {
    private let descriptors: [BridgeDescriptor]

    public init(descriptors: [BridgeDescriptor]) {
        self.descriptors = descriptors
    }

    public func queryBridges(_ query: BridgeDiscoveryQuery) async throws -> [BridgeDescriptor] {
        descriptors.filter { descriptor in
            descriptor.scaffold_domain == query.scaffold_domain &&
                descriptor.purpose_constraints.contains(query.purpose)
        }
    }
}
