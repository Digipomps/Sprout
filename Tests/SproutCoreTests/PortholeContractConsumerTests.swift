import XCTest
import Foundation
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
        XCTAssertTrue(descriptor.bridge_websocket_url.hasPrefix(contract.bridge_endpoint + "?"))
        XCTAssertTrue(descriptor.bridge_websocket_url.contains("contract_id=" + contract.contract_id))
        XCTAssertTrue(descriptor.bridge_websocket_url.contains("contract_payload_b64url="))
        XCTAssertTrue(descriptor.bridge_websocket_url.contains("contract_sha256_b64url="))
        XCTAssertEqual(descriptor.identity_public_key, contract.identity_public_key)

        let schemaData = try Data(contentsOf: rootURL.appendingPathComponent("Schemas/NativePortholeBindingDescriptor.schema.json"))
        let instanceData = try JSONEncoder().encode(descriptor)
        try JSONSchemaValidator.validate(instanceData: instanceData, schemaData: schemaData)
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
}
