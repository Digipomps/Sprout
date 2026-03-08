import Foundation

public enum BridgeManagerError: Error, Equatable, Sendable {
    case invalidCatalog
    case noMatchingBridge
}

public struct BridgeCatalog: Codable, Equatable, Sendable {
    public var bridges: [BridgeDescriptor]

    public init(bridges: [BridgeDescriptor]) {
        self.bridges = bridges
    }
}

public struct BridgeManager: Sendable {
    private let validator: BridgeDescriptorValidator

    public init(validator: BridgeDescriptorValidator = .init()) {
        self.validator = validator
    }

    public func loadCatalog(from fileURL: URL) throws -> [BridgeDescriptor] {
        let data = try Data(contentsOf: fileURL)

        if let catalog = try? JSONDecoder.plain.decode(BridgeCatalog.self, from: data) {
            return catalog.bridges
        }
        if let list = try? JSONDecoder.plain.decode([BridgeDescriptor].self, from: data) {
            return list
        }
        if let single = try? JSONDecoder.plain.decode(BridgeDescriptor.self, from: data) {
            return [single]
        }

        throw BridgeManagerError.invalidCatalog
    }

    public func validate(
        descriptors: [BridgeDescriptor],
        context: BridgeDescriptorValidationContext
    ) -> Result<[BridgeDescriptor], Error> {
        do {
            let valid = try descriptors.filter { descriptor in
                try validator.validate(descriptor: descriptor, context: context)
                return true
            }
            return .success(valid)
        } catch {
            return .failure(error)
        }
    }

    public func chooseFirstUsable(
        descriptors: [BridgeDescriptor],
        context: BridgeDescriptorValidationContext
    ) throws -> BridgeDescriptor {
        for descriptor in descriptors {
            if (try? validator.validate(descriptor: descriptor, context: context)) != nil {
                return descriptor
            }
        }
        throw BridgeManagerError.noMatchingBridge
    }
}
