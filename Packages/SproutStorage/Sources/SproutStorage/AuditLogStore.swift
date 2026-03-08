import Foundation
import SproutCrypto

public struct AuditEvent: Codable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var eventType: String
    public var state: String
    public var payloadSHA256: String
    public var details: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        eventType: String,
        state: String,
        payloadSHA256: String,
        details: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.eventType = eventType
        self.state = state
        self.payloadSHA256 = payloadSHA256
        self.details = details
    }
}

public actor AuditLogStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func append(eventType: String, state: String, payload: Data, details: String) throws {
        let hash = Hashing.sha256Base64URL(payload)
        let event = AuditEvent(
            eventType: eventType,
            state: state,
            payloadSHA256: hash,
            details: details
        )
        try append(event: event)
    }

    public func append(event: AuditEvent) throws {
        let eventData = try encoder.encode(event)
        let line = eventData + Data("\n".utf8)

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func readAll() throws -> [AuditEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
            return []
        }

        return try data
            .split(separator: UInt8(ascii: "\n"))
            .map { try decoder.decode(AuditEvent.self, from: Data($0)) }
    }
}
