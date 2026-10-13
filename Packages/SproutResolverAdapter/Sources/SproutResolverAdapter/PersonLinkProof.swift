import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Possession proof for an existing, human-approved Person Entity link.
/// This is not a new enrollment, a capability grant, or a general cell operation.
public struct PersonLinkProof: Codable, Equatable, Sendable {
    public var schema: String
    public var evidenceReference: String
    public var linkID: String
    public var challenge: Data
    public var signature: Data

    public init(evidenceReference: String, linkID: String, challenge: Data, signature: Data) {
        self.schema = "haven.person-entity-read-route-proof.v1"
        self.evidenceReference = evidenceReference
        self.linkID = linkID
        self.challenge = challenge
        self.signature = signature
    }
}

/// Reuses the resolver transport's receive-time limit and redirect rejection.
public enum PersonLinkHTTP {
    public static func data(for request: URLRequest, session: URLSession,
                            maximumBytes: Int = 65_536) async throws -> (Data, URLResponse) {
        try await session.boundedData(for: request, maximumBytes: maximumBytes)
    }
}
