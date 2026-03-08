import Foundation
import CoreFoundation

public enum JCSCanonicalizationError: Error, Equatable {
    case unsupportedType(String)
    case unsupportedNumber(String)
    case integerOutOfRange(String)
    case unsupportedTopLevel
}

public enum CanonicalJSONValue: Equatable {
    case object([String: CanonicalJSONValue])
    case array([CanonicalJSONValue])
    case string(String)
    case integer(Int64)
    case bool(Bool)
    case null

    public static func parse(jsonData: Data) throws -> CanonicalJSONValue {
        let object = try JSONSerialization.jsonObject(with: jsonData, options: [.fragmentsAllowed])
        return try fromFoundation(object)
    }

    static func fromFoundation(_ value: Any) throws -> CanonicalJSONValue {
        switch value {
        case let object as [String: Any]:
            var map = [String: CanonicalJSONValue]()
            for (key, currentValue) in object {
                map[key] = try fromFoundation(currentValue)
            }
            return .object(map)
        case let array as [Any]:
            return .array(try array.map(fromFoundation))
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }

            let stringValue = number.stringValue
            if stringValue.contains(".") || stringValue.lowercased().contains("e") {
                throw JCSCanonicalizationError.unsupportedNumber(stringValue)
            }

            guard let intValue = Int64(stringValue) else {
                throw JCSCanonicalizationError.integerOutOfRange(stringValue)
            }
            return .integer(intValue)
        case _ as NSNull:
            return .null
        default:
            throw JCSCanonicalizationError.unsupportedType(String(describing: type(of: value)))
        }
    }

    public func removingTopLevelKeys(_ keys: Set<String>) -> CanonicalJSONValue {
        guard case let .object(object) = self else { return self }
        var copy = object
        for key in keys {
            copy[key] = nil
        }
        return .object(copy)
    }

    public func canonicalData() throws -> Data {
        guard let data = canonicalString().data(using: .utf8) else {
            throw JCSCanonicalizationError.unsupportedTopLevel
        }
        return data
    }

    public func canonicalString() -> String {
        switch self {
        case let .object(object):
            let keys = object.keys.sorted(by: lexicalLessThan)
            let body = keys.map { key in
                let keyPart = "\"\(escapeJSONString(key))\""
                let valuePart = object[key]!.canonicalString()
                return "\(keyPart):\(valuePart)"
            }
            return "{\(body.joined(separator: ","))}"
        case let .array(array):
            return "[\(array.map { $0.canonicalString() }.joined(separator: ","))]"
        case let .string(string):
            return "\"\(escapeJSONString(string))\""
        case let .integer(integer):
            return String(integer)
        case let .bool(boolean):
            return boolean ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private func lexicalLessThan(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.unicodeScalars)
        let right = Array(rhs.unicodeScalars)
        for index in 0..<min(left.count, right.count) {
            if left[index].value == right[index].value {
                continue
            }
            return left[index].value < right[index].value
        }
        return left.count < right.count
    }
}

public enum JCSCanonicalizer {
    public static func canonicalize(_ jsonData: Data) throws -> Data {
        try CanonicalJSONValue.parse(jsonData: jsonData).canonicalData()
    }

    public static func canonicalizeRemovingTopLevelKeys(_ jsonData: Data, keys: Set<String>) throws -> Data {
        let parsed = try CanonicalJSONValue.parse(jsonData: jsonData)
        return try parsed.removingTopLevelKeys(keys).canonicalData()
    }

    public static func canonicalize(_ jsonObject: [String: Any]) throws -> Data {
        let parsed = try CanonicalJSONValue.fromFoundation(jsonObject)
        return try parsed.canonicalData()
    }
}

private func escapeJSONString(_ input: String) -> String {
    var result = ""
    result.reserveCapacity(input.count)

    for scalar in input.unicodeScalars {
        switch scalar.value {
        case 0x22:
            result.append("\\\"")
        case 0x5C:
            result.append("\\\\")
        case 0x08:
            result.append("\\b")
        case 0x09:
            result.append("\\t")
        case 0x0A:
            result.append("\\n")
        case 0x0C:
            result.append("\\f")
        case 0x0D:
            result.append("\\r")
        case 0x00...0x1F:
            let hex = String(scalar.value, radix: 16, uppercase: false)
            let padded = String(repeating: "0", count: max(0, 4 - hex.count)) + hex
            result.append("\\u\(padded)")
        default:
            result.unicodeScalars.append(scalar)
        }
    }

    return result
}
