import Foundation

public enum PlanningMarkdownCodec {
    public static func decode(relativePath: String, data: Data) throws -> PlanningMarkdownNote {
        guard data.count <= PlanningLimits.maximumMarkdownBytes else {
            throw PlanningValidationError.inputTooLarge
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw PlanningValidationError.invalidUTF8
        }
        return try decode(relativePath: relativePath, source: source)
    }

    public static func decode(relativePath: String, source: String) throws -> PlanningMarkdownNote {
        guard source.utf8.count <= PlanningLimits.maximumMarkdownBytes else {
            throw PlanningValidationError.inputTooLarge
        }
        guard !source.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw PlanningValidationError.unsafeValue("markdown.source")
        }

        let path = try PlanningRelativePath(relativePath)
        guard path.value.lowercased().hasSuffix(".md") else {
            throw PlanningValidationError.invalidRelativePath("markdown.path")
        }

        let parsed = try parseFrontmatter(source)
        let title = try title(for: path, frontmatter: parsed.frontmatter)
        return try PlanningMarkdownNote(
            relativePath: path,
            title: title,
            frontmatter: parsed.frontmatter,
            body: parsed.body,
            source: source
        )
    }

    public static func encode(_ note: PlanningMarkdownNote) throws -> Data {
        let decoded = try decode(relativePath: note.relativePath.value, source: note.source)
        guard decoded == note else {
            throw PlanningValidationError.invalidDocument
        }
        let data = Data(note.source.utf8)
        guard data.count <= PlanningLimits.maximumMarkdownBytes else {
            throw PlanningValidationError.inputTooLarge
        }
        return data
    }

    private struct ParsedDocument {
        let frontmatter: PlanningMarkdownFrontmatter
        let body: String
    }

    private static func parseFrontmatter(_ source: String) throws -> ParsedDocument {
        let bytes = Array(source.utf8)
        guard let opening = line(in: bytes, from: 0), opening.content == "---" else {
            let frontmatter = try PlanningMarkdownFrontmatter(status: .absent, raw: "", fields: [])
            return ParsedDocument(frontmatter: frontmatter, body: source)
        }

        var cursor = opening.next
        let blockStart = cursor
        var closingLineStart: Int?
        var bodyStart = bytes.count

        while let current = line(in: bytes, from: cursor) {
            if current.content == "---" {
                closingLineStart = cursor
                bodyStart = current.next
                break
            }
            if current.next == cursor {
                break
            }
            cursor = current.next
        }

        guard let closingLineStart else {
            throw PlanningValidationError.invalidFrontmatter("closing delimiter")
        }

        let rawBytes = Array(bytes[blockStart..<closingLineStart])
        let raw = String(decoding: rawBytes, as: UTF8.self)
        let body = String(decoding: bytes[bodyStart..<bytes.count], as: UTF8.self)
        let parsedFields = parseScalarFields(rawBytes)
        let frontmatter = try PlanningMarkdownFrontmatter(
            status: parsedFields.isUnsupported ? .unsupported : .parsed,
            raw: raw,
            fields: parsedFields.fields
        )
        return ParsedDocument(frontmatter: frontmatter, body: body)
    }

    private struct ParsedFields {
        let fields: [PlanningMarkdownFrontmatterField]
        let isUnsupported: Bool
    }

    private static func parseScalarFields(_ raw: [UInt8]) -> ParsedFields {
        var fields: [PlanningMarkdownFrontmatterField] = []
        var keys = Set<String>()
        var unavailableKeys = Set<String>()
        var isUnsupported = false
        var metadataIsAmbiguous = false
        var activePlainScalarKey: String?
        var cursor = 0

        while cursor < raw.count {
            guard let record = line(in: raw, from: cursor) else { break }
            let line = record.content
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                // Keep the active key across blank/comment lines so a later
                // indented continuation cannot be exposed as valid metadata.
                cursor = record.next
                continue
            }

            // Only top-level scalar mappings are understood. In particular,
            // an indented `title:` under a YAML object must never become the
            // note title merely because this bounded parser found a colon.
            guard let first = line.first, first != " " && first != "\t" else {
                isUnsupported = true
                if let activePlainScalarKey {
                    fields.removeAll { $0.key.caseInsensitiveCompare(activePlainScalarKey) == .orderedSame }
                    unavailableKeys.insert(activePlainScalarKey)
                }
                activePlainScalarKey = nil
                cursor = record.next
                continue
            }

            guard let colon = line.firstIndex(of: ":") else {
                isUnsupported = true
                activePlainScalarKey = nil
                cursor = record.next
                continue
            }

            let afterColon = line.index(after: colon)
            guard afterColon == line.endIndex || line[afterColon].isWhitespace else {
                // `title:Hello` is not a mapping in this bounded YAML subset.
                isUnsupported = true
                activePlainScalarKey = nil
                cursor = record.next
                continue
            }

            let rawKey = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String
            if rawKey.hasPrefix("\"") || rawKey.hasPrefix("'") {
                guard let quotedKey = normalizedQuotedFrontmatterKey(rawKey) else {
                    // A quoted key we cannot identify safely could alias a
                    // parsed field (especially `title`). Do not expose any
                    // partial metadata from this frontmatter block.
                    isUnsupported = true
                    metadataIsAmbiguous = true
                    fields.removeAll()
                    keys.removeAll()
                    unavailableKeys.removeAll()
                    activePlainScalarKey = nil
                    cursor = record.next
                    continue
                }
                key = quotedKey
            } else {
                guard (try? PlanningValidation.validateFrontmatterKey(rawKey)) != nil else {
                    isUnsupported = true
                    activePlainScalarKey = nil
                    cursor = record.next
                    continue
                }
                key = rawKey
            }

            let valueWithoutComment = String(line[afterColon...])
            let rawValue = stripInlineComment(valueWithoutComment)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let foldedKey = key.lowercased()

            if unavailableKeys.contains(foldedKey) {
                isUnsupported = true
                fields.removeAll { $0.key.caseInsensitiveCompare(key) == .orderedSame }
                activePlainScalarKey = nil
                cursor = record.next
                continue
            }

            guard keys.insert(foldedKey).inserted else {
                isUnsupported = true
                unavailableKeys.insert(foldedKey)
                fields.removeAll { $0.key.caseInsensitiveCompare(key) == .orderedSame }
                activePlainScalarKey = nil
                cursor = record.next
                continue
            }

            if rawValue.isEmpty {
                isUnsupported = true
                unavailableKeys.insert(foldedKey)
                fields.removeAll { $0.key.caseInsensitiveCompare(key) == .orderedSame }
                activePlainScalarKey = nil
                cursor = record.next
                continue
            }

            if containsUnsupportedPlainScalarSyntax(rawValue) {
                isUnsupported = true
                unavailableKeys.insert(foldedKey)
                fields.removeAll { $0.key.caseInsensitiveCompare(key) == .orderedSame }
                activePlainScalarKey = nil
                cursor = record.next
                continue
            }

            guard let field = try? PlanningMarkdownFrontmatterField(key: key, value: rawValue) else {
                isUnsupported = true
                unavailableKeys.insert(foldedKey)
                fields.removeAll { $0.key.caseInsensitiveCompare(key) == .orderedSame }
                activePlainScalarKey = nil
                cursor = record.next
                continue
            }
            if !metadataIsAmbiguous {
                fields.append(field)
            }
            activePlainScalarKey = foldedKey
            cursor = record.next
        }

        return ParsedFields(
            fields: metadataIsAmbiguous ? [] : fields,
            isUnsupported: isUnsupported
        )
    }

    private static func normalizedQuotedFrontmatterKey(_ rawKey: String) -> String? {
        guard let quote = rawKey.first,
              (quote == "\"" || quote == "'"),
              rawKey.last == quote,
              rawKey.count >= 2 else {
            return nil
        }

        let inner = String(rawKey.dropFirst().dropLast())
        // This deliberately accepts only the identifier subset understood by
        // PlanningMarkdownFrontmatterField. Escapes, embedded quotes, and
        // YAML-specific key syntax remain unsupported instead of being
        // guessed at.
        guard (try? PlanningValidation.validateFrontmatterKey(inner)) != nil else {
            return nil
        }
        return inner
    }

    private static func containsUnsupportedPlainScalarSyntax(_ value: String) -> Bool {
        let characters = Array(value)
        guard let first = characters.first else { return true }
        if ["[", "{", "|", ">", "&", "*", "!", "'", "\"", "%", "@", "`"].contains(first) {
            return true
        }
        if (first == "-" && (characters.count == 1 || characters.dropFirst().first?.isWhitespace == true))
            || (first == "?" && (characters.count == 1 || characters.dropFirst().first?.isWhitespace == true)) {
            return true
        }

        for index in characters.indices {
            let character = characters[index]
            let previousIsWhitespace = index == characters.startIndex || characters[index - 1].isWhitespace
            if previousIsWhitespace && ["&", "*", "!"].contains(character) {
                return true
            }
            if character == ":" {
                let nextIndex = characters.index(after: index)
                if nextIndex == characters.endIndex || characters[nextIndex].isWhitespace {
                    // A colon followed by whitespace is YAML syntax inside a
                    // plain scalar, which this bounded parser does not model.
                    return true
                }
            }
        }
        return false
    }

    private static func stripInlineComment(_ value: String) -> String {
        var previousWasWhitespace = true
        for index in value.indices {
            let character = value[index]
            if character == "#" && previousWasWhitespace {
                return String(value[..<index])
            }
            previousWasWhitespace = character.isWhitespace
        }
        return value
    }

    private static func title(
        for path: PlanningRelativePath,
        frontmatter: PlanningMarkdownFrontmatter
    ) throws -> String {
        if let title = frontmatter.value(forKey: "title") {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PlanningValidationError.invalidTitle
            }
            try PlanningValidation.validateSafeString(
                title,
                field: "title",
                maximumBytes: PlanningLimits.maximumTitleBytes
            )
            return title
        }

        guard let last = path.segments.last else {
            throw PlanningValidationError.invalidTitle
        }
        let stem = last.count >= 3 ? String(last.dropLast(3)) : ""
        guard !stem.isEmpty else {
            throw PlanningValidationError.invalidTitle
        }
        try PlanningValidation.validateSafeString(
            stem,
            field: "title",
            maximumBytes: PlanningLimits.maximumTitleBytes
        )
        return stem
    }

    private static func line(
        in bytes: [UInt8],
        from start: Int
    ) -> (content: String, next: Int)? {
        guard start <= bytes.count else { return nil }
        var end = start
        while end < bytes.count, bytes[end] != 0x0A {
            end += 1
        }
        var contentEnd = end
        if contentEnd > start, bytes[contentEnd - 1] == 0x0D {
            contentEnd -= 1
        }
        let content = String(decoding: bytes[start..<contentEnd], as: UTF8.self)
        let next = end < bytes.count ? end + 1 : end
        return (content: content, next: next)
    }
}

extension PlanningMarkdownNote {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PlanningAnyCodingKey.self)
        let relativePath = try container.decode(PlanningRelativePath.self, forKey: planningCodingKey("relativePath"))
        let title = try container.decode(String.self, forKey: planningCodingKey("title"))
        let frontmatter = try container.decode(PlanningMarkdownFrontmatter.self, forKey: planningCodingKey("frontmatter"))
        let body = try container.decode(String.self, forKey: planningCodingKey("body"))
        let source = try container.decode(String.self, forKey: planningCodingKey("source"))
        let decoded = try PlanningMarkdownCodec.decode(relativePath: relativePath.value, source: source)
        guard decoded.title == title,
              decoded.frontmatter == frontmatter,
              decoded.body == body else {
            throw PlanningValidationError.invalidDocument
        }
        self = decoded
    }

    public func encode(to encoder: Encoder) throws {
        _ = try PlanningMarkdownCodec.encode(self)
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(relativePath, forKey: planningCodingKey("relativePath"))
        try container.encode(title, forKey: planningCodingKey("title"))
        try container.encode(frontmatter, forKey: planningCodingKey("frontmatter"))
        try container.encode(body, forKey: planningCodingKey("body"))
        try container.encode(source, forKey: planningCodingKey("source"))
    }
}
