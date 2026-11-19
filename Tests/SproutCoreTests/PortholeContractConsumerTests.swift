import XCTest
import Foundation
import SproutCrypto
import SproutResolverAdapter
@testable import SproutCore

final class PortholeContractConsumerTests: XCTestCase {
    private var rootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testWebConsumerProducesBootstrapDescriptor() throws {
        let contract = try ResolverFixtureFactory.makePortholeAccessContract(
            clientKind: .web,
            protocolKind: .web
        )

        let descriptor = try PortholeContractConsumer.makeWebBootstrap(
            contract: contract,
            now: ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")!
        )

        XCTAssertEqual(descriptor.launch_url, "https://bridge.example.haven.local/browserhead/webo")
        XCTAssertEqual(descriptor.contract_id, contract.contract_id)
        XCTAssertEqual(descriptor.entity_id, contract.entity_id)

        let schemaData = try Data(contentsOf: rootURL.appendingPathComponent("Schemas/WebPortholeBootstrapDescriptor.schema.json"))
        let instanceData = try JSONEncoder().encode(descriptor)
        try JSONSchemaValidator.validate(instanceData: instanceData, schemaData: schemaData)
    }

    func testNativeConsumerProducesBindingDescriptor() throws {
        let contract = try ResolverFixtureFactory.makePortholeAccessContract(
            clientKind: .native,
            protocolKind: .cellprotocol
        )

        let descriptor = try PortholeContractConsumer.makeNativeBindingDescriptor(
            contract: contract,
            now: ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")!
        )

        XCTAssertEqual(descriptor.cell_endpoint, "cell://bridge.example.haven.local/Porthole")
        XCTAssertEqual(descriptor.bridge_endpoint, contract.bridge_endpoint)
        // No contract data in any URL: CellProtocol's channel-authenticated
        // endpoint rejects queries, and the contract travels in a POST body.
        XCTAssertEqual(descriptor.bridge_websocket_url, contract.bridge_endpoint)
        XCTAssertEqual(descriptor.contract_presentation_url, "https://bridge.example.haven.local/cell/contract")
        for url in [descriptor.bridge_websocket_url, descriptor.contract_presentation_url] {
            let components = try XCTUnwrap(URLComponents(string: url))
            XCTAssertNil(components.query)
            XCTAssertNil(components.fragment)
            XCTAssertFalse(url.contains(descriptor.contract_payload_b64url))
            XCTAssertFalse(url.contains(descriptor.contract_sha256_b64url))
            XCTAssertFalse(url.contains(contract.contract_id))
        }
        XCTAssertEqual(descriptor.identity_public_key, contract.identity_public_key)

        // The presentation body is the exact signed contract bytes plus hash.
        let presentation = descriptor.contractPresentation
        XCTAssertEqual(presentation.contract_id, contract.contract_id)
        let payload = try Base64URL.decode(presentation.contract_payload_b64url)
        XCTAssertEqual(Hashing.sha256Base64URL(payload), presentation.contract_sha256_b64url)
        let decoded = try JSONDecoder().decode(PortholeAccessContract.self, from: payload)
        XCTAssertEqual(decoded, contract)
        XCTAssertTrue(try decoded.verifySignature())

        let schemaData = try Data(contentsOf: rootURL.appendingPathComponent("Schemas/NativePortholeBindingDescriptor.schema.json"))
        let instanceData = try JSONEncoder().encode(descriptor)
        try JSONSchemaValidator.validate(instanceData: instanceData, schemaData: schemaData)
    }

    func testNativeLoopbackBridgeEndpointPresentsOverLoopbackHTTP() throws {
        let contract = try ResolverFixtureFactory.makePortholeAccessContract(
            clientKind: .native,
            protocolKind: .cellprotocol,
            bridgeEndpoint: "ws://127.0.0.1:8080/v1/resolver/native-porthole/Porthole/"
        )
        let descriptor = try PortholeContractConsumer.makeNativeBindingDescriptor(
            contract: contract,
            now: ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")!
        )
        XCTAssertEqual(descriptor.bridge_websocket_url, contract.bridge_endpoint)
        XCTAssertEqual(descriptor.contract_presentation_url, "http://127.0.0.1:8080/v1/resolver/native-porthole/Porthole/contract")
    }

    func testNativeConsumerRejectsBridgeEndpointThatCarriesQueryFragmentOrUserInfo() throws {
        for endpoint in [
            "wss://bridge.example.haven.local/cell?contract_id=pac_fixture_0001",
            "wss://bridge.example.haven.local/cell#fragment",
            "wss://user:secret@bridge.example.haven.local/cell",
            "https://bridge.example.haven.local/cell"
        ] {
            let contract = try ResolverFixtureFactory.makePortholeAccessContract(
                clientKind: .native,
                protocolKind: .cellprotocol,
                bridgeEndpoint: endpoint
            )
            XCTAssertThrowsError(
                try PortholeContractConsumer.makeNativeBindingDescriptor(
                    contract: contract,
                    now: ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")!
                ),
                endpoint
            ) { error in
                XCTAssertEqual(error as? PortholeContractConsumerError, .invalidBridgeEndpoint, endpoint)
            }
        }
    }

    func testNativeDescriptorSchemaRejectsContractDataInWebSocketURL() throws {
        let contract = try ResolverFixtureFactory.makePortholeAccessContract(
            clientKind: .native,
            protocolKind: .cellprotocol
        )
        var descriptor = try PortholeContractConsumer.makeNativeBindingDescriptor(
            contract: contract,
            now: ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")!
        )
        descriptor.bridge_websocket_url += "?contract_payload_b64url=" + descriptor.contract_payload_b64url
        let schemaData = try Data(contentsOf: rootURL.appendingPathComponent("Schemas/NativePortholeBindingDescriptor.schema.json"))
        XCTAssertThrowsError(try JSONSchemaValidator.validate(instanceData: JSONEncoder().encode(descriptor), schemaData: schemaData)) { error in
            XCTAssertEqual(error as? JSONSchemaValidationError, .patternMismatch(path: "$.bridge_websocket_url"))
        }
    }

    func testConsumerRejectsWrongClientKind() throws {
        let contract = try ResolverFixtureFactory.makePortholeAccessContract(
            clientKind: .cli,
            protocolKind: .cli
        )

        XCTAssertThrowsError(
            try PortholeContractConsumer.makeWebBootstrap(
                contract: contract,
                now: ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")!
            )
        )
    }

    // MARK: CellProtocol conformance (R8)

    private struct EndpointVectors: Decodable {
        struct Vector: Decodable {
            let endpoint: String
            let expected_valid: Bool
            let note: String
        }
        let vectors: [Vector]
    }

    /// Expected results are CellProtocol's `BridgeChannelAuthentication.Endpoint`
    /// on endpoint + "/" + UUID. `validateNativeBridgeEndpoint` calls that type
    /// directly (R9), so this runs the vectors through CellProtocol itself.
    func testNativeBridgeEndpointValidationMatchesCellProtocolVectors() throws {
        let data = try Data(contentsOf: rootURL.appendingPathComponent("TestVectors/native_bridge_endpoint.cellprotocol.json"))
        let vectors = try JSONDecoder().decode(EndpointVectors.self, from: data).vectors
        XCTAssertGreaterThanOrEqual(vectors.count, 20)
        for vector in vectors {
            let valid = (try? PortholeContractConsumer.validateNativeBridgeEndpoint(vector.endpoint)) != nil
            XCTAssertEqual(valid, vector.expected_valid, "\(vector.note): \(vector.endpoint)")
        }
    }

    func testNativeConsumerRefusesEndpointsCellProtocolRejects() throws {
        let data = try Data(contentsOf: rootURL.appendingPathComponent("TestVectors/native_bridge_endpoint.cellprotocol.json"))
        let vectors = try JSONDecoder().decode(EndpointVectors.self, from: data).vectors
        let now = ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")!
        let schemaData = try Data(contentsOf: rootURL.appendingPathComponent("Schemas/NativePortholeBindingDescriptor.schema.json"))
        for vector in vectors {
            let contract = try ResolverFixtureFactory.makePortholeAccessContract(
                clientKind: .native,
                protocolKind: .cellprotocol,
                bridgeEndpoint: vector.endpoint
            )
            if vector.expected_valid {
                let descriptor = try PortholeContractConsumer.makeNativeBindingDescriptor(contract: contract, now: now)
                XCTAssertEqual(descriptor.bridge_websocket_url, vector.endpoint, vector.note)
                try JSONSchemaValidator.validate(instanceData: JSONEncoder().encode(descriptor), schemaData: schemaData)
            } else {
                XCTAssertThrowsError(try PortholeContractConsumer.makeNativeBindingDescriptor(contract: contract, now: now), vector.note)
            }
        }
    }

    func testNativeCellEndpointUsesCellProtocolAddressForm() throws {
        let now = ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")!
        for (endpoint, expected) in [
            ("wss://bridge.example.haven.local:8443/cell", "cell://bridge.example.haven.local/Porthole"),
            ("ws://[::1]:9000/bridge", "cell://[::1]/Porthole"),
            ("ws://127.0.0.1:8080/v1/resolver/native-porthole/Porthole/", "cell://127.0.0.1/Porthole")
        ] {
            let contract = try ResolverFixtureFactory.makePortholeAccessContract(
                clientKind: .native,
                protocolKind: .cellprotocol,
                bridgeEndpoint: endpoint
            )
            let descriptor = try PortholeContractConsumer.makeNativeBindingDescriptor(contract: contract, now: now)
            XCTAssertEqual(descriptor.cell_endpoint, expected, endpoint)
            let url = try XCTUnwrap(URL(string: descriptor.cell_endpoint))
            XCTAssertEqual(url.scheme, "cell")
            XCTAssertEqual(url.path, "/Porthole")
        }
    }

    func testNativeDescriptorSchemaRejectsBridgeURLOverCellProtocolLimit() throws {
        let contract = try ResolverFixtureFactory.makePortholeAccessContract(
            clientKind: .native,
            protocolKind: .cellprotocol
        )
        var descriptor = try PortholeContractConsumer.makeNativeBindingDescriptor(
            contract: contract,
            now: ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")!
        )
        descriptor.bridge_websocket_url = "wss://h.example/" + String(repeating: "a", count: 476)
        let schemaData = try Data(contentsOf: rootURL.appendingPathComponent("Schemas/NativePortholeBindingDescriptor.schema.json"))
        XCTAssertThrowsError(try JSONSchemaValidator.validate(instanceData: JSONEncoder().encode(descriptor), schemaData: schemaData)) { error in
            XCTAssertEqual(error as? JSONSchemaValidationError, .stringTooLong(path: "$.bridge_websocket_url", maxLength: 476))
        }
    }
}
