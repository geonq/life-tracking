import Foundation

public enum PlanningCanvasCodec {
    public static func decode(_ data: Data) throws -> PlanningCanvasDocument {
        guard data.count <= PlanningLimits.maximumCanvasBytes else {
            throw PlanningValidationError.inputTooLarge
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw PlanningValidationError.invalidUTF8
        }

        var parser = PlanningJSONParser(data: data)
        let root = try parser.parse()
        guard case .object(let values) = root else {
            throw PlanningValidationError.invalidDocument
        }

        let nodes: [PlanningCanvasNode]
        if let rawNodes = values["nodes"] {
            guard case .array(let entries) = rawNodes else {
                throw PlanningValidationError.invalidDocument
            }
            nodes = try entries.map { try decodeNode($0) }
        } else {
            nodes = []
        }

        let edges: [PlanningCanvasEdge]
        if let rawEdges = values["edges"] {
            guard case .array(let entries) = rawEdges else {
                throw PlanningValidationError.invalidDocument
            }
            edges = try entries.map { try decodeEdge($0) }
        } else {
            edges = []
        }

        var unknownFields = values
        unknownFields.removeValue(forKey: "nodes")
        unknownFields.removeValue(forKey: "edges")
        return try PlanningCanvasDocument(nodes: nodes, edges: edges, unknownFields: unknownFields)
    }

    public static func encode(_ document: PlanningCanvasDocument) throws -> Data {
        let raw = try rawDocument(document)
        // Preflight the exact bounded output size before allocating the final
        // Data buffer. This protects callers that construct large documents in
        // memory rather than first decoding a bounded input payload.
        let size = try raw.encodedJSONSize()
        guard size <= PlanningLimits.maximumCanvasBytes else {
            throw PlanningValidationError.inputTooLarge
        }
        var data = Data(capacity: size)
        try raw.appendEncoded(to: &data)
        guard data.count == size, data.count <= PlanningLimits.maximumCanvasBytes else {
            throw PlanningValidationError.inputTooLarge
        }
        return data
    }

    private static func decodeNode(_ value: PlanningJSONValue) throws -> PlanningCanvasNode {
        guard case .object(let fields) = value else {
            throw PlanningValidationError.invalidDocument
        }
        let id = try requiredString(fields, key: "id")
        let typeRawValue = try requiredString(fields, key: "type")
        guard let type = PlanningCanvasNodeType(rawValue: typeRawValue) else {
            throw PlanningValidationError.unsupportedNodeType(typeRawValue)
        }

        let x = try requiredInteger(fields, key: "x", field: "node.x")
        let y = try requiredInteger(fields, key: "y", field: "node.y")
        let width = try requiredInteger(fields, key: "width", field: "node.width")
        let height = try requiredInteger(fields, key: "height", field: "node.height")
        let color = try optionalString(fields, key: "color")
        let text = try optionalString(fields, key: "text")
        let file = try optionalString(fields, key: "file")
        let subpath = try optionalString(fields, key: "subpath")
        let url = try optionalString(fields, key: "url")
        let label = try optionalString(fields, key: "label")
        let background = try optionalString(fields, key: "background")
        let backgroundStyle = try optionalString(fields, key: "backgroundStyle")
        let borderWidth = try optionalNumber(fields, key: "borderWidth", field: "node.borderWidth")
        let borderStyle = try optionalString(fields, key: "borderStyle")
        let extensionFields = fields.filter { planningCanvasNodeExtensionKeys.contains($0.key) }
        let unknownFields = unknownFields(from: fields, known: planningCanvasNodeKeys)

        return try PlanningCanvasNode(
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
            borderWidth: borderWidth,
            borderStyle: borderStyle,
            unknownFields: unknownFields,
            extensionFields: extensionFields
        )
    }

    private static func decodeEdge(_ value: PlanningJSONValue) throws -> PlanningCanvasEdge {
        guard case .object(let fields) = value else {
            throw PlanningValidationError.invalidDocument
        }
        let id = try requiredString(fields, key: "id")
        let fromNode = try requiredString(fields, key: "fromNode")
        let fromSide = try optionalString(fields, key: "fromSide")
        let fromEnd = try optionalString(fields, key: "fromEnd")
        let toNode = try requiredString(fields, key: "toNode")
        let toSide = try optionalString(fields, key: "toSide")
        let toEnd = try optionalString(fields, key: "toEnd")
        let color = try optionalString(fields, key: "color")
        let label = try optionalString(fields, key: "label")
        let unknownFields = unknownFields(from: fields, known: planningCanvasEdgeKeys)

        return try PlanningCanvasEdge(
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
    }

    private static func rawDocument(_ document: PlanningCanvasDocument) throws -> PlanningJSONValue {
        // Re-run all document-level validation, including cross-reference path
        // collision checks, for values assembled directly by a caller.
        _ = try PlanningCanvasDocument(
            nodes: document.nodes,
            edges: document.edges,
            unknownFields: document.unknownFields
        )

        var values: [String: PlanningJSONValue] = [
            "nodes": .array(try document.nodes.map(rawNode)),
            "edges": .array(try document.edges.map(rawEdge))
        ]
        try mergeUnknown(document.unknownFields, into: &values, known: planningCanvasDocumentKeys)
        return .object(values)
    }

    private static func rawNode(_ node: PlanningCanvasNode) throws -> PlanningJSONValue {
        var values: [String: PlanningJSONValue] = [
            "id": .string(node.id),
            "type": .string(node.type.rawValue),
            "x": .integer(Int64(node.x)),
            "y": .integer(Int64(node.y)),
            "width": .integer(Int64(node.width)),
            "height": .integer(Int64(node.height))
        ]
        if let color = node.color { values["color"] = .string(color) }
        if let text = node.text { values["text"] = .string(text) }
        if let file = node.file { values["file"] = .string(file) }
        if let subpath = node.subpath { values["subpath"] = .string(subpath) }
        if let url = node.url { values["url"] = .string(url) }
        if let label = node.label { values["label"] = .string(label) }
        if let background = node.background { values["background"] = .string(background) }
        if let backgroundStyle = node.backgroundStyle { values["backgroundStyle"] = .string(backgroundStyle) }
        if let locked = node.extensionFields["locked"] {
            values["locked"] = locked
        } else if let locked = node.locked {
            values["locked"] = .bool(locked)
        }
        if let borderWidth = node.extensionFields["borderWidth"] {
            values["borderWidth"] = borderWidth
        } else if let borderWidth = node.borderWidth {
            values["borderWidth"] = .number(String(borderWidth))
        }
        if let borderStyle = node.extensionFields["borderStyle"] {
            values["borderStyle"] = borderStyle
        } else if let borderStyle = node.borderStyle {
            values["borderStyle"] = .string(borderStyle)
        }
        try mergeCanvasExtensions(node.extensionFields, into: &values)
        try mergeUnknown(node.unknownFields, into: &values, known: planningCanvasNodeKeys)
        return .object(values)
    }

    private static func rawEdge(_ edge: PlanningCanvasEdge) throws -> PlanningJSONValue {
        var values: [String: PlanningJSONValue] = [
            "id": .string(edge.id),
            "fromNode": .string(edge.fromNode),
            "toNode": .string(edge.toNode)
        ]
        if let fromSide = edge.fromSide { values["fromSide"] = .string(fromSide) }
        if let fromEnd = edge.fromEnd { values["fromEnd"] = .string(fromEnd) }
        if let toSide = edge.toSide { values["toSide"] = .string(toSide) }
        if let toEnd = edge.toEnd { values["toEnd"] = .string(toEnd) }
        if let color = edge.color { values["color"] = .string(color) }
        if let label = edge.label { values["label"] = .string(label) }
        try mergeUnknown(edge.unknownFields, into: &values, known: planningCanvasEdgeKeys)
        return .object(values)
    }

    private static func mergeUnknown(
        _ unknown: [String: PlanningJSONValue],
        into values: inout [String: PlanningJSONValue],
        known: Set<String>
    ) throws {
        try PlanningValidation.validateUnknownFields(unknown, known: known)
        for key in unknown.keys.sorted() {
            guard values[key] == nil else {
                throw PlanningValidationError.unsafeValue("unknownField.(key)")
            }
            values[key] = unknown[key]!
        }
    }

    private static func mergeCanvasExtensions(
        _ extensions: [String: PlanningJSONValue],
        into values: inout [String: PlanningJSONValue]
    ) throws {
        try PlanningValidation.validateCanvasExtensionFields(extensions)
        for key in extensions.keys.sorted() {
            guard planningCanvasNodeExtensionKeys.contains(key) else {
                throw PlanningValidationError.unsafeValue("node.extensions.key")
            }
            guard values[key] == nil else { continue }
            values[key] = extensions[key]!
        }
    }

    private static func unknownFields(
        from fields: [String: PlanningJSONValue],
        known: Set<String>
    ) -> [String: PlanningJSONValue] {
        fields.filter { !known.contains($0.key) }
    }

    private static func requiredString(
        _ fields: [String: PlanningJSONValue],
        key: String
    ) throws -> String {
        guard let value = fields[key], case .string(let string) = value else {
            throw PlanningValidationError.invalidDocument
        }
        return string
    }

    private static func optionalString(
        _ fields: [String: PlanningJSONValue],
        key: String
    ) throws -> String? {
        guard let value = fields[key] else { return nil }
        if case .null = value { return nil }
        guard case .string(let string) = value else {
            throw PlanningValidationError.invalidDocument
        }
        return string
    }

    private static func optionalBool(
        _ fields: [String: PlanningJSONValue],
        key: String
    ) throws -> Bool? {
        guard let value = fields[key] else { return nil }
        if case .null = value { return nil }
        guard case .bool(let bool) = value else {
            throw PlanningValidationError.invalidDocument
        }
        return bool
    }

    private static func requiredInteger(
        _ fields: [String: PlanningJSONValue],
        key: String,
        field: String
    ) throws -> Double {
        guard let value = fields[key] else {
            throw PlanningValidationError.invalidDocument
        }
        let integer: Int64?
        switch value {
        case .integer(let value):
            integer = value
        case .number(let raw):
            integer = PlanningJSONNumber.integer(raw)
        default:
            integer = nil
        }
        guard let integer else {
            throw PlanningValidationError.invalidCoordinate(field)
        }
        return Double(integer)
    }

    private static func optionalNumber(
        _ fields: [String: PlanningJSONValue],
        key: String,
        field: String
    ) throws -> Double? {
        guard let value = fields[key] else { return nil }
        if case .null = value { return nil }
        let number: Double?
        switch value {
        case .integer(let integer):
            number = Double(integer)
        case .number(let raw):
            number = Double(raw)
        default:
            number = nil
        }
        guard let number, number.isFinite else {
            throw PlanningValidationError.invalidDimension(field)
        }
        return number
    }
}

/// Small bounded JSON parser used by the Canvas codec so unknown extension
/// values retain their source number lexemes. JSONDecoder exposes numbers only
/// as machine types to nested Codable values, which is insufficient for this
/// round-trip contract.
internal struct PlanningJSONParser {
    private let bytes: [UInt8]
    private var index: Int = 0

    init(data: Data) {
        self.bytes = Array(data)
    }

    mutating func parse() throws -> PlanningJSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw PlanningValidationError.invalidDocument }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> PlanningJSONValue {
        guard depth <= PlanningLimits.maximumJSONDepth, index < bytes.count else {
            throw PlanningValidationError.invalidDocument
        }
        switch bytes[index] {
        case 0x6E: // null
            try expect([0x6E, 0x75, 0x6C, 0x6C])
            return .null
        case 0x74: // true
            try expect([0x74, 0x72, 0x75, 0x65])
            return .bool(true)
        case 0x66: // false
            try expect([0x66, 0x61, 0x6C, 0x73, 0x65])
            return .bool(false)
        case 0x22:
            return try parseString()
        case 0x5B:
            return try parseArray(depth: depth + 1)
        case 0x7B:
            return try parseObject(depth: depth + 1)
        case 0x2D, 0x30...0x39:
            return try parseNumber()
        default:
            throw PlanningValidationError.invalidDocument
        }
    }

    private mutating func parseString() throws -> PlanningJSONValue {
        let start = index
        index += 1 // opening quote
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x20 && !escaped {
                throw PlanningValidationError.invalidDocument
            }
            if byte == 0x22 && !escaped {
                index += 1
                guard index - start <= PlanningLimits.maximumJSONEncodedStringBytes else {
                    throw PlanningValidationError.unsafeValue("json.string")
                }
                let data = Data(bytes[start..<index])
                guard let string = try? JSONDecoder().decode(String.self, from: data) else {
                    throw PlanningValidationError.invalidDocument
                }
                try PlanningValidation.validateJSONString(string)
                return .string(string)
            }
            if byte == 0x5C {
                escaped.toggle()
            } else {
                escaped = false
            }
            index += 1
            guard index - start <= PlanningLimits.maximumJSONEncodedStringBytes else {
                throw PlanningValidationError.unsafeValue("json.string")
            }
        }
        throw PlanningValidationError.invalidDocument
    }

    private mutating func parseNumber() throws -> PlanningJSONValue {
        let start = index
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x2D || byte == 0x2B || byte == 0x2E
                    || (0x30...0x39).contains(byte) || byte == 0x45 || byte == 0x65 else {
                break
            }
            index += 1
            guard index - start <= PlanningJSONNumber.maximumBytes else {
                throw PlanningValidationError.unsafeValue("json.number")
            }
        }
        let raw = String(decoding: bytes[start..<index], as: UTF8.self)
        try PlanningJSONNumber.validate(raw)
        if let integer = PlanningJSONNumber.integer(raw) {
            return .integer(integer)
        }
        return .number(raw)
    }

    private mutating func parseArray(depth: Int) throws -> PlanningJSONValue {
        index += 1 // [
        skipWhitespace()
        var values: [PlanningJSONValue] = []
        if index < bytes.count, bytes[index] == 0x5D {
            index += 1
            return .array(values)
        }
        while true {
            guard values.count < PlanningLimits.maximumJSONArrayItems else {
                throw PlanningValidationError.unsafeValue("json.array")
            }
            values.append(try parseValue(depth: depth))
            skipWhitespace()
            guard index < bytes.count else { throw PlanningValidationError.invalidDocument }
            if bytes[index] == 0x5D {
                index += 1
                return .array(values)
            }
            guard bytes[index] == 0x2C else { throw PlanningValidationError.invalidDocument }
            index += 1
            skipWhitespace()
        }
    }

    private mutating func parseObject(depth: Int) throws -> PlanningJSONValue {
        index += 1 // {
        skipWhitespace()
        var values: [String: PlanningJSONValue] = [:]
        if index < bytes.count, bytes[index] == 0x7D {
            index += 1
            return .object(values)
        }
        while true {
            guard values.count < PlanningLimits.maximumJSONObjectFields else {
                throw PlanningValidationError.unsafeValue("json.object")
            }
            guard let keyValue = try parseString().stringValue else {
                throw PlanningValidationError.invalidDocument
            }
            try PlanningValidation.validateJSONKey(keyValue)
            guard values[keyValue] == nil else {
                throw PlanningValidationError.invalidDocument
            }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x3A else {
                throw PlanningValidationError.invalidDocument
            }
            index += 1
            skipWhitespace()
            values[keyValue] = try parseValue(depth: depth)
            skipWhitespace()
            guard index < bytes.count else { throw PlanningValidationError.invalidDocument }
            if bytes[index] == 0x7D {
                index += 1
                return .object(values)
            }
            guard bytes[index] == 0x2C else { throw PlanningValidationError.invalidDocument }
            index += 1
            skipWhitespace()
        }
    }

    private mutating func expect(_ expected: [UInt8]) throws {
        guard bytes[index...].starts(with: expected) else {
            throw PlanningValidationError.invalidDocument
        }
        index += expected.count
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
    }
}

private extension PlanningJSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

extension PlanningCanvasNode {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PlanningAnyCodingKey.self)
        let id = try container.decode(String.self, forKey: planningCodingKey("id"))
        let typeRawValue = try container.decode(String.self, forKey: planningCodingKey("type"))
        guard let type = PlanningCanvasNodeType(rawValue: typeRawValue) else {
            throw PlanningValidationError.unsupportedNodeType(typeRawValue)
        }

        let x = Double(try container.decode(Int.self, forKey: planningCodingKey("x")))
        let y = Double(try container.decode(Int.self, forKey: planningCodingKey("y")))
        let width = Double(try container.decode(Int.self, forKey: planningCodingKey("width")))
        let height = Double(try container.decode(Int.self, forKey: planningCodingKey("height")))
        let color = try container.decodeIfPresent(String.self, forKey: planningCodingKey("color"))
        let text = try container.decodeIfPresent(String.self, forKey: planningCodingKey("text"))
        let file = try container.decodeIfPresent(String.self, forKey: planningCodingKey("file"))
        let subpath = try container.decodeIfPresent(String.self, forKey: planningCodingKey("subpath"))
        let url = try container.decodeIfPresent(String.self, forKey: planningCodingKey("url"))
        let label = try container.decodeIfPresent(String.self, forKey: planningCodingKey("label"))
        let background = try container.decodeIfPresent(String.self, forKey: planningCodingKey("background"))
        let backgroundStyle = try container.decodeIfPresent(String.self, forKey: planningCodingKey("backgroundStyle"))
        let extensionFields = try planningDecodeCanvasExtensionFields(from: container)
        let locked = try planningTypedExtensionBool(extensionFields, key: "locked")
        let borderWidth = try planningTypedExtensionDouble(extensionFields, key: "borderWidth")
        let borderStyle = try planningTypedExtensionString(extensionFields, key: "borderStyle")
        let unknownFields = try planningUnknownFields(from: container, known: planningCanvasNodeKeys)

        try self.init(
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
            locked: locked,
            background: background,
            backgroundStyle: backgroundStyle,
            borderWidth: borderWidth,
            borderStyle: borderStyle,
            unknownFields: unknownFields,
            extensionFields: extensionFields
        )
    }

    public func encode(to encoder: Encoder) throws {
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
            borderWidth: borderWidth,
            borderStyle: borderStyle,
            unknownFields: unknownFields,
            extensionFields: extensionFields
        )

        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(id, forKey: planningCodingKey("id"))
        try container.encode(type.rawValue, forKey: planningCodingKey("type"))
        try container.encode(Int(x), forKey: planningCodingKey("x"))
        try container.encode(Int(y), forKey: planningCodingKey("y"))
        try container.encode(Int(width), forKey: planningCodingKey("width"))
        try container.encode(Int(height), forKey: planningCodingKey("height"))
        try container.encodeIfPresent(color, forKey: planningCodingKey("color"))
        try container.encodeIfPresent(text, forKey: planningCodingKey("text"))
        try container.encodeIfPresent(file, forKey: planningCodingKey("file"))
        try container.encodeIfPresent(subpath, forKey: planningCodingKey("subpath"))
        try container.encodeIfPresent(url, forKey: planningCodingKey("url"))
        try container.encodeIfPresent(label, forKey: planningCodingKey("label"))
        try container.encodeIfPresent(background, forKey: planningCodingKey("background"))
        try container.encodeIfPresent(backgroundStyle, forKey: planningCodingKey("backgroundStyle"))
        for key in planningCanvasNodeExtensionKeys.sorted() {
            let codingKey = planningCodingKey(key)
            if let raw = extensionFields[key] {
                try container.encode(raw, forKey: codingKey)
                continue
            }
            switch key {
            case "locked":
                try container.encodeIfPresent(locked, forKey: codingKey)
            case "borderWidth":
                try container.encodeIfPresent(borderWidth, forKey: codingKey)
            case "borderStyle":
                try container.encodeIfPresent(borderStyle, forKey: codingKey)
            default:
                break
            }
        }
        try planningEncodeUnknownFields(unknownFields, into: &container, known: planningCanvasNodeKeys)
    }
}

private func planningTypedExtensionBool(
    _ fields: [String: PlanningJSONValue],
    key: String
) throws -> Bool? {
    guard let value = fields[key] else { return nil }
    switch value {
    case .null:
        return nil
    case .bool(let value):
        return value
    default:
        throw PlanningValidationError.invalidDocument
    }
}

private func planningTypedExtensionDouble(
    _ fields: [String: PlanningJSONValue],
    key: String
) throws -> Double? {
    guard let value = fields[key] else { return nil }
    switch value {
    case .null:
        return nil
    case .integer(let value):
        return Double(value)
    case .number(let value):
        guard let value = Double(value), value.isFinite else {
            throw PlanningValidationError.invalidDocument
        }
        return value
    default:
        throw PlanningValidationError.invalidDocument
    }
}

private func planningTypedExtensionString(
    _ fields: [String: PlanningJSONValue],
    key: String
) throws -> String? {
    guard let value = fields[key] else { return nil }
    switch value {
    case .null:
        return nil
    case .string(let value):
        return value
    default:
        throw PlanningValidationError.invalidDocument
    }
}

extension PlanningCanvasEdge {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PlanningAnyCodingKey.self)
        let id = try container.decode(String.self, forKey: planningCodingKey("id"))
        let fromNode = try container.decode(String.self, forKey: planningCodingKey("fromNode"))
        let fromSide = try container.decodeIfPresent(String.self, forKey: planningCodingKey("fromSide"))
        let fromEnd = try container.decodeIfPresent(String.self, forKey: planningCodingKey("fromEnd"))
        let toNode = try container.decode(String.self, forKey: planningCodingKey("toNode"))
        let toSide = try container.decodeIfPresent(String.self, forKey: planningCodingKey("toSide"))
        let toEnd = try container.decodeIfPresent(String.self, forKey: planningCodingKey("toEnd"))
        let color = try container.decodeIfPresent(String.self, forKey: planningCodingKey("color"))
        let label = try container.decodeIfPresent(String.self, forKey: planningCodingKey("label"))
        let unknownFields = try planningUnknownFields(from: container, known: planningCanvasEdgeKeys)

        try self.init(
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
    }

    public func encode(to encoder: Encoder) throws {
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

        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(id, forKey: planningCodingKey("id"))
        try container.encode(fromNode, forKey: planningCodingKey("fromNode"))
        try container.encodeIfPresent(fromSide, forKey: planningCodingKey("fromSide"))
        try container.encodeIfPresent(fromEnd, forKey: planningCodingKey("fromEnd"))
        try container.encode(toNode, forKey: planningCodingKey("toNode"))
        try container.encodeIfPresent(toSide, forKey: planningCodingKey("toSide"))
        try container.encodeIfPresent(toEnd, forKey: planningCodingKey("toEnd"))
        try container.encodeIfPresent(color, forKey: planningCodingKey("color"))
        try container.encodeIfPresent(label, forKey: planningCodingKey("label"))
        try planningEncodeUnknownFields(unknownFields, into: &container, known: planningCanvasEdgeKeys)
    }
}

extension PlanningCanvasDocument {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PlanningAnyCodingKey.self)
        let nodes = try container.decodeIfPresent([PlanningCanvasNode].self, forKey: planningCodingKey("nodes")) ?? []
        let edges = try container.decodeIfPresent([PlanningCanvasEdge].self, forKey: planningCodingKey("edges")) ?? []
        let unknownFields = try planningUnknownFields(from: container, known: planningCanvasDocumentKeys)
        try self.init(nodes: nodes, edges: edges, unknownFields: unknownFields)
    }

    public func encode(to encoder: Encoder) throws {
        _ = try PlanningCanvasDocument(
            nodes: nodes,
            edges: edges,
            unknownFields: unknownFields
        )
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(nodes, forKey: planningCodingKey("nodes"))
        try container.encode(edges, forKey: planningCodingKey("edges"))
        try planningEncodeUnknownFields(unknownFields, into: &container, known: planningCanvasDocumentKeys)
    }
}
