import Foundation

/// Encodes text as a JavaScript string literal for `JSON.parse("...")`.
/// This is not an eval of remote code. The only inserted data is JSON text.
enum JavaScriptLiteral {
    static func string(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                output.append("\\\"")
            case 0x5C:
                output.append("\\\\")
            case 0x08:
                output.append("\\b")
            case 0x0C:
                output.append("\\f")
            case 0x0A:
                output.append("\\n")
            case 0x0D:
                output.append("\\r")
            case 0x09:
                output.append("\\t")
            case 0x2028:
                output.append("\\u2028")
            case 0x2029:
                output.append("\\u2029")
            case 0x3C:
                output.append("\\u003C")
            case 0x3E:
                output.append("\\u003E")
            case 0x26:
                output.append("\\u0026")
            default:
                if scalar.value < 0x20 {
                    output.append(String(format: "\\u%04X", scalar.value))
                } else {
                    output.append(String(scalar))
                }
            }
        }
        output.append("\"")
        return output
    }
}
