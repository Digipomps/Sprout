import Foundation

public enum LocalKeyStoreError: Error, Equatable {
    case keyNotFound(String)
    case invalidPermissions
}

public actor LocalKeyStore {
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func writeKey(_ data: Data, named name: String) throws {
        try ensureRoot()
        let keyURL = root.appendingPathComponent(name)
        try data.write(to: keyURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    }

    public func readKey(named name: String) throws -> Data {
        let keyURL = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: keyURL.path) else {
            throw LocalKeyStoreError.keyNotFound(name)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        if let permissions = attributes[.posixPermissions] as? NSNumber {
            let mask = permissions.intValue & 0o077
            if mask != 0 {
                throw LocalKeyStoreError.invalidPermissions
            }
        }

        return try Data(contentsOf: keyURL)
    }

    private func ensureRoot() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
