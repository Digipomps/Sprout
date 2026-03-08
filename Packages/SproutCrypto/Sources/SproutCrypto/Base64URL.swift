import Foundation

public enum Base64URLError: Error, Equatable {
    case paddedInputNotAllowed
    case invalidLength
    case invalidCharacter(Character)
    case decodeFailure
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ value: String) throws -> Data {
        if value.contains("=") {
            throw Base64URLError.paddedInputNotAllowed
        }

        for character in value {
            switch character {
            case "A"..."Z", "a"..."z", "0"..."9", "-", "_":
                continue
            default:
                throw Base64URLError.invalidCharacter(character)
            }
        }

        let remainder = value.count % 4
        if remainder == 1 {
            throw Base64URLError.invalidLength
        }

        let padded: String
        switch remainder {
        case 0:
            padded = value
        case 2:
            padded = value + "=="
        case 3:
            padded = value + "="
        default:
            throw Base64URLError.invalidLength
        }

        let canonical = padded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: canonical) else {
            throw Base64URLError.decodeFailure
        }

        let roundTrip = encode(data)
        if roundTrip != value {
            throw Base64URLError.decodeFailure
        }

        return data
    }
}
