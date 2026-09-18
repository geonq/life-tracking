import Foundation
import CryptoKit

public enum PlanningValidationError: Error, Equatable, LocalizedError, Sendable {
    case inputTooLarge
    case invalidUTF8
    case invalidDocument
    case tooManyNodes
    case tooManyEdges
    case duplicateIdentifier(String)
    case invalidIdentifier(String)
    case unsupportedNodeType(String)
    case invalidCoordinate(String)
    case invalidDimension(String)
    case invalidReference(String)
    case invalidRelativePath(String)
    case absolutePath(String)
    case pathTraversal(String)
    case emptyPathSegment(String)
    case caseCollision(String)
    case invalidURL
    case unsafeValue(String)
    case invalidFrontmatter(String)
    case unsupportedFrontmatter
    case invalidTitle
    case invalidBinding
    case unsupportedSymlinkPolicy

    public var errorDescription: String {
        switch self {
        case .inputTooLarge:
            return "The planning payload exceeds its bounded input limit."
        case .invalidUTF8:
            return "The planning payload is not valid UTF-8."
        case .invalidDocument:
            return "The planning document is malformed."
        case .tooManyNodes:
            return "The canvas contains too many nodes."
        case .tooManyEdges:
            return "The canvas contains too many edges."
        case .duplicateIdentifier(let identifier):
            return "The planning identifier is duplicated: \(identifier)."
        case .invalidIdentifier(let field):
            return "The planning identifier is invalid for \(field)."
        case .unsupportedNodeType(let type):
            return "The canvas node type is unsupported: \(type)."
        case .invalidCoordinate(let field):
            return "The canvas coordinate is invalid for \(field)."
        case .invalidDimension(let field):
            return "The canvas dimension is invalid for \(field)."
        case .invalidReference(let field):
            return "The canvas reference is invalid for \(field)."
        case .invalidRelativePath(let field):
            return "The relative path is invalid for \(field)."
        case .absolutePath(let field):
            return "An absolute path is not allowed for \(field)."
        case .pathTraversal(let field):
            return "Path traversal is not allowed for \(field)."
        case .emptyPathSegment(let field):
            return "Empty path segments are not allowed for \(field)."
        case .caseCollision(let field):
            return "Case-colliding path or key values are not allowed for \(field)."
        case .invalidURL:
            return "The link URL is invalid or uses an unsafe scheme."
        case .unsafeValue(let field):
            return "The planning value is unsafe for \(field)."
        case .invalidFrontmatter(let field):
            return "The Markdown frontmatter is invalid for \(field)."
        case .unsupportedFrontmatter:
            return "The Markdown frontmatter contains a form this bounded parser does not interpret."
        case .invalidTitle:
            return "The Markdown title is invalid."
        case .invalidBinding:
            return "The selected planning vault binding is invalid."
        case .unsupportedSymlinkPolicy:
            return "The planning binding must reject unknown symlinks."
        }
    }
}

public enum PlanningLimits {
    public static let maximumCanvasBytes = 2 * 1024 * 1024
    public static let maximumMarkdownBytes = 1 * 1024 * 1024
    public static let maximumNodes = 10_000
    public static let maximumEdges = 20_000
    public static let maximumIdentifierBytes = 256
    public static let maximumTextBytes = 512 * 1024
    /// `maximumTextBytes` bounds the decoded Swift value. Canvas input is also
    /// bounded by the encoded JSON token size so escape-heavy strings cannot
    /// make the parser allocate without limit.
    public static let maximumJSONEncodedStringBytes = maximumCanvasBytes
    public static let maximumUnknownFields = 20_000
    public static let maximumJSONDepth = 64
    public static let maximumJSONArrayItems = 20_000
    public static let maximumJSONObjectFields = 20_000
    public static let maximumPathBytes = 1_024
    public static let maximumPathSegments = 64
    public static let maximumPathSegmentBytes = 255
    public static let maximumCoordinate = 10_000_000.0
    public static let maximumDimension = 10_000_000.0
    public static let maximumBorderWidth = 1_000.0
    public static let maximumURLBytes = 4_096
    public static let maximumFrontmatterFieldBytes = 16 * 1_024
    public static let maximumTitleBytes = 256
}

internal struct PlanningAnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

internal func planningCodingKey(_ value: String) -> PlanningAnyCodingKey {
    PlanningAnyCodingKey(stringValue: value)!
}

internal let planningCanvasDocumentKeys: Set<String> = ["nodes", "edges"]
internal let planningCanvasNodeExtensionKeys: Set<String> = [
    "locked", "borderWidth", "borderStyle"
]
internal let planningCanvasNodeStandardKeys: Set<String> = [
    "id", "type", "x", "y", "width", "height", "color", "text", "file",
    "subpath", "url", "label", "background", "backgroundStyle"
]
internal let planningCanvasNodeKeys: Set<String> = planningCanvasNodeStandardKeys.union(planningCanvasNodeExtensionKeys)
internal let planningCanvasEdgeKeys: Set<String> = [
    "id", "fromNode", "fromSide", "fromEnd", "toNode", "toSide", "toEnd", "color", "label"
]

internal func planningUnknownFields(
    from container: KeyedDecodingContainer<PlanningAnyCodingKey>,
    known: Set<String>
) throws -> [String: PlanningJSONValue] {
    guard container.allKeys.count <= PlanningLimits.maximumUnknownFields else {
        throw PlanningValidationError.unsafeValue("unknownFields")
    }

    var fields: [String: PlanningJSONValue] = [:]
    fields.reserveCapacity(max(0, container.allKeys.count - known.count))
    for key in container.allKeys where !known.contains(key.stringValue) {
        try PlanningValidation.validateJSONKey(key.stringValue)
        fields[key.stringValue] = try container.decode(PlanningJSONValue.self, forKey: key)
    }
    return fields
}

internal func planningEncodeUnknownFields(
    _ fields: [String: PlanningJSONValue],
    into container: inout KeyedEncodingContainer<PlanningAnyCodingKey>,
    known: Set<String>
) throws {
    guard fields.count <= PlanningLimits.maximumUnknownFields else {
        throw PlanningValidationError.unsafeValue("unknownFields")
    }
    for key in fields.keys.sorted() {
        guard !known.contains(key) else {
            throw PlanningValidationError.unsafeValue("unknownField.(key)")
        }
        try PlanningValidation.validateJSONKey(key)
        try container.encode(fields[key]!, forKey: planningCodingKey(key))
    }
}

internal func planningDecodeCanvasExtensionFields(
    from container: KeyedDecodingContainer<PlanningAnyCodingKey>
) throws -> [String: PlanningJSONValue] {
    var fields: [String: PlanningJSONValue] = [:]
    for key in planningCanvasNodeExtensionKeys.sorted() {
        let codingKey = planningCodingKey(key)
        guard container.contains(codingKey) else { continue }
        fields[key] = try container.decode(PlanningJSONValue.self, forKey: codingKey)
    }
    return fields
}

public enum PlanningJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    /// A JSON number whose source lexeme is retained. This is intentionally a
    /// string so exponent notation and integers outside Int64 remain exact.
    case number(String)
    case string(String)
    case array([PlanningJSONValue])
    case object([String: PlanningJSONValue])

    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= PlanningLimits.maximumJSONDepth else {
            throw PlanningValidationError.unsafeValue("json.depth")
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(String.self) {
            try PlanningValidation.validateJSONString(value)
            self = .string(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            // A Decoder does not expose the source number lexeme. Accepting a
            // Double here would silently round large or exponent-form values;
            // the dedicated bounded Canvas parser is the only lossless number
            // route. Public Codable therefore rejects every non-Int64 number.
            guard value.isFinite else {
                throw PlanningValidationError.unsafeValue("json.number")
            }
            throw PlanningValidationError.unsafeValue("json.number.nonInt64")
        }
        if let value = try? container.decode([PlanningJSONValue].self) {
            guard value.count <= PlanningLimits.maximumJSONArrayItems else {
                throw PlanningValidationError.unsafeValue("json.array")
            }
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: PlanningJSONValue].self) {
            guard value.count <= PlanningLimits.maximumJSONObjectFields else {
                throw PlanningValidationError.unsafeValue("json.object")
            }
            for key in value.keys {
                try PlanningValidation.validateJSONKey(key)
            }
            self = .object(value)
            return
        }

        throw PlanningValidationError.unsafeValue("json.value")
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .integer(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            // Codable has no public primitive for emitting a raw number
            // lexeme. Refuse a lossy conversion here; PlanningCanvasCodec
            // uses its bounded raw writer for exact Canvas round-trips.
            try PlanningJSONNumber.validate(value)
            guard let integer = Int64(value), String(integer) == value else {
                throw PlanningValidationError.unsafeValue("json.number.lossyEncode")
            }
            var container = encoder.singleValueContainer()
            try container.encode(integer)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .object(let values):
            var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
            for key in values.keys.sorted() {
                try container.encode(values[key]!, forKey: planningCodingKey(key))
            }
        }
    }

    internal func validate(depth: Int = 0) throws {
        guard depth <= PlanningLimits.maximumJSONDepth else {
            throw PlanningValidationError.unsafeValue("json.depth")
        }
        switch self {
        case .null, .bool, .integer:
            return
        case .number(let value):
            try PlanningJSONNumber.validate(value)
        case .string(let value):
            try PlanningValidation.validateJSONString(value)
        case .array(let values):
            guard values.count <= PlanningLimits.maximumJSONArrayItems else {
                throw PlanningValidationError.unsafeValue("json.array")
            }
            for value in values {
                try value.validate(depth: depth + 1)
            }
        case .object(let values):
            guard values.count <= PlanningLimits.maximumJSONObjectFields else {
                throw PlanningValidationError.unsafeValue("json.object")
            }
            for (key, value) in values {
                try PlanningValidation.validateJSONKey(key)
                try value.validate(depth: depth + 1)
            }
        }
    }

    internal func encodedJSONSize() throws -> Int {
        try validate()
        switch self {
        case .null:
            return 4
        case .bool(let value):
            return value ? 4 : 5
        case .integer(let value):
            return String(value).utf8.count
        case .number(let value):
            return value.utf8.count
        case .string(let value):
            return PlanningJSONString.encodedSize(value)
        case .array(let values):
            var size = 2
            for (index, value) in values.enumerated() {
                size = try PlanningJSONString.adding(size, value.encodedJSONSize())
                if index < values.count - 1 {
                    size = try PlanningJSONString.adding(size, 1)
                }
            }
            return size
        case .object(let values):
            var size = 2
            for (index, key) in values.keys.sorted().enumerated() {
                try PlanningValidation.validateJSONKey(key)
                size = try PlanningJSONString.adding(size, PlanningJSONString.encodedSize(key))
                size = try PlanningJSONString.adding(size, 1)
                size = try PlanningJSONString.adding(size, values[key]!.encodedJSONSize())
                if index < values.count - 1 {
                    size = try PlanningJSONString.adding(size, 1)
                }
            }
            return size
        }
    }

    internal func appendEncoded(to data: inout Data) throws {
        try validate()
        switch self {
        case .null:
            data.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C]) // null
        case .bool(let value):
            data.append(contentsOf: Array((value ? "true" : "false").utf8))
        case .integer(let value):
            data.append(contentsOf: Array(String(value).utf8))
        case .number(let value):
            data.append(contentsOf: Array(value.utf8))
        case .string(let value):
            PlanningJSONString.append(value, to: &data)
        case .array(let values):
            data.append(0x5B) // [
            for (index, value) in values.enumerated() {
                try value.appendEncoded(to: &data)
                if index < values.count - 1 { data.append(0x2C) }
            }
            data.append(0x5D) // ]
        case .object(let values):
            data.append(0x7B) // {
            let keys = values.keys.sorted()
            for (index, key) in keys.enumerated() {
                PlanningJSONString.append(key, to: &data)
                data.append(0x3A) // :
                try values[key]!.appendEncoded(to: &data)
                if index < keys.count - 1 { data.append(0x2C) }
            }
            data.append(0x7D) // }
        }
    }
}

internal enum PlanningJSONString {
    static func adding(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw PlanningValidationError.inputTooLarge
        }
        return result
    }

    static func encodedSize(_ value: String) -> Int {
        var size = 2
        for byte in value.utf8 {
            switch byte {
            case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D:
                size += 2
            case 0x00..<0x20:
                size += 6
            default:
                size += 1
            }
        }
        return size
    }

    static func append(_ value: String, to data: inout Data) {
        data.append(0x22) // quote
        for byte in value.utf8 {
            switch byte {
            case 0x22:
                data.append(contentsOf: [0x5C, 0x22])
            case 0x5C:
                data.append(contentsOf: [0x5C, 0x5C])
            case 0x08:
                data.append(contentsOf: [0x5C, 0x62])
            case 0x09:
                data.append(contentsOf: [0x5C, 0x74])
            case 0x0A:
                data.append(contentsOf: [0x5C, 0x6E])
            case 0x0C:
                data.append(contentsOf: [0x5C, 0x66])
            case 0x0D:
                data.append(contentsOf: [0x5C, 0x72])
            case 0x00..<0x20:
                let digits = Array(String(format: "%02X", byte).utf8)
                data.append(contentsOf: [0x5C, 0x75, 0x30, 0x30])
                data.append(contentsOf: digits)
            default:
                data.append(byte)
            }
        }
        data.append(0x22) // quote
    }
}

internal enum PlanningJSONNumber {
    static let maximumBytes = 256

    static func validate(_ raw: String) throws {
        let bytes = Array(raw.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumBytes else {
            throw PlanningValidationError.unsafeValue("json.number")
        }

        var index = 0
        if bytes[index] == 0x2D { // -
            index += 1
            guard index < bytes.count else {
                throw PlanningValidationError.unsafeValue("json.number")
            }
        }

        if bytes[index] == 0x30 { // 0
            index += 1
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                throw PlanningValidationError.unsafeValue("json.number")
            }
        } else if (0x31...0x39).contains(bytes[index]) {
            repeat {
                index += 1
            } while index < bytes.count && (0x30...0x39).contains(bytes[index])
        } else {
            throw PlanningValidationError.unsafeValue("json.number")
        }

        if index < bytes.count, bytes[index] == 0x2E { // .
            index += 1
            let fractionStart = index
            while index < bytes.count && (0x30...0x39).contains(bytes[index]) {
                index += 1
            }
            guard index > fractionStart else {
                throw PlanningValidationError.unsafeValue("json.number")
            }
        }

        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 { // e/E
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
                index += 1
            }
            let exponentStart = index
            while index < bytes.count && (0x30...0x39).contains(bytes[index]) {
                index += 1
            }
            guard index > exponentStart else {
                throw PlanningValidationError.unsafeValue("json.number")
            }
        }

        guard index == bytes.count else {
            throw PlanningValidationError.unsafeValue("json.number")
        }
    }

    static func integer(_ raw: String) -> Int64? {
        guard raw.first != "-" || raw != "-0" else { return nil }
        guard !raw.contains("."), !raw.contains("e"), !raw.contains("E"),
              let value = Int64(raw), String(value) == raw else {
            return nil
        }
        return value
    }
}

internal enum PlanningValidation {
    static func validateJSONKey(_ value: String) throws {
        // Object keys are JSON data, not Canvas identifiers. Empty keys and
        // escaped control characters are valid and must remain round-trippable.
        try validateJSONString(value, maximumBytes: PlanningLimits.maximumIdentifierBytes)
    }

    static func validateFrontmatterKey(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= PlanningLimits.maximumIdentifierBytes else {
            throw PlanningValidationError.invalidFrontmatter("key")
        }
        guard value.unicodeScalars.allSatisfy({
            ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A)
                || ($0.value >= 0x30 && $0.value <= 0x39)
                || $0 == "_" || $0 == "-" || $0 == "."
        }) else {
            throw PlanningValidationError.invalidFrontmatter("key")
        }
    }

    static func validateSafeString(
        _ value: String,
        field: String,
        maximumBytes: Int,
        allowNewlines: Bool = false
    ) throws {
        guard value.utf8.count <= maximumBytes else {
            throw PlanningValidationError.unsafeValue(field)
        }
        for scalar in value.unicodeScalars {
            if scalar.value == 0 || scalar.value < 0x20 {
                let isAllowedWhitespace = allowNewlines && (scalar == "\n" || scalar == "\r" || scalar == "\t")
                guard isAllowedWhitespace else {
                    throw PlanningValidationError.unsafeValue(field)
                }
            }
        }
    }

    static func validateJSONString(_ value: String) throws {
        try validateJSONString(value, maximumBytes: PlanningLimits.maximumTextBytes)
    }

    static func validateJSONString(_ value: String, maximumBytes: Int) throws {
        guard value.utf8.count <= maximumBytes else {
            throw PlanningValidationError.unsafeValue("json.string")
        }
        guard PlanningJSONString.encodedSize(value) <= PlanningLimits.maximumJSONEncodedStringBytes else {
            throw PlanningValidationError.unsafeValue("json.string.encoded")
        }
        // JSON permits control characters in a Swift String when they were
        // escaped in the source. The raw parser rejects unescaped controls;
        // keeping the decoded value here permits exact object-key round trips.
    }

    static func validateIdentifier(_ value: String, field: String) throws {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= PlanningLimits.maximumIdentifierBytes else {
            throw PlanningValidationError.invalidIdentifier(field)
        }
        try validateSafeString(value, field: field, maximumBytes: PlanningLimits.maximumIdentifierBytes)
    }

    static func validateCoordinate(_ value: Double, field: String) throws {
        guard value.isFinite,
              value.rounded(.towardZero) == value,
              abs(value) <= PlanningLimits.maximumCoordinate else {
            throw PlanningValidationError.invalidCoordinate(field)
        }
    }

    static func validateDimension(_ value: Double, field: String) throws {
        guard value.isFinite,
              value.rounded(.towardZero) == value,
              value > 0,
              value <= PlanningLimits.maximumDimension else {
            throw PlanningValidationError.invalidDimension(field)
        }
    }

    static func validateCanvasColor(_ value: String, field: String) throws {
        try validateSafeString(value, field: field, maximumBytes: 16)
        if ["1", "2", "3", "4", "5", "6"].contains(value) {
            return
        }
        let bytes = Array(value.utf8)
        guard bytes.first == 0x23, bytes.count == 7 || bytes.count == 9 else {
            throw PlanningValidationError.unsafeValue(field)
        }
        guard bytes.dropFirst().allSatisfy({
            (0x30...0x39).contains($0)
                || (0x41...0x46).contains($0)
                || (0x61...0x66).contains($0)
        }) else {
            throw PlanningValidationError.unsafeValue(field)
        }
    }

    static func validateCanvasSubpath(_ value: String) throws {
        try validateSafeString(value, field: "node.subpath", maximumBytes: 4_096)
        guard value.first == "#" else {
            throw PlanningValidationError.invalidReference("node.subpath")
        }
    }

    static func validateCanvasBackgroundStyle(_ value: String) throws {
        guard ["cover", "ratio", "repeat"].contains(value) else {
            throw PlanningValidationError.unsafeValue("node.backgroundStyle")
        }
    }

    static func validateCanvasSide(_ value: String?, field: String) throws {
        if let value {
            guard ["top", "right", "bottom", "left"].contains(value) else {
                throw PlanningValidationError.unsafeValue(field)
            }
        }
    }

    static func validateCanvasEnd(_ value: String?, field: String) throws {
        if let value {
            guard ["none", "arrow"].contains(value) else {
                throw PlanningValidationError.unsafeValue(field)
            }
        }
    }

    static func validateRelativePath(_ raw: String, field: String) throws -> String {
        guard !raw.isEmpty, raw.utf8.count <= PlanningLimits.maximumPathBytes else {
            throw PlanningValidationError.invalidRelativePath(field)
        }
        let bytes = Array(raw.utf8)
        guard !bytes.isEmpty else {
            throw PlanningValidationError.invalidRelativePath(field)
        }
        guard bytes[0] != 0x2f, bytes[0] != 0x5c, bytes[0] != 0x7e else {
            throw PlanningValidationError.absolutePath(field)
        }
        if bytes.count >= 2,
           ((0x41...0x5A).contains(bytes[0]) || (0x61...0x7A).contains(bytes[0])),
           bytes[1] == 0x3A {
            throw PlanningValidationError.absolutePath(field)
        }
        guard !raw.contains("\\") else {
            throw PlanningValidationError.absolutePath(field)
        }

        let segments = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty, segments.count <= PlanningLimits.maximumPathSegments else {
            throw PlanningValidationError.invalidRelativePath(field)
        }

        for segment in segments {
            guard !segment.isEmpty else {
                throw PlanningValidationError.emptyPathSegment(field)
            }
            guard segment.utf8.count <= PlanningLimits.maximumPathSegmentBytes else {
                throw PlanningValidationError.invalidRelativePath(field)
            }
            if segment == "." || segment == ".." {
                throw PlanningValidationError.pathTraversal(field)
            }
            try validateSafeString(segment, field: field, maximumBytes: PlanningLimits.maximumPathSegmentBytes)
            guard !segment.hasSuffix(".") && !segment.hasSuffix(" ") else {
                throw PlanningValidationError.invalidRelativePath(field)
            }
            let windowsForbiddenScalars: Set<UInt32> = [
                0x3A, // : (alternate data stream)
                0x2A, // *
                0x3F, // ?
                0x22, // "
                0x3C, // <
                0x3E, // >
                0x7C  // |
            ]
            guard !segment.unicodeScalars.contains(where: { windowsForbiddenScalars.contains($0.value) }) else {
                throw PlanningValidationError.invalidRelativePath(field)
            }
            let windowsBase = segment.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? segment
            let normalizedWindowsBase = windowsBase.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            let reserved = ["CON", "PRN", "AUX", "NUL"]
            let deviceSuffixes = Set((1...9).map(String.init) + ["¹", "²", "³"])
            let upperBase = normalizedWindowsBase.uppercased()
            let isReservedDevice = reserved.contains(upperBase)
                || (upperBase.count > 3
                    && (upperBase.hasPrefix("COM") || upperBase.hasPrefix("LPT"))
                    && deviceSuffixes.contains(String(upperBase.dropFirst(3))))
            guard !isReservedDevice else {
                throw PlanningValidationError.invalidRelativePath(field)
            }
        }
        return segments.joined(separator: "/")
    }

    /// The reference collision policy is intentionally stricter than the
    /// logical vault path policy: each reference is a valid POSIX-style
    /// relative path, then Windows aliases are folded by Unicode
    /// case-insensitive comparison of each segment. A single path may contain
    /// segments that differ only by case; separate references may not resolve
    /// to the same folded path unless their original spelling is identical.
    static func normalizedReferencePath(_ raw: String) -> String {
        raw.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
            .joined(separator: "/")
    }

    static func validateReferenceCollisions(_ references: [(value: String, field: String)]) throws {
        var seen: [String: (value: String, field: String)] = [:]
        for reference in references {
            let normalized = normalizedReferencePath(reference.value)
            if let prior = seen[normalized], prior.value != reference.value {
                throw PlanningValidationError.caseCollision("\(prior.field),\(reference.field)")
            }
            seen[normalized] = reference
        }
    }

    static func validateURL(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= PlanningLimits.maximumURLBytes else {
            throw PlanningValidationError.invalidURL
        }
        try validateSafeString(value, field: "url", maximumBytes: PlanningLimits.maximumURLBytes)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty,
              !["file", "javascript", "data", "blob"].contains(scheme) else {
            throw PlanningValidationError.invalidURL
        }
    }

    static func validateOptionalText(_ value: String?, field: String, maximumBytes: Int = PlanningLimits.maximumTextBytes) throws {
        if let value {
            try validateSafeString(value, field: field, maximumBytes: maximumBytes, allowNewlines: field == "text")
            if field == "text" {
                try validateJSONString(value, maximumBytes: maximumBytes)
            }
        }
    }

    static func validateUnknownFields(_ fields: [String: PlanningJSONValue], known: Set<String>) throws {
        guard fields.count <= PlanningLimits.maximumUnknownFields else {
            throw PlanningValidationError.unsafeValue("unknownFields")
        }
        for (key, value) in fields {
            guard !known.contains(key) else {
                throw PlanningValidationError.unsafeValue("unknownField.(key)")
            }
            try validateJSONKey(key)
            try value.validate()
        }
    }

    static func validateCanvasExtensionFields(_ fields: [String: PlanningJSONValue]) throws {
        guard fields.count <= planningCanvasNodeExtensionKeys.count else {
            throw PlanningValidationError.unsafeValue("node.extensions")
        }
        for (key, value) in fields {
            guard planningCanvasNodeExtensionKeys.contains(key) else {
                throw PlanningValidationError.unsafeValue("node.extensions.key")
            }
            switch key {
            case "locked":
                switch value {
                case .null, .bool:
                    break
                default:
                    throw PlanningValidationError.invalidDocument
                }
            case "borderWidth":
                if case .null = value {
                    continue
                }
                let raw: String?
                switch value {
                case .integer(let integer):
                    raw = String(integer)
                case .number(let number):
                    raw = number
                default:
                    raw = nil
                }
                guard let raw, let number = Double(raw), number.isFinite,
                      number >= 0, number <= PlanningLimits.maximumBorderWidth else {
                    throw PlanningValidationError.invalidDimension("node.borderWidth")
                }
            case "borderStyle":
                if case .null = value {
                    continue
                }
                guard case .string(let style) = value else {
                    throw PlanningValidationError.invalidDocument
                }
                try validateOptionalText(style, field: "node.borderStyle", maximumBytes: 256)
            default:
                throw PlanningValidationError.unsafeValue("node.extensions.key")
            }
            try value.validate()
        }
    }

}

public struct PlanningRelativePath: Codable, Equatable, Hashable, Sendable {
    public let value: String

    public init(_ rawValue: String) throws {
        self.value = try PlanningValidation.validateRelativePath(rawValue, field: "path")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public var segments: [String] {
        value.split(separator: "/").map(String.init)
    }
}

public enum PlanningCanvasNodeType: String, Codable, Equatable, Sendable {
    case file
    case text
    case link
    case group
}

public struct PlanningCanvasNode: Codable, Equatable, Sendable {
    public let id: String
    public let type: PlanningCanvasNodeType
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let color: String?
    public let text: String?
    public let file: String?
    public let subpath: String?
    public let url: String?
    public let label: String?
    public let locked: Bool?
    public let background: String?
    public let backgroundStyle: String?
    public let borderWidth: Double?
    public let borderStyle: String?
    /// Raw JSON for the nonstandard Canvas extension fields. Dedicated Canvas
    /// decoding stores these values here so nulls and numeric lexemes survive
    /// a decode/encode cycle without being coerced through Double.
    public let extensionFields: [String: PlanningJSONValue]
    public let unknownFields: [String: PlanningJSONValue]

    public init(
        id: String,
        type: PlanningCanvasNodeType,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        color: String? = nil,
        text: String? = nil,
        file: String? = nil,
        subpath: String? = nil,
        url: String? = nil,
        label: String? = nil,
        locked: Bool? = nil,
        background: String? = nil,
        backgroundStyle: String? = nil,
        borderWidth: Double? = nil,
        borderStyle: String? = nil,
        unknownFields: [String: PlanningJSONValue] = [:],
        extensionFields: [String: PlanningJSONValue] = [:]
    ) throws {
        let resolved = try Self.resolvedExtensions(
            locked: locked,
            borderWidth: borderWidth,
            borderStyle: borderStyle,
            extensionFields: extensionFields
        )
        try Self.validate(
            id: id,
            type: type,
            x: x,
            y: y,
            width: width,
            height: height,
            color: color,
            text: text,
            file: file,
            subpath: subpath,
            url: url,
            label: label,
            background: background,
            backgroundStyle: backgroundStyle,
            borderWidth: resolved.borderWidth,
            borderStyle: resolved.borderStyle,
            unknownFields: unknownFields,
            extensionFields: extensionFields
        )
        self.id = id
        self.type = type
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.color = color
        self.text = text
        self.file = file
        self.subpath = subpath
        self.url = url
        self.label = label
        self.locked = resolved.locked
        self.background = background
        self.backgroundStyle = backgroundStyle
        self.borderWidth = resolved.borderWidth
        self.borderStyle = resolved.borderStyle
        self.extensionFields = extensionFields
        self.unknownFields = unknownFields
    }

    private static func resolvedExtensions(
        locked: Bool?,
        borderWidth: Double?,
        borderStyle: String?,
        extensionFields: [String: PlanningJSONValue]
    ) throws -> (locked: Bool?, borderWidth: Double?, borderStyle: String?) {
        try PlanningValidation.validateCanvasExtensionFields(extensionFields)

        var resolvedLocked = locked
        if let raw = extensionFields["locked"] {
            switch raw {
            case .null:
                guard locked == nil else { throw PlanningValidationError.invalidDocument }
                resolvedLocked = nil
            case .bool(let value):
                if let locked, locked != value { throw PlanningValidationError.invalidDocument }
                resolvedLocked = value
            default:
                throw PlanningValidationError.invalidDocument
            }
        }

        var resolvedBorderWidth = borderWidth
        if let raw = extensionFields["borderWidth"] {
            switch raw {
            case .null:
                guard borderWidth == nil else { throw PlanningValidationError.invalidDocument }
                resolvedBorderWidth = nil
            case .integer(let value):
                let number = Double(value)
                if let borderWidth, borderWidth != number { throw PlanningValidationError.invalidDocument }
                resolvedBorderWidth = number
            case .number(let value):
                guard let number = Double(value), number.isFinite else {
                    throw PlanningValidationError.invalidDocument
                }
                if let borderWidth, borderWidth != number { throw PlanningValidationError.invalidDocument }
                resolvedBorderWidth = number
            default:
                throw PlanningValidationError.invalidDocument
            }
        }

        var resolvedBorderStyle = borderStyle
        if let raw = extensionFields["borderStyle"] {
            switch raw {
            case .null:
                guard borderStyle == nil else { throw PlanningValidationError.invalidDocument }
                resolvedBorderStyle = nil
            case .string(let value):
                if let borderStyle, borderStyle != value { throw PlanningValidationError.invalidDocument }
                resolvedBorderStyle = value
            default:
                throw PlanningValidationError.invalidDocument
            }
        }

        return (resolvedLocked, resolvedBorderWidth, resolvedBorderStyle)
    }

    internal static func validate(
        id: String,
        type: PlanningCanvasNodeType,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        color: String?,
        text: String?,
        file: String?,
        subpath: String?,
        url: String?,
        label: String?,
        background: String?,
        backgroundStyle: String?,
        borderWidth: Double?,
        borderStyle: String?,
        unknownFields: [String: PlanningJSONValue],
        extensionFields: [String: PlanningJSONValue]
    ) throws {
        try PlanningValidation.validateIdentifier(id, field: "node.id")
        try PlanningValidation.validateCoordinate(x, field: "node.x")
        try PlanningValidation.validateCoordinate(y, field: "node.y")
        try PlanningValidation.validateDimension(width, field: "node.width")
        try PlanningValidation.validateDimension(height, field: "node.height")
        if let color {
            try PlanningValidation.validateCanvasColor(color, field: "node.color")
        }
        try PlanningValidation.validateOptionalText(text, field: "text")
        if let subpath {
            try PlanningValidation.validateCanvasSubpath(subpath)
        }
        try PlanningValidation.validateOptionalText(label, field: "node.label", maximumBytes: PlanningLimits.maximumTextBytes)
        if let background {
            _ = try PlanningRelativePath(background)
        }
        if let backgroundStyle {
            try PlanningValidation.validateCanvasBackgroundStyle(backgroundStyle)
        }
        try PlanningValidation.validateCanvasExtensionFields(extensionFields)
        try PlanningValidation.validateOptionalText(borderStyle, field: "node.borderStyle", maximumBytes: 256)
        if let file {
            _ = try PlanningRelativePath(file)
        }
        if let url {
            try PlanningValidation.validateURL(url)
        }
        if let borderWidth {
            guard borderWidth.isFinite, borderWidth >= 0, borderWidth <= PlanningLimits.maximumBorderWidth else {
                throw PlanningValidationError.invalidDimension("node.borderWidth")
            }
        }
        switch type {
        case .file:
            guard file != nil else { throw PlanningValidationError.invalidReference("node.file") }
        case .text:
            guard text != nil else { throw PlanningValidationError.invalidReference("node.text") }
        case .link:
            guard url != nil else { throw PlanningValidationError.invalidReference("node.url") }
        case .group:
            break
        }
        try PlanningValidation.validateUnknownFields(unknownFields, known: planningCanvasNodeKeys)
    }
}

public struct PlanningCanvasEdge: Codable, Equatable, Sendable {
    public let id: String
    public let fromNode: String
    public let fromSide: String?
    public let fromEnd: String?
    public let toNode: String
    public let toSide: String?
    public let toEnd: String?
    public let color: String?
    public let label: String?
    public let unknownFields: [String: PlanningJSONValue]

    public init(
        id: String,
        fromNode: String,
        fromSide: String? = nil,
        fromEnd: String? = nil,
        toNode: String,
        toSide: String? = nil,
        toEnd: String? = nil,
        color: String? = nil,
        label: String? = nil,
        unknownFields: [String: PlanningJSONValue] = [:]
    ) throws {
        try Self.validate(
            id: id,
            fromNode: fromNode,
            fromSide: fromSide,
            fromEnd: fromEnd,
            toNode: toNode,
            toSide: toSide,
            toEnd: toEnd,
            color: color,
            label: label,
            unknownFields: unknownFields
        )
        self.id = id
        self.fromNode = fromNode
        self.fromSide = fromSide
        self.fromEnd = fromEnd
        self.toNode = toNode
        self.toSide = toSide
        self.toEnd = toEnd
        self.color = color
        self.label = label
        self.unknownFields = unknownFields
    }

    internal static func validate(
        id: String,
        fromNode: String,
        fromSide: String?,
        fromEnd: String?,
        toNode: String,
        toSide: String?,
        toEnd: String?,
        color: String?,
        label: String?,
        unknownFields: [String: PlanningJSONValue]
    ) throws {
        try PlanningValidation.validateIdentifier(id, field: "edge.id")
        try PlanningValidation.validateIdentifier(fromNode, field: "edge.fromNode")
        try PlanningValidation.validateIdentifier(toNode, field: "edge.toNode")
        try PlanningValidation.validateCanvasSide(fromSide, field: "edge.fromSide")
        try PlanningValidation.validateCanvasSide(toSide, field: "edge.toSide")
        try PlanningValidation.validateCanvasEnd(fromEnd, field: "edge.fromEnd")
        try PlanningValidation.validateCanvasEnd(toEnd, field: "edge.toEnd")
        if let color {
            try PlanningValidation.validateCanvasColor(color, field: "edge.color")
        }
        try PlanningValidation.validateOptionalText(label, field: "edge.label", maximumBytes: PlanningLimits.maximumTextBytes)
        try PlanningValidation.validateUnknownFields(unknownFields, known: planningCanvasEdgeKeys)
    }
}

public struct PlanningCanvasDocument: Codable, Equatable, Sendable {
    public let nodes: [PlanningCanvasNode]
    public let edges: [PlanningCanvasEdge]
    public let unknownFields: [String: PlanningJSONValue]

    public init(
        nodes: [PlanningCanvasNode],
        edges: [PlanningCanvasEdge],
        unknownFields: [String: PlanningJSONValue] = [:]
    ) throws {
        guard nodes.count <= PlanningLimits.maximumNodes else {
            throw PlanningValidationError.tooManyNodes
        }
        guard edges.count <= PlanningLimits.maximumEdges else {
            throw PlanningValidationError.tooManyEdges
        }

        var identifiers = Set<String>()
        identifiers.reserveCapacity(nodes.count + edges.count)
        for node in nodes {
            guard identifiers.insert(node.id).inserted else {
                throw PlanningValidationError.duplicateIdentifier(node.id)
            }
        }
        let nodeIdentifiers = Set(nodes.map(\.id))
        for edge in edges {
            guard identifiers.insert(edge.id).inserted else {
                throw PlanningValidationError.duplicateIdentifier(edge.id)
            }
            guard nodeIdentifiers.contains(edge.fromNode),
                  nodeIdentifiers.contains(edge.toNode) else {
                throw PlanningValidationError.invalidReference(edge.id)
            }
        }
        var pathReferences: [(value: String, field: String)] = []
        pathReferences.reserveCapacity(nodes.reduce(into: 0) { count, node in
            count += (node.file == nil ? 0 : 1) + (node.background == nil ? 0 : 1)
        })
        for node in nodes {
            if let file = node.file {
                pathReferences.append((file, "node.file.\(node.id)"))
            }
            if let background = node.background {
                pathReferences.append((background, "node.background.\(node.id)"))
            }
        }
        try PlanningValidation.validateReferenceCollisions(pathReferences)
        try PlanningValidation.validateUnknownFields(unknownFields, known: planningCanvasDocumentKeys)
        self.nodes = nodes
        self.edges = edges
        self.unknownFields = unknownFields
    }

    public var contentDigest: String {
        guard let data = try? PlanningCanvasCodec.encode(self) else { return "" }
        return PlanningDigest.hex(data)
    }

    public var revision: String {
        contentDigest
    }
}

internal enum PlanningDigest {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum PlanningMarkdownFrontmatterStatus: String, Codable, Equatable, Sendable {
    case absent
    case parsed
    case unsupported
}

public struct PlanningMarkdownFrontmatterField: Codable, Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) throws {
        try PlanningValidation.validateFrontmatterKey(key)
        try PlanningValidation.validateSafeString(
            value,
            field: "frontmatter.value",
            maximumBytes: PlanningLimits.maximumFrontmatterFieldBytes
        )
        self.key = key
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PlanningAnyCodingKey.self)
        let key = try container.decode(String.self, forKey: planningCodingKey("key"))
        let value = try container.decode(String.self, forKey: planningCodingKey("value"))
        try self.init(key: key, value: value)
    }

    public func encode(to encoder: Encoder) throws {
        _ = try Self(key: key, value: value)
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(key, forKey: planningCodingKey("key"))
        try container.encode(value, forKey: planningCodingKey("value"))
    }
}

public struct PlanningMarkdownFrontmatter: Codable, Equatable, Sendable {
    public let status: PlanningMarkdownFrontmatterStatus
    public let raw: String
    public let fields: [PlanningMarkdownFrontmatterField]

    public init(
        status: PlanningMarkdownFrontmatterStatus,
        raw: String,
        fields: [PlanningMarkdownFrontmatterField]
    ) throws {
        try PlanningValidation.validateSafeString(
            raw,
            field: "frontmatter.raw",
            maximumBytes: PlanningLimits.maximumMarkdownBytes,
            allowNewlines: true
        )
        guard fields.count <= PlanningLimits.maximumJSONObjectFields else {
            throw PlanningValidationError.unsafeValue("frontmatter.fields")
        }
        var keys = Set<String>()
        for field in fields {
            guard keys.insert(field.key.lowercased()).inserted else {
                throw PlanningValidationError.caseCollision("frontmatter.key")
            }
        }
        self.status = status
        self.raw = raw
        self.fields = fields
    }

    public func value(forKey key: String) -> String? {
        fields.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PlanningAnyCodingKey.self)
        let status = try container.decode(PlanningMarkdownFrontmatterStatus.self, forKey: planningCodingKey("status"))
        let raw = try container.decode(String.self, forKey: planningCodingKey("raw"))
        let fields = try container.decode([PlanningMarkdownFrontmatterField].self, forKey: planningCodingKey("fields"))
        try self.init(status: status, raw: raw, fields: fields)
    }

    public func encode(to encoder: Encoder) throws {
        _ = try Self(status: status, raw: raw, fields: fields)
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(status, forKey: planningCodingKey("status"))
        try container.encode(raw, forKey: planningCodingKey("raw"))
        try container.encode(fields, forKey: planningCodingKey("fields"))
    }
}

public struct PlanningMarkdownNote: Codable, Equatable, Sendable {
    public let relativePath: PlanningRelativePath
    public let title: String
    public let frontmatter: PlanningMarkdownFrontmatter
    public let body: String
    public let source: String

    internal init(
        relativePath: PlanningRelativePath,
        title: String,
        frontmatter: PlanningMarkdownFrontmatter,
        body: String,
        source: String
    ) throws {
        try PlanningValidation.validateSafeString(
            title,
            field: "title",
            maximumBytes: PlanningLimits.maximumTitleBytes
        )
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlanningValidationError.invalidTitle
        }
        guard source.utf8.count <= PlanningLimits.maximumMarkdownBytes else {
            throw PlanningValidationError.inputTooLarge
        }
        guard !source.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw PlanningValidationError.unsafeValue("markdown.source")
        }
        try PlanningValidation.validateSafeString(
            body,
            field: "markdown.body",
            maximumBytes: PlanningLimits.maximumMarkdownBytes,
            allowNewlines: true
        )
        self.relativePath = relativePath
        self.title = title
        self.frontmatter = frontmatter
        self.body = body
        self.source = source
    }

    public var contentDigest: String {
        PlanningDigest.hex(Data(source.utf8))
    }

    public var revision: String {
        contentDigest
    }

    public func encodedData() throws -> Data {
        try PlanningMarkdownCodec.encode(self)
    }
}
