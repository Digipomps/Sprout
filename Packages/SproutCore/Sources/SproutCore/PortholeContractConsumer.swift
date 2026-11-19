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

/// Body of `POST contract_presentation_url`. The contract travels in an HTTPS
/// request body, never in a URL: CellProtocol's channel-authenticated bridge
/// endpoint rejects any query, and URLs end up in logs. The server stores the
/// verified contract keyed by `identity_public_key`; the WebSocket upgrade then
/// finds it through the channel-authenticated principal, not through anything
/// in the upgrade request.
public struct NativePortholeContractPresentation: Codable, Equatable, Sendable {
    public var contract_id: String
    public var contract_payload_b64url: String
    public var contract_sha256_b64url: String

    public init(contract_id: String, contract_payload_b64url: String, contract_sha256_b64url: String) {
        self.contract_id = contract_id
        self.contract_payload_b64url = contract_payload_b64url
        self.contract_sha256_b64url = contract_sha256_b64url
    }
}

public struct NativePortholeBindingDescriptor: Codable, Equatable, Sendable {
    public var bridge_endpoint: String
    /// Equal to `bridge_endpoint`; carries no query, fragment or user info.
    public var bridge_websocket_url: String
    /// HTTPS (HTTP only for loopback) URL that receives the contract before the
    /// bridge is opened. Derived from `bridge_endpoint` + `/contract`.
    public var contract_presentation_url: String
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
        contract_presentation_url: String,
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
        self.contract_presentation_url = contract_presentation_url
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

    public var contractPresentation: NativePortholeContractPresentation {
        NativePortholeContractPresentation(
            contract_id: contract_id,
            contract_payload_b64url: contract_payload_b64url,
            contract_sha256_b64url: contract_sha256_b64url
        )
    }
}

public enum PortholeContractConsumer {
    /// Path segment appended to `bridge_endpoint` for contract presentation.
    public static let nativeContractPresentationPathSuffix = "contract"

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
        let endpoints = try nativeEndpoints(from: contract.bridge_endpoint)

        return NativePortholeBindingDescriptor(
            bridge_endpoint: contract.bridge_endpoint,
            bridge_websocket_url: endpoints.websocket,
            contract_presentation_url: endpoints.presentation,
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

    /// The WebSocket URL is the bridge endpoint itself: no contract data, no
    /// query. CellProtocol's `BridgeChannelAuthentication.Endpoint` rejects any
    /// query, fragment or user info, so such a bridge endpoint is refused here.
    private static func nativeEndpoints(from baseEndpoint: String) throws -> (websocket: String, presentation: String) {
        guard let components = URLComponents(string: baseEndpoint),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil else {
            throw PortholeContractConsumerError.invalidBridgeEndpoint
        }
        var presentation = components
        switch scheme {
        case "wss": presentation.scheme = "https"
        case "ws": presentation.scheme = "http"
        default: throw PortholeContractConsumerError.invalidBridgeEndpoint
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        presentation.path = path + "/" + nativeContractPresentationPathSuffix
        guard let websocketURL = components.url, let presentationURL = presentation.url else {
            throw PortholeContractConsumerError.invalidBridgeEndpoint
        }
        return (websocketURL.absoluteString, presentationURL.absoluteString)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
