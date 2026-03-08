import Foundation
import SproutCrypto
import SproutResolverAdapter

public enum PortholeContractConsumerError: Error, Equatable, Sendable {
    case invalidSignature
    case expiredContract
    case invalidBridgeEndpoint
    case missingHost
    case clientKindMismatch(expected: PortholeClientKind, actual: PortholeClientKind)
    case protocolMismatch(expected: PortholeProtocolKind, actual: PortholeProtocolKind)
}

public struct WebPortholeBootstrapDescriptor: Codable, Equatable, Sendable {
    public var launch_url: String
    public var contract_id: String
    public var contract_payload_b64url: String
    public var contract_sha256_b64url: String
    public var scaffold_domain: String
    public var entity_id: String
    public var identity_public_key: String
    public var headers: [String: String]
    public var expires_at: String

    public init(
        launch_url: String,
        contract_id: String,
        contract_payload_b64url: String,
        contract_sha256_b64url: String,
        scaffold_domain: String,
        entity_id: String,
        identity_public_key: String,
        headers: [String: String],
        expires_at: String
    ) {
        self.launch_url = launch_url
        self.contract_id = contract_id
        self.contract_payload_b64url = contract_payload_b64url
        self.contract_sha256_b64url = contract_sha256_b64url
        self.scaffold_domain = scaffold_domain
        self.entity_id = entity_id
        self.identity_public_key = identity_public_key
        self.headers = headers
        self.expires_at = expires_at
    }
}

public struct NativePortholeBindingDescriptor: Codable, Equatable, Sendable {
    public var bridge_endpoint: String
    public var bridge_websocket_url: String
    public var cell_endpoint: String
    public var contract_id: String
    public var contract_payload_b64url: String
    public var contract_sha256_b64url: String
    public var scaffold_domain: String
    public var entity_id: String
    public var identity_public_key: String
    public var scaffold_admin_public_key: String
    public var capability_grants: [String]
    public var expires_at: String

    public init(
        bridge_endpoint: String,
        bridge_websocket_url: String,
        cell_endpoint: String,
        contract_id: String,
        contract_payload_b64url: String,
        contract_sha256_b64url: String,
        scaffold_domain: String,
        entity_id: String,
        identity_public_key: String,
        scaffold_admin_public_key: String,
        capability_grants: [String],
        expires_at: String
    ) {
        self.bridge_endpoint = bridge_endpoint
        self.bridge_websocket_url = bridge_websocket_url
        self.cell_endpoint = cell_endpoint
        self.contract_id = contract_id
        self.contract_payload_b64url = contract_payload_b64url
        self.contract_sha256_b64url = contract_sha256_b64url
        self.scaffold_domain = scaffold_domain
        self.entity_id = entity_id
        self.identity_public_key = identity_public_key
        self.scaffold_admin_public_key = scaffold_admin_public_key
        self.capability_grants = capability_grants
        self.expires_at = expires_at
    }
}

public enum PortholeContractConsumer {
    public static func makeWebBootstrap(
        contract: PortholeAccessContract,
        now: Date = Date()
    ) throws -> WebPortholeBootstrapDescriptor {
        try validate(contract: contract, expectedKind: .web, expectedProtocol: .web, now: now)

        guard var components = URLComponents(string: contract.bridge_endpoint) else {
            throw PortholeContractConsumerError.invalidBridgeEndpoint
        }
        guard let host = components.host, !host.isEmpty else {
            throw PortholeContractConsumerError.missingHost
        }

        components.scheme = components.scheme == "wss" ? "https" : "https"
        components.host = host
        components.path = "/browserhead/webo"
        components.query = nil

        let contractData = try JSONEncoder.sorted.encode(contract)
        let payloadB64URL = Base64URL.encode(contractData)
        let payloadHash = Hashing.sha256Base64URL(contractData)

        return WebPortholeBootstrapDescriptor(
            launch_url: components.string ?? "https://\(host)/browserhead/webo",
            contract_id: contract.contract_id,
            contract_payload_b64url: payloadB64URL,
            contract_sha256_b64url: payloadHash,
            scaffold_domain: contract.scaffold_domain,
            entity_id: contract.entity_id,
            identity_public_key: contract.identity_public_key,
            headers: [
                "X-Sprout-Porthole-Contract-Id": contract.contract_id,
                "X-Sprout-Porthole-Contract-SHA256": payloadHash,
                "X-Sprout-Porthole-Entity-Id": contract.entity_id
            ],
            expires_at: contract.expires_at
        )
    }

    public static func makeNativeBindingDescriptor(
        contract: PortholeAccessContract,
        now: Date = Date()
    ) throws -> NativePortholeBindingDescriptor {
        try validate(contract: contract, expectedKind: .native, expectedProtocol: .cellprotocol, now: now)

        guard let url = URL(string: contract.bridge_endpoint) else {
            throw PortholeContractConsumerError.invalidBridgeEndpoint
        }
        guard let host = url.host, !host.isEmpty else {
            throw PortholeContractConsumerError.missingHost
        }

        let contractData = try JSONEncoder.sorted.encode(contract)
        let payloadB64URL = Base64URL.encode(contractData)
        let payloadHash = Hashing.sha256Base64URL(contractData)
        let websocketURL = try nativeWebSocketURL(
            from: contract.bridge_endpoint,
            contractID: contract.contract_id,
            payloadB64URL: payloadB64URL,
            payloadHash: payloadHash
        )

        return NativePortholeBindingDescriptor(
            bridge_endpoint: contract.bridge_endpoint,
            bridge_websocket_url: websocketURL,
            cell_endpoint: "cell://\(host)/Porthole",
            contract_id: contract.contract_id,
            contract_payload_b64url: payloadB64URL,
            contract_sha256_b64url: payloadHash,
            scaffold_domain: contract.scaffold_domain,
            entity_id: contract.entity_id,
            identity_public_key: contract.identity_public_key,
            scaffold_admin_public_key: contract.scaffold_admin_public_key,
            capability_grants: contract.capability_grants.sorted(),
            expires_at: contract.expires_at
        )
    }

    private static func validate(
        contract: PortholeAccessContract,
        expectedKind: PortholeClientKind,
        expectedProtocol: PortholeProtocolKind,
        now: Date
    ) throws {
        guard try contract.verifySignature() else {
            throw PortholeContractConsumerError.invalidSignature
        }
        guard !contract.isExpired(now: now) else {
            throw PortholeContractConsumerError.expiredContract
        }
        guard contract.client_kind == expectedKind else {
            throw PortholeContractConsumerError.clientKindMismatch(
                expected: expectedKind,
                actual: contract.client_kind
            )
        }
        guard contract.porthole_protocol == expectedProtocol else {
            throw PortholeContractConsumerError.protocolMismatch(
                expected: expectedProtocol,
                actual: contract.porthole_protocol
            )
        }
        guard URL(string: contract.bridge_endpoint) != nil else {
            throw PortholeContractConsumerError.invalidBridgeEndpoint
        }
    }

    private static func nativeWebSocketURL(
        from baseEndpoint: String,
        contractID: String,
        payloadB64URL: String,
        payloadHash: String
    ) throws -> String {
        guard var components = URLComponents(string: baseEndpoint) else {
            throw PortholeContractConsumerError.invalidBridgeEndpoint
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "contract_id", value: contractID))
        queryItems.append(URLQueryItem(name: "contract_payload_b64url", value: payloadB64URL))
        queryItems.append(URLQueryItem(name: "contract_sha256_b64url", value: payloadHash))
        components.queryItems = queryItems.sorted { $0.name < $1.name }

        guard let url = components.url else {
            throw PortholeContractConsumerError.invalidBridgeEndpoint
        }
        return url.absoluteString
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
