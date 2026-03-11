import XCTest
import Foundation
import SproutBridge
import SproutResolverAdapter
@testable import SproutCore

final class SchemaValidationTests: XCTestCase {
    private var rootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testStarterAuthVectorMatchesSchema() throws {
        try validate(vector: "TestVectors/starter_auth_payload.signed.json", schema: "Schemas/StarterAuthPayload.schema.json")
    }

    func testBridgeDescriptorVectorMatchesSchema() throws {
        try validate(vector: "TestVectors/bridge_descriptor.signed.json", schema: "Schemas/BridgeDescriptor.schema.json")
    }

    func testEntityLinkVectorMatchesSchema() throws {
        try validate(vector: "TestVectors/entity_link_contract.mutual.json", schema: "Schemas/EntityLinkContract.schema.json")
    }

    func testUpdateGrantPolicyVectorMatchesSchema() throws {
        try validate(vector: "TestVectors/update_grant_policy.example.json", schema: "Schemas/UpdateGrantPolicy.schema.json")
    }

    func testPortholeAccessContractVectorMatchesSchema() throws {
        try validate(vector: "TestVectors/porthole_access_contract.example.json", schema: "Schemas/PortholeAccessContract.schema.json")
    }

    func testCloudBridgePricingContractVectorMatchesSchema() throws {
        try validate(vector: "TestVectors/cloud_bridge_pricing_contract.example.json", schema: "Schemas/CloudBridgePricingContract.schema.json")
    }

    func testGeneratedEntityAnchorSnapshotMatchesSchema() throws {
        let snapshot = try ResolverFixtureFactory.makeSignedEntityAnchorSnapshot(
            identities: [
                EntityAnchorIdentityMember(
                    identity_public_key: "m2J3MyPvQaEYNIJBlOVRZNMl65zcwQ3dp9EK3k-9j20",
                    domain: "example.haven.local",
                    added_at: "2026-02-26T07:59:00Z"
                )
            ]
        )
        try validate(instance: snapshot, schema: "Schemas/EntityAnchorSnapshot.schema.json")
    }

    func testGeneratedScaffoldTrustRootDescriptorMatchesSchema() throws {
        let descriptor = try ResolverFixtureFactory.makeScaffoldTrustRootDescriptor()
        try validate(instance: descriptor, schema: "Schemas/ScaffoldAdminTrustRootDescriptor.schema.json")
    }

    func testGeneratedCrossScaffoldContinuityProofMatchesSchema() throws {
        let proof = try ResolverFixtureFactory.makeCrossScaffoldContinuityProof()
        try validate(instance: proof, schema: "Schemas/CrossScaffoldEntityContinuityProof.schema.json")
    }

    func testGeneratedEntityAdmissionRequestMatchesSchema() throws {
        let proof = try ResolverFixtureFactory.makeCrossScaffoldContinuityProof()
        let request = try ResolverFixtureFactory.makeEntityAdmissionRequest(continuityProof: proof)
        try validate(instance: request, schema: "Schemas/EntityAdmissionRequest.schema.json")
    }

    func testGeneratedEntityAdmissionContractMatchesSchema() throws {
        let proof = try ResolverFixtureFactory.makeCrossScaffoldContinuityProof()
        let request = try ResolverFixtureFactory.makeEntityAdmissionRequest(continuityProof: proof)
        let contract = try ResolverFixtureFactory.makeEntityAdmissionContract(
            continuityProof: proof,
            request: request
        )
        try validate(instance: contract, schema: "Schemas/EntityAdmissionContract.schema.json")
    }

    func testGeneratedEntityInclusionProofMatchesSchema() async throws {
        let snapshot = try ResolverFixtureFactory.makeSignedEntityAnchorSnapshot(
            identities: [
                EntityAnchorIdentityMember(
                    identity_public_key: "m2J3MyPvQaEYNIJBlOVRZNMl65zcwQ3dp9EK3k-9j20",
                    domain: "example.haven.local",
                    added_at: "2026-02-26T07:59:00Z"
                )
            ]
        )
        let adapter = EntityAnchorResolverAdapter(
            anchorSnapshot: snapshot,
            scenario: EntityAnchorResolverScenario(allowedDomains: ["example.haven.local"], requireFreshPayload: false),
            now: { ISO8601DateFormatter().date(from: "2026-02-26T08:01:00Z")! }
        )
        let decision = try await adapter.resolveEntity(
            EntityResolutionRequest(
                identity_public_key: "m2J3MyPvQaEYNIJBlOVRZNMl65zcwQ3dp9EK3k-9j20",
                domain: "example.haven.local",
                scaffold_admin_public_key: snapshot.admin_public_key,
                purpose: "bootstrap.join_scaffold",
                goal: "Join scaffold and register identity",
                interests: ["haven.core.bootstrap"],
                evidence: nil
            )
        )
        let proof = try XCTUnwrap(decision.inclusion_proof)
        try validate(instance: proof, schema: "Schemas/EntityInclusionProof.schema.json")
    }

    func testSchemaValidatorRejectsMissingRequiredProperty() throws {
        let schemaData = try Data(contentsOf: rootURL.appendingPathComponent("Schemas/StarterAuthPayload.schema.json"))
        let invalid = Data("{\"version\":\"1.0\"}".utf8)

        XCTAssertThrowsError(try JSONSchemaValidator.validate(instanceData: invalid, schemaData: schemaData))
    }

    private func validate(vector: String, schema: String) throws {
        let vectorData = try Data(contentsOf: rootURL.appendingPathComponent(vector))
        let schemaData = try Data(contentsOf: rootURL.appendingPathComponent(schema))
        try JSONSchemaValidator.validate(instanceData: vectorData, schemaData: schemaData)
    }

    private func validate<T: Encodable>(instance: T, schema: String) throws {
        let instanceData = try JSONEncoder().encode(instance)
        let schemaData = try Data(contentsOf: rootURL.appendingPathComponent(schema))
        try JSONSchemaValidator.validate(instanceData: instanceData, schemaData: schemaData)
    }

}
