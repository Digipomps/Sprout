import XCTest
import Foundation
import SproutResolverAdapter

final class PortholeAccessContractTests: XCTestCase {
    private var rootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testExampleVectorVerifiesSignatureAndExpiry() throws {
        let contract = try JSONDecoder().decode(
            PortholeAccessContract.self,
            from: Data(contentsOf: rootURL.appendingPathComponent("TestVectors/porthole_access_contract.example.json"))
        )

        let now = ISO8601DateFormatter().date(from: "2026-02-26T08:03:00Z")!
        XCTAssertTrue(try contract.verifySignature())
        XCTAssertFalse(contract.isExpired(now: now))
        XCTAssertEqual(contract.client_kind, .cli)
        XCTAssertEqual(contract.porthole_protocol, .cli)
        XCTAssertEqual(contract.entity_id, "entity_example_primary")
    }
}
