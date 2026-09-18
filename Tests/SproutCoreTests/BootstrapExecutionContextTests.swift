import Foundation
import XCTest
@testable import SproutCore

final class BootstrapExecutionContextTests: XCTestCase {
    private func storedContext(extra: String = "") -> Data {
        Data("""
        {"runtime":"cliService","domain":"example.haven.local",
         "requestedPortholeKind":"cli","discoveredBridges":[]\(extra)}
        """.utf8)
    }

    func testLegacyStoredContextRestoresWithoutAddingRequestedAuthority() throws {
        let restored = try JSONDecoder().decode(
            BootstrapExecutionContext.self, from: storedContext()
        )
        XCTAssertEqual(restored.requestedCapabilities, [])
        XCTAssertNil(restored.capabilityDecision)
        XCTAssertNil(restored.portholeAccessContract)
        XCTAssertEqual(restored.domain, "example.haven.local")
        XCTAssertEqual(
            try JSONDecoder().decode(
                BootstrapExecutionContext.self, from: JSONEncoder().encode(restored)
            ), restored
        )
    }

    func testStoredRequestedCapabilitiesUseDeterministicSetSemantics() throws {
        let restored = try JSONDecoder().decode(
            BootstrapExecutionContext.self,
            from: storedContext(extra: ",\"requestedCapabilities\":[\"cap.z\",\"cap.a\",\"cap.z\"]")
        )
        XCTAssertEqual(restored.requestedCapabilities, ["cap.a", "cap.z"])
    }

    func testMalformedRequestedCapabilitiesFailClosed() {
        for malformed in ["null", "true", "1", "\"cap.join\"", "{}", "[1]", "[\"cap.join\",null]"] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    BootstrapExecutionContext.self,
                    from: storedContext(extra: ",\"requestedCapabilities\":\(malformed)")
                ), malformed
            )
        }
    }

    func testUnknownStoredFieldsDoNotGrantCapabilities() throws {
        let restored = try JSONDecoder().decode(
            BootstrapExecutionContext.self,
            from: storedContext(extra: ",\"futureField\":{\"admin\":true}")
        )
        XCTAssertEqual(restored.requestedCapabilities, [])
        XCTAssertNil(restored.capabilityDecision)
    }
}
