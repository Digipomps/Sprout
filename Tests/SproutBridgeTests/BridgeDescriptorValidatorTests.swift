import XCTest
@testable import SproutBridge

final class BridgeDescriptorValidatorTests: XCTestCase {
    private var rootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var validNow: Date {
        ISO8601DateFormatter().date(from: "2026-02-26T08:30:00Z")!
    }

    func testValidDescriptorPasses() throws {
        let descriptor = try loadDescriptor()
        let context = BridgeDescriptorValidationContext(
            expectedDomain: "example.haven.local",
            requiredPurpose: "bootstrap.join_scaffold",
            now: validNow
        )

        XCTAssertNoThrow(try BridgeDescriptorValidator().validate(descriptor: descriptor, context: context))
    }

    func testWrongDomainFails() throws {
        let descriptor = try loadDescriptor()
        let context = BridgeDescriptorValidationContext(
            expectedDomain: "other.haven.local",
            requiredPurpose: "bootstrap.join_scaffold",
            now: validNow
        )

        XCTAssertThrowsError(try BridgeDescriptorValidator().validate(descriptor: descriptor, context: context)) { error in
            guard case .wrongDomain = error as? BridgeDescriptorValidationError else {
                return XCTFail("expected wrongDomain")
            }
        }
    }

    func testExpiredFails() throws {
        let descriptor = try loadDescriptor()
        let context = BridgeDescriptorValidationContext(
            expectedDomain: "example.haven.local",
            requiredPurpose: "bootstrap.join_scaffold",
            now: ISO8601DateFormatter().date(from: "2026-02-26T09:01:00Z")!
        )

        XCTAssertThrowsError(try BridgeDescriptorValidator().validate(descriptor: descriptor, context: context)) { error in
            XCTAssertEqual(error as? BridgeDescriptorValidationError, .expired)
        }
    }

    func testSignatureFailureFails() throws {
        var descriptor = try loadDescriptor()
        descriptor.signature.sig = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

        let context = BridgeDescriptorValidationContext(
            expectedDomain: "example.haven.local",
            requiredPurpose: "bootstrap.join_scaffold",
            now: validNow
        )

        XCTAssertThrowsError(try BridgeDescriptorValidator().validate(descriptor: descriptor, context: context)) { error in
            XCTAssertEqual(error as? BridgeDescriptorValidationError, .signatureInvalid)
        }
    }

    private func loadDescriptor() throws -> BridgeDescriptor {
        let data = try Data(contentsOf: rootURL.appendingPathComponent("TestVectors/bridge_descriptor.signed.json"))
        return try JSONDecoder().decode(BridgeDescriptor.self, from: data)
    }
}
