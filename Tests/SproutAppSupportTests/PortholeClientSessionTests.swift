import Foundation
import SproutAppSupport
import SproutCrypto
import SproutResolverAdapter
import XCTest

final class PortholeClientSessionTests: XCTestCase {
    func testWebSessionProducesURLRequestWithContractHeaders() throws {
        let contract = try makeContract(clientKind: .web, protocolKind: .web)
        let session = try PortholeClientSession.fromContract(
            contract,
            now: ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")!
        )

        XCTAssertEqual(session.mode, .web)
        let request = try session.makeWebURLRequest()
        XCTAssertEqual(request.url?.absoluteString, "https://bridge.example.haven.local/browserhead/webo")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sprout-Porthole-Contract-Id"), contract.contract_id)
    }

    func testNativeSessionProducesDescriptorJSON() throws {
        let contract = try makeContract(clientKind: .native, protocolKind: .cellprotocol)
        let session = try PortholeClientSession.fromContract(
            contract,
            now: ISO8601DateFormatter().date(from: "2026-02-26T08:02:00Z")!
        )

        XCTAssertEqual(session.mode, .native)
        XCTAssertEqual(session.nativeDescriptor?.cell_endpoint, "cell://bridge.example.haven.local/Porthole")
        XCTAssertTrue(session.nativeDescriptor?.bridge_websocket_url.contains("contract_payload_b64url=") == true)
        XCTAssertTrue(session.nativeDescriptor?.bridge_websocket_url.contains("contract_sha256_b64url=") == true)
        let descriptorJSON = try session.nativeDescriptorJSON()
        XCTAssertTrue(descriptorJSON.contains("\"bridge_endpoint\""))
        XCTAssertTrue(descriptorJSON.contains("\"bridge_websocket_url\""))
    }

    func testCLISessionIsExplicitlyUnsupportedForMacClient() throws {
        let contract = try makeContract(clientKind: .cli, protocolKind: .cli)
        let session = try PortholeClientSession.fromContract(contract)

        XCTAssertEqual(session.mode, .unsupported)
        XCTAssertThrowsError(try session.makeWebURLRequest())
    }

    private func makeContract(
        clientKind: PortholeClientKind,
        protocolKind: PortholeProtocolKind
    ) throws -> PortholeAccessContract {
        let seed = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        let publicKey = try Ed25519.publicKeyBase64URL(fromSeedBase64URL: seed)

        var contract = PortholeAccessContract(
            contract_id: "pac_support_0001",
            scaffold_domain: "example.haven.local",
            entity_id: "entity_example_primary",
            identity_public_key: "m2J3MyPvQaEYNIJBlOVRZNMl65zcwQ3dp9EK3k-9j20",
            scaffold_admin_public_key: publicKey,
            bridge_descriptor_id: "bd_anchor_0001",
            bridge_endpoint: "wss://bridge.example.haven.local/cell",
            client_kind: clientKind,
            porthole_protocol: protocolKind,
            capability_grants: ["cap.join", "cap.discover"],
            purpose: "bootstrap.join_scaffold",
            goal: "Join scaffold and register identity",
            interests: ["haven.core.bootstrap", "haven.core.bridge"],
            issued_at: "2026-02-26T08:01:00Z",
            expires_at: "2026-02-26T08:06:00Z",
            issued_by: publicKey,
            entity_evidence_contract_id: nil,
            signature: ResolverSignatureEnvelope(alg: "Ed25519", sig: "")
        )
        contract.signature = ResolverSignatureEnvelope(
            alg: "Ed25519",
            sig: try Ed25519.signBase64URL(data: try contract.canonicalPayloadData(), seedBase64URL: seed)
        )
        return contract
    }
}
