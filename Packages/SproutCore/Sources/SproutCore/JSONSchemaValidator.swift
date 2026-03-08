import Foundation
import CoreFoundation

public enum JSONSchemaValidationError: Error, Equatable, Sendable {
    case invalidSchema(String)
    case typeMismatch(path: String, expected: String)
    case missingRequiredProperty(path: String, property: String)
    case additionalPropertyNotAllowed(path: String, property: String)
    case enumMismatch(path: String)
    case arrayTooShort(path: String, minItems: Int)
    case invalidDateTime(path: String)
}

public enum JSONSchemaValidator {
    public static func validate(instanceData: Data, schemaData: Data) throws {
        let instance = try JSONSerialization.jsonObject(with: instanceData)
        guard let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else {
            throw JSONSchemaValidationError.invalidSchema("Top-level schema must be an object")
        }
        try validate(instance: instance, schema: schema, path: "$")
    }

    private static func validate(instance: Any, schema: [String: Any], path: String) throws {
        if let allowed = schema["enum"] as? [Any] {
            let canonicalInstance = canonicalJSON(instance)
            let matches = allowed.contains { canonicalJSON($0) == canonicalInstance }
            if !matches {
                throw JSONSchemaValidationError.enumMismatch(path: path)
            }
        }

        if let type = schema["type"] as? String {
            try validateType(instance: instance, expectedType: type, path: path)
        }

        if let format = schema["format"] as? String, format == "date-time" {
            guard let string = instance as? String else {
                throw JSONSchemaValidationError.invalidDateTime(path: path)
            }
            let formatter = ISO8601DateFormatter()
            if formatter.date(from: string) == nil {
                throw JSONSchemaValidationError.invalidDateTime(path: path)
            }
        }

        if let properties = schema["properties"] as? [String: Any],
           let object = instance as? [String: Any]
        {
            if let required = schema["required"] as? [String] {
                for key in required where object[key] == nil {
                    throw JSONSchemaValidationError.missingRequiredProperty(path: path, property: key)
                }
            }

            for (key, value) in object {
                if let propertySchema = properties[key] as? [String: Any] {
                    try validate(instance: value, schema: propertySchema, path: "\(path).\(key)")
                } else if (schema["additionalProperties"] as? Bool) == false {
                    throw JSONSchemaValidationError.additionalPropertyNotAllowed(path: path, property: key)
                }
            }
        }

        if let itemsSchema = schema["items"] as? [String: Any],
           let array = instance as? [Any]
        {
            if let minItems = schema["minItems"] as? Int, array.count < minItems {
                throw JSONSchemaValidationError.arrayTooShort(path: path, minItems: minItems)
            }

            for (index, value) in array.enumerated() {
                try validate(instance: value, schema: itemsSchema, path: "\(path)[\(index)]")
            }
        }
    }

    private static func validateType(instance: Any, expectedType: String, path: String) throws {
        switch expectedType {
        case "object":
            guard instance is [String: Any] else {
                throw JSONSchemaValidationError.typeMismatch(path: path, expected: expectedType)
            }
        case "array":
            guard instance is [Any] else {
                throw JSONSchemaValidationError.typeMismatch(path: path, expected: expectedType)
            }
        case "string":
            guard instance is String else {
                throw JSONSchemaValidationError.typeMismatch(path: path, expected: expectedType)
            }
        case "integer":
            guard let number = instance as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw JSONSchemaValidationError.typeMismatch(path: path, expected: expectedType)
            }
            let stringValue = number.stringValue
            if stringValue.contains(".") || stringValue.lowercased().contains("e") {
                throw JSONSchemaValidationError.typeMismatch(path: path, expected: expectedType)
            }
        case "boolean":
            guard let number = instance as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw JSONSchemaValidationError.typeMismatch(path: path, expected: expectedType)
            }
        case "null":
            guard instance is NSNull else {
                throw JSONSchemaValidationError.typeMismatch(path: path, expected: expectedType)
            }
        default:
            throw JSONSchemaValidationError.invalidSchema("Unsupported schema type: \(expectedType)")
        }
    }

    private static func canonicalJSON(_ value: Any) -> String {
        if let object = value as? [String: Any] {
            let keys = object.keys.sorted()
            let body = keys.map { key in
                let v = canonicalJSON(object[key] ?? NSNull())
                return "\"\(key)\":\(v)"
            }.joined(separator: ",")
            return "{\(body)}"
        }

        if let array = value as? [Any] {
            return "[\(array.map(canonicalJSON).joined(separator: ","))]"
        }

        if let string = value as? String {
            return "\"\(string)\""
        }

        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }

        if value is NSNull {
            return "null"
        }

        return "\"unsupported\""
    }
}
