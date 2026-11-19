// Runs only in the CellProtocol runtime build:
//   swift test -Xswiftc -DSPROUT_ENABLE_CELLPROTOCOL_RUNTIME --filter NativePortholeBindingRuntimeCellProtocolTests
// (CI job `cellprotocol-runtime`). The default build does not compile
// NativePortholeBindingRuntime, so there is nothing to test there.
#if SPROUT_ENABLE_CELLPROTOCOL_RUNTIME && canImport(CellBase) && canImport(CellApple)
import Foundation
@preconcurrency import CellBase
import SproutCore
import SproutCrypto
@testable import SproutAppSupport
import XCTest

@MainActor
final class NativePortholeBindingRuntimeCellProtocolTests: XCTestCase {
    private let seedA = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    private let seedB = "HyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4"

    func testBridgeEndpointIsCheckedWithCellProtocolsEndpoint() throws {
        XCTAssertNoThrow(try NativePortholeBindingRuntime.validateBridgeEndpoint("wss://bridge.example.haven.local/cell"))
        for rejected in [
            "https://bridge.example.haven.local/cell",   // not ws/wss
            "wss://bridge.example.haven.local:443/cell", // default port
            "wss://Bridge.example.haven.local/cell",     // upper-case host
            "wss://bridge.example.haven.local/a/../cell",
            "ws://bridge.example.haven.local/cell"       // plain ws off loopback
        ] {
            XCTAssertThrowsError(try NativePortholeBindingRuntime.validateBridgeEndpoint(rejected), rejected)
        }
    }

    func testLoopbackWebSocketFollowsCellProtocolPolicy() {
        let endpoint = "ws://127.0.0.1:8080/bridge"
        if CellBase.allowsInsecureWebSocket(toHost: "127.0.0.1") {
            XCTAssertNoThrow(try NativePortholeBindingRuntime.validateBridgeEndpoint(endpoint))
        } else {
            XCTAssertThrowsError(try NativePortholeBindingRuntime.validateBridgeEndpoint(endpoint))
        }
    }

    func testRequesterMustHoldTheContractsIdentityKey() throws {
        let descriptor = try makeDescriptor(identityKey: Ed25519.publicKeyBase64URL(fromSeedBase64URL: seedA))
        XCTAssertNoThrow(try NativePortholeBindingRuntime.validateRequester(try identity(seed: seedA), matches: descriptor))
        XCTAssertThrowsError(try NativePortholeBindingRuntime.validateRequester(try identity(seed: seedB), matches: descriptor)) {
            XCTAssertEqual($0 as? NativePortholeBindingRuntimeError, .identityMismatch)
        }
    }

    /// An Identity with only a public Ed25519 key, built the way CellProtocol
    /// rebuilds a channel peer (`PublicIdentity.makeIdentity()`).
    private func identity(seed: String) throws -> Identity {
        let raw = try SproutCrypto.Base64URL.decode(Ed25519.publicKeyBase64URL(fromSeedBase64URL: seed))
        let json = """
        {"uuid":"requester-\(seed.prefix(4))","algorithm":"EdDSA","curve":"Curve25519","publicKey":"\(raw.base64EncodedString())"}
        """
        let publicIdentity = try JSONDecoder().decode(BridgeChannelAuthentication.PublicIdentity.self, from: Data(json.utf8))
        return publicIdentity.makeIdentity()
    }

    private func makeDescriptor(identityKey: String) throws -> NativePortholeBindingDescriptor {
        NativePortholeBindingDescriptor(
            bridge_endpoint: "wss://bridge.example.haven.local/cell",
            bridge_websocket_url: "wss://bridge.example.haven.local/cell",
            contract_presentation_url: "https://bridge.example.haven.local/cell/contract",
            cell_endpoint: "cell://bridge.example.haven.local/Porthole",
            contract_id: "pac_runtime_0001",
            contract_payload_b64url: "",
            contract_sha256_b64url: "",
            scaffold_domain: "example.haven.local",
            entity_id: "entity_example_primary",
            identity_public_key: identityKey,
            scaffold_admin_public_key: identityKey,
            capability_grants: ["cap.join"],
            expires_at: "2026-02-26T08:06:00Z"
        )
    }
}
#endif
