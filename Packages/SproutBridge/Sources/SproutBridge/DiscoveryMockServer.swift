import Foundation

public actor BridgeDiscoveryMockServer {
    private let descriptors: [BridgeDescriptor]

    public init(descriptors: [BridgeDescriptor]) {
        self.descriptors = descriptors
    }

    public func query(_ request: BridgeDiscoveryQuery) -> BridgeDiscoveryResponse {
        let filtered = descriptors.filter { descriptor in
            descriptor.scaffold_domain == request.scaffold_domain &&
                descriptor.purpose_constraints.contains(request.purpose)
        }
        return BridgeDiscoveryResponse(bridges: filtered)
    }
}

public struct BridgeDiscoveryMockClient: BridgeDiscoveryService {
    private let server: BridgeDiscoveryMockServer

    public init(server: BridgeDiscoveryMockServer) {
        self.server = server
    }

    public func queryBridges(_ query: BridgeDiscoveryQuery) async throws -> [BridgeDescriptor] {
        await server.query(query).bridges
    }
}
