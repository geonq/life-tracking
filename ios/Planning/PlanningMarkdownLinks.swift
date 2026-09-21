import Foundation

/// A byte offset into the original UTF-8 Markdown source. Keeping offsets in
/// bytes means a scanner can report exact source locations without rebuilding
/// or normalising the user's text.
public struct PlanningMarkdownSourceRange: Codable, Equatable, Hashable, Sendable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) throws {
        guard start >= 0, end >= start else {
            throw PlanningValidationError.invalidDocument
        }
        self.start = start
        self.end = end
    }

    public var length: Int { end - start }
}

public enum PlanningMarkdownLinkKind: String, Codable, Equatable, Sendable {
    case wikilink
    case inlineMarkdown
    case referenceMarkdown
}

public enum PlanningMarkdownDiagnosticCode: String, Codable, Equatable, Sendable {
    case inputTooLarge
    case unterminatedFence
    case unterminatedInlineCode
    case unterminatedComment
    case malformedLink
    case unsupportedLinkSyntax
    case unresolvedReferenceDefinition
    case occurrenceLimit
}

public struct PlanningMarkdownLinkDiagnostic: Codable, Equatable, Sendable {
    public let code: PlanningMarkdownDiagnosticCode
    public let range: PlanningMarkdownSourceRange
    public let message: String

    public init(
        code: PlanningMarkdownDiagnosticCode,
        range: PlanningMarkdownSourceRange,
        message: String
    ) {
        self.code = code
        self.range = range
        self.message = message
    }
}

public struct PlanningMarkdownLinkOccurrence: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let kind: PlanningMarkdownLinkKind
    public let sourceRange: PlanningMarkdownSourceRange
    public let targetRange: PlanningMarkdownSourceRange?
    /// The destination exactly as authored, after surrounding Markdown
    /// whitespace and angle delimiters have been removed. It is deliberately
    /// not normalised or resolved by the scanner.
    public let rawTarget: String
    public let alias: String?
    public let anchor: String?
    /// The complete fragment beginning with `#`, when one was authored.
    public let subpath: String?
    public let isEmbed: Bool
    /// A normalised reference label for `[text][label]`, `[text][]`, or a
    /// shortcut reference. It is retained even when its definition is absent.
    public let referenceLabel: String?

    public init(
        id: Int,
        kind: PlanningMarkdownLinkKind,
        sourceRange: PlanningMarkdownSourceRange,
        targetRange: PlanningMarkdownSourceRange? = nil,
        rawTarget: String,
        alias: String? = nil,
        anchor: String? = nil,
        subpath: String? = nil,
        isEmbed: Bool = false,
        referenceLabel: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sourceRange = sourceRange
        self.targetRange = targetRange
        self.rawTarget = rawTarget
        self.alias = alias
        self.anchor = anchor
        self.subpath = subpath
        self.isEmbed = isEmbed
        self.referenceLabel = referenceLabel
    }
}

public struct PlanningMarkdownLinkScan: Codable, Equatable, Sendable {
    public let sourceByteCount: Int
    public let occurrences: [PlanningMarkdownLinkOccurrence]
    public let diagnostics: [PlanningMarkdownLinkDiagnostic]
    public let isComplete: Bool

    public init(
        sourceByteCount: Int,
        occurrences: [PlanningMarkdownLinkOccurrence],
        diagnostics: [PlanningMarkdownLinkDiagnostic],
        isComplete: Bool
    ) {
        self.sourceByteCount = sourceByteCount
        self.occurrences = occurrences
        self.diagnostics = diagnostics
        self.isComplete = isComplete
    }
}

/// A bounded, non-regex Markdown link scanner. It intentionally implements a
/// small, explicit subset of Markdown/Obsidian syntax; unsupported constructs
/// remain in the source and are reported as diagnostics instead of guessed at.
public enum PlanningMarkdownLinkScanner {
    public static let maximumSourceBytes = 32 * 1024 * 1024
    public static let maximumOccurrences = 40_000
    public static let maximumDiagnostics = 512

    public static func scan(source: String) -> PlanningMarkdownLinkScan {
        let sourceByteCount = source.utf8.count
        guard sourceByteCount <= maximumSourceBytes else {
            let range = try! PlanningMarkdownSourceRange(start: 0, end: sourceByteCount)
            return PlanningMarkdownLinkScan(
                sourceByteCount: sourceByteCount,
                occurrences: [],
                diagnostics: [PlanningMarkdownLinkDiagnostic(
                    code: .inputTooLarge,
                    range: range,
                    message: "Markdown link scanning is bounded to 32 MiB."
                )],
                isComplete: false
            )
        }

        let bytes = Array(source.utf8)
        var scanner = Scanner(bytes: bytes)
        return scanner.run()
    }
}

private struct Scanner {
    let bytes: [UInt8]
    var occurrences: [PlanningMarkdownLinkOccurrence] = []
    var diagnostics: [PlanningMarkdownLinkDiagnostic] = []
    var referenceDefinitions: [String: Definition] = [:]
    var pendingReferences: [PendingReference] = []
    var complete = true
    var nextOccurrenceID = 0

    struct Definition {
        let target: String
        let targetRange: PlanningMarkdownSourceRange
        let anchor: String?
        let subpath: String?
    }

    struct PendingReference {
        let occurrenceIndex: Int
        let label: String
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func run() -> PlanningMarkdownLinkScan {
        var index = 0
        var lineStart = true
        var fenceCharacter: UInt8?
        var fenceLength = 0

        while index < bytes.count {
            if lineStart {
                if let activeFence = fenceCharacter,
                   isClosingFence(at: index, character: activeFence, minimumLength: fenceLength) {
                    fenceCharacter = nil
                    fenceLength = 0
                    index = endOfLine(from: index)
                    lineStart = true
                    continue
                }

                if fenceCharacter == nil, let fence = parseFence(at: index) {
                    fenceCharacter = fence.character
                    fenceLength = fence.length
                    index = endOfLine(from: index)
                    lineStart = true
                    continue
                }

                if fenceCharacter != nil {
                    index = endOfLine(from: index)
                    lineStart = true
                    continue
                }

                if let definition = parseReferenceDefinition(at: index) {
                    referenceDefinitions[definition.label] = definition.definition
                    index = endOfLine(from: index)
                    lineStart = true
                    continue
                }
            }

            if fenceCharacter != nil {
                index = endOfLine(from: index)
                lineStart = true
                continue
            }

            if bytes[index] == 0x0A {
                index += 1
                lineStart = true
                continue
            }

            if bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0D {
                index += 1
                continue
            }

            if matches("<!--", at: index) {
                guard let close = find("-->", from: index + 4) else {
                    addDiagnostic(
                        code: .unterminatedComment,
                        start: index,
                        end: bytes.count,
                        message: "The HTML comment has no closing delimiter."
                    )
                    complete = false
                    break
                }
                index = close + 3
                lineStart = false
                continue
            }

            if bytes[index] == 0x60 {
                let runLength = runLength(of: 0x60, at: index)
                guard let close = findBacktickRun(length: runLength, from: index + runLength) else {
                    addDiagnostic(
                        code: .unterminatedInlineCode,
                        start: index,
                        end: bytes.count,
                        message: "The inline code span has no closing delimiter."
                    )
                    complete = false
                    break
                }
                index = close + runLength
                lineStart = false
                continue
            }

            if bytes[index] == 0x5C {
                index = min(index + 2, bytes.count)
                lineStart = false
                continue
            }

            if bytes[index] == 0x21, index + 2 < bytes.count,
               bytes[index + 1] == 0x5B, bytes[index + 2] == 0x5B {
                if let end = find("\u{005D}\u{005D}", from: index + 3) {
                    addWikiOccurrence(start: index, end: end + 2, targetStart: index + 3, targetEnd: end)
                    index = end + 2
                } else {
                    addDiagnostic(
                        code: .malformedLink,
                        start: index,
                        end: bytes.count,
                        message: "The Obsidian embed has no closing `]]`."
                    )
                    index = bytes.count
                }
                lineStart = false
                continue
            }

            if bytes[index] == 0x5B, index + 1 < bytes.count, bytes[index + 1] == 0x5B {
                if let end = find("\u{005D}\u{005D}", from: index + 2) {
                    addWikiOccurrence(start: index, end: end + 2, targetStart: index + 2, targetEnd: end)
                    index = end + 2
                } else {
                    addDiagnostic(
                        code: .malformedLink,
                        start: index,
                        end: bytes.count,
                        message: "The Obsidian wikilink has no closing `]]`."
                    )
                    index = bytes.count
                }
                lineStart = false
                continue
            }

            if bytes[index] == 0x5B {
                if let parsed = parseMarkdownLink(at: index) {
                    if let occurrence = parsed.occurrence {
                        append(occurrence)
                    }
                    if let pending = parsed.pending {
                        let occurrence = makeOccurrence(
                            kind: .referenceMarkdown,
                            start: index,
                            end: parsed.end,
                            targetStart: parsed.targetStart,
                            targetEnd: parsed.targetEnd,
                            rawTarget: pending.definitionTarget ?? "",
                            alias: parsed.alias,
                            anchor: pending.definitionAnchor,
                            subpath: pending.definitionSubpath,
                            referenceLabel: pending.label
                        )
                        let occurrenceIndex = occurrences.count
                        if append(occurrence), pending.definitionTarget == nil {
                            pendingReferences.append(PendingReference(
                                occurrenceIndex: occurrenceIndex,
                                label: pending.label
                            ))
                        }
                    }
                    index = parsed.end
                    lineStart = false
                    continue
                }
            }

            lineStart = false
            index += 1
        }

        resolvePendingReferences()
        if fenceCharacter != nil {
            addDiagnostic(
                code: .unterminatedFence,
                start: max(0, bytes.count - 1),
                end: bytes.count,
                message: "The fenced code block has no closing fence."
            )
            complete = false
        }
        return PlanningMarkdownLinkScan(
            sourceByteCount: bytes.count,
            occurrences: occurrences,
            diagnostics: diagnostics,
            isComplete: complete
        )
    }

    private func parseFence(at index: Int) -> (character: UInt8, length: Int)? {
        var cursor = index
        var spaces = 0
        while cursor < bytes.count, spaces < 4, (bytes[cursor] == 0x20 || bytes[cursor] == 0x09) {
            cursor += 1
            spaces += 1
        }
        guard spaces <= 3, cursor < bytes.count,
              bytes[cursor] == 0x60 || bytes[cursor] == 0x7E else { return nil }
        let character = bytes[cursor]
        let length = runLength(of: character, at: cursor)
        guard length >= 3 else { return nil }
        return (character, length)
    }

    private func isClosingFence(at index: Int, character: UInt8, minimumLength: Int) -> Bool {
        var cursor = index
        var spaces = 0
        while cursor < bytes.count, spaces < 4, (bytes[cursor] == 0x20 || bytes[cursor] == 0x09) {
            cursor += 1
            spaces += 1
        }
        guard spaces <= 3, cursor < bytes.count, bytes[cursor] == character else { return false }
        let length = runLength(of: character, at: cursor)
        guard length >= minimumLength else { return false }
        cursor += length
        while cursor < bytes.count,
              bytes[cursor] == 0x20 || bytes[cursor] == 0x09 || bytes[cursor] == 0x0D {
            cursor += 1
        }
        return cursor == bytes.count || bytes[cursor] == 0x0A
    }

    private func parseReferenceDefinition(at index: Int) -> (label: String, definition: Definition)? {
        var cursor = index
        var spaces = 0
        while cursor < bytes.count, spaces < 4, (bytes[cursor] == 0x20 || bytes[cursor] == 0x09) {
            cursor += 1
            spaces += 1
        }
        guard spaces <= 3, cursor < bytes.count, bytes[cursor] == 0x5B,
              let close = findByte(0x5D, from: cursor + 1), close + 1 < bytes.count,
              bytes[close + 1] == 0x3A else { return nil }
        let label = normaliseReferenceLabel(string(cursor + 1, close))
        guard !label.isEmpty else { return nil }
        var targetStart = close + 2
        while targetStart < bytes.count, bytes[targetStart] == 0x20 || bytes[targetStart] == 0x09 {
            targetStart += 1
        }
        guard targetStart < bytes.count else { return nil }
        let targetEnd: Int
        if bytes[targetStart] == 0x3C {
            guard let closeTarget = findByte(0x3E, from: targetStart + 1) else { return nil }
            targetEnd = closeTarget
            targetStart += 1
        } else {
            var cursorTarget = targetStart
            while cursorTarget < bytes.count,
                  bytes[cursorTarget] != 0x20,
                  bytes[cursorTarget] != 0x09,
                  bytes[cursorTarget] != 0x0A,
                  bytes[cursorTarget] != 0x0D {
                cursorTarget += 1
            }
            targetEnd = cursorTarget
        }
        let rawTarget = string(targetStart, targetEnd).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTarget.isEmpty else { return nil }
        let parsed = parseTarget(rawTarget)
        guard let range = try? PlanningMarkdownSourceRange(start: targetStart, end: targetEnd) else {
            return nil
        }
        return (
            label,
            Definition(
                target: parsed.path,
                targetRange: range,
                anchor: parsed.anchor,
                subpath: parsed.subpath
            )
        )
    }

    private mutating func parseMarkdownLink(at index: Int) -> ParsedMarkdownLink? {
        guard let closeLabel = findUnescapedByte(0x5D, from: index + 1) else {
            addDiagnostic(
                code: .malformedLink,
                start: index,
                end: bytes.count,
                message: "The Markdown link has no closing bracket."
            )
            return ParsedMarkdownLink(end: bytes.count)
        }
        let label = string(index + 1, closeLabel)
        var cursor = closeLabel + 1
        while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 {
            cursor += 1
        }

        if cursor < bytes.count, bytes[cursor] == 0x28 {
            guard let closeDestination = closingParenthesis(from: cursor) else {
                addDiagnostic(
                    code: .malformedLink,
                    start: index,
                    end: min(cursor + 1, bytes.count),
                    message: "The Markdown link has no closing parenthesis."
                )
                // `closingParenthesis` has already scanned the entire remaining
                // suffix. Consume it here so repeated malformed links cannot
                // rescan the same bytes quadratically.
                return ParsedMarkdownLink(end: bytes.count)
            }
            let rawDestinationStart: Int
            let rawDestinationEnd: Int
            let titleStart: Int
            var destinationStart = cursor + 1
            while destinationStart < closeDestination, isInlineWhitespace(bytes[destinationStart]) {
                destinationStart += 1
            }
            if destinationStart < closeDestination, bytes[destinationStart] == 0x3C {
                guard let angleEnd = findByte(0x3E, from: destinationStart + 1), angleEnd < closeDestination else {
                    addDiagnostic(
                        code: .malformedLink,
                        start: index,
                        end: closeDestination + 1,
                        message: "The Markdown destination has an invalid angle delimiter."
                    )
                    return ParsedMarkdownLink(end: closeDestination + 1)
                }
                rawDestinationStart = destinationStart + 1
                rawDestinationEnd = angleEnd
                titleStart = angleEnd + 1
            } else {
                rawDestinationStart = destinationStart
                var destinationEnd = destinationStart
                while destinationEnd < closeDestination, !isInlineWhitespace(bytes[destinationEnd]) {
                    destinationEnd += 1
                }
                rawDestinationEnd = destinationEnd
                titleStart = destinationEnd
            }
            guard hasValidInlineTitle(from: titleStart, to: closeDestination) else {
                addDiagnostic(
                    code: .unsupportedLinkSyntax,
                    start: index,
                    end: closeDestination + 1,
                    message: "The Markdown link has an unsupported destination or title."
                )
                return ParsedMarkdownLink(end: closeDestination + 1)
            }
            let raw = string(rawDestinationStart, rawDestinationEnd)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                addDiagnostic(
                    code: .malformedLink,
                    start: index,
                    end: closeDestination + 1,
                    message: "The Markdown destination is empty."
                )
                return ParsedMarkdownLink(end: closeDestination + 1)
            }
            let target = parseTarget(raw)
            let sourceRange = try! PlanningMarkdownSourceRange(start: index, end: closeDestination + 1)
            let targetRange = try? PlanningMarkdownSourceRange(
                start: rawDestinationStart,
                end: rawDestinationEnd
            )
            return ParsedMarkdownLink(
                end: closeDestination + 1,
                occurrence: makeOccurrence(
                    kind: .inlineMarkdown,
                    start: sourceRange.start,
                    end: sourceRange.end,
                    targetStart: targetRange?.start,
                    targetEnd: targetRange?.end,
                    rawTarget: target.path,
                    alias: label.isEmpty ? nil : label,
                    anchor: target.anchor,
                    subpath: target.subpath,
                    referenceLabel: nil
                )
            )
        }

        if cursor < bytes.count, bytes[cursor] == 0x5B,
           let closeReference = findUnescapedByte(0x5D, from: cursor + 1) {
            let referenceText = string(cursor + 1, closeReference)
            let referenceLabel = normaliseReferenceLabel(referenceText.isEmpty ? label : referenceText)
            guard !referenceLabel.isEmpty else {
                addDiagnostic(
                    code: .malformedLink,
                    start: index,
                    end: closeReference + 1,
                    message: "The Markdown reference label is empty."
                )
                return ParsedMarkdownLink(end: closeReference + 1)
            }
            let definition = referenceDefinitions[referenceLabel]
            return ParsedMarkdownLink(
                end: closeReference + 1,
                pending: PendingDestination(
                    label: referenceLabel,
                    definitionTarget: definition?.target,
                    definitionAnchor: definition?.anchor,
                    definitionSubpath: definition?.subpath
                ),
                targetStart: definition?.targetRange.start,
                targetEnd: definition?.targetRange.end,
                alias: label.isEmpty ? nil : label
            )
        }

        let shortcutLabel = normaliseReferenceLabel(label)
        guard !shortcutLabel.isEmpty else {
            return nil
        }
        let definition = referenceDefinitions[shortcutLabel]
        return ParsedMarkdownLink(
            end: closeLabel + 1,
            pending: PendingDestination(
                label: shortcutLabel,
                definitionTarget: definition?.target,
                definitionAnchor: definition?.anchor,
                definitionSubpath: definition?.subpath
            ),
            targetStart: definition?.targetRange.start,
            targetEnd: definition?.targetRange.end,
            alias: label.isEmpty ? nil : label
        )
    }

    private struct ParsedMarkdownLink {
        let end: Int
        let occurrence: PlanningMarkdownLinkOccurrence?
        let pending: PendingDestination?
        let targetStart: Int?
        let targetEnd: Int?
        let alias: String?

        init(
            end: Int,
            occurrence: PlanningMarkdownLinkOccurrence? = nil,
            pending: PendingDestination? = nil,
            targetStart: Int? = nil,
            targetEnd: Int? = nil,
            alias: String? = nil
        ) {
            self.end = end
            self.occurrence = occurrence
            self.pending = pending
            self.targetStart = targetStart
            self.targetEnd = targetEnd
            self.alias = alias
        }
    }

    private struct PendingDestination {
        let label: String
        let definitionTarget: String?
        let definitionAnchor: String?
        let definitionSubpath: String?
    }

    private mutating func addWikiOccurrence(start: Int, end: Int, targetStart: Int, targetEnd: Int) {
        let rawContent = string(targetStart, targetEnd)
        let pieces = splitWikiContent(rawContent)
        let target = parseTarget(pieces.target)
        append(makeOccurrence(
            kind: .wikilink,
            start: start,
            end: end,
            targetStart: targetStart,
            targetEnd: targetEnd,
            rawTarget: target.path,
            alias: pieces.alias,
            anchor: target.anchor,
            subpath: target.subpath,
            isEmbed: bytes[start] == 0x21,
            referenceLabel: nil
        ))
    }

    private func splitWikiContent(_ content: String) -> (target: String, alias: String?) {
        var escaped = false
        for index in content.indices {
            let character = content[index]
            if character == "|" && !escaped {
                let target = String(content[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                let alias = String(content[content.index(after: index)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (target, alias.isEmpty ? nil : alias)
            }
            if character == "\\" {
                escaped.toggle()
            } else {
                escaped = false
            }
        }
        return (content.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    private func parseTarget(_ raw: String) -> (path: String, anchor: String?, subpath: String?) {
        guard let hash = raw.firstIndex(of: "#") else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), nil, nil)
        }
        let path = String(raw[..<hash]).trimmingCharacters(in: .whitespacesAndNewlines)
        let fragment = String(raw[hash...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor = fragment.dropFirst().isEmpty ? nil : String(fragment.dropFirst())
        return (path, anchor, fragment.isEmpty ? nil : fragment)
    }

    private mutating func resolvePendingReferences() {
        for pending in pendingReferences {
            guard occurrences.indices.contains(pending.occurrenceIndex) else { continue }
            guard let definition = referenceDefinitions[pending.label] else {
                addDiagnostic(
                    code: .unresolvedReferenceDefinition,
                    start: occurrences[pending.occurrenceIndex].sourceRange.start,
                    end: occurrences[pending.occurrenceIndex].sourceRange.end,
                    message: "No Markdown reference definition exists for `\(pending.label)`."
                )
                continue
            }
            let old = occurrences[pending.occurrenceIndex]
            occurrences[pending.occurrenceIndex] = PlanningMarkdownLinkOccurrence(
                id: old.id,
                kind: old.kind,
                sourceRange: old.sourceRange,
                targetRange: definition.targetRange,
                rawTarget: definition.target,
                alias: old.alias,
                anchor: definition.anchor,
                subpath: definition.subpath,
                isEmbed: old.isEmbed,
                referenceLabel: old.referenceLabel
            )
        }
    }

    @discardableResult
    private mutating func append(_ occurrence: PlanningMarkdownLinkOccurrence) -> Bool {
        guard occurrences.count < PlanningMarkdownLinkScanner.maximumOccurrences else {
            complete = false
            addDiagnostic(
                code: .occurrenceLimit,
                start: occurrence.sourceRange.start,
                end: occurrence.sourceRange.end,
                message: "Markdown link scanning reached its bounded occurrence limit."
            )
            return false
        }
        occurrences.append(occurrence)
        nextOccurrenceID += 1
        return true
    }

    private func makeOccurrence(
        kind: PlanningMarkdownLinkKind,
        start: Int,
        end: Int,
        targetStart: Int?,
        targetEnd: Int?,
        rawTarget: String,
        alias: String?,
        anchor: String?,
        subpath: String?,
        isEmbed: Bool = false,
        referenceLabel: String?
    ) -> PlanningMarkdownLinkOccurrence {
        PlanningMarkdownLinkOccurrence(
            id: nextOccurrenceID,
            kind: kind,
            sourceRange: try! PlanningMarkdownSourceRange(start: start, end: end),
            targetRange: targetStart.flatMap { start in
                targetEnd.flatMap { end in try? PlanningMarkdownSourceRange(start: start, end: end) }
            },
            rawTarget: rawTarget,
            alias: alias,
            anchor: anchor,
            subpath: subpath,
            isEmbed: isEmbed,
            referenceLabel: referenceLabel
        )
    }

    private mutating func addDiagnostic(
        code: PlanningMarkdownDiagnosticCode,
        start: Int,
        end: Int,
        message: String
    ) {
        guard diagnostics.count < PlanningMarkdownLinkScanner.maximumDiagnostics else {
            complete = false
            return
        }
        diagnostics.append(PlanningMarkdownLinkDiagnostic(
            code: code,
            range: try! PlanningMarkdownSourceRange(start: max(0, start), end: max(start, end)),
            message: message
        ))
    }

    private func find(_ literal: String, from start: Int) -> Int? {
        let needle = Array(literal.utf8)
        guard !needle.isEmpty, start >= 0, start + needle.count <= bytes.count else { return nil }
        var index = start
        while index + needle.count <= bytes.count {
            if bytes[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }

    private func findByte(_ byte: UInt8, from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        for index in start..<bytes.count where bytes[index] == byte { return index }
        return nil
    }

    private func findUnescapedByte(_ byte: UInt8, from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        var index = start
        while index < bytes.count {
            if bytes[index] == byte, !isEscaped(at: index) { return index }
            index += 1
        }
        return nil
    }

    private func closingParenthesis(from open: Int) -> Int? {
        var depth = 0
        var inAngleDestination = false
        var quote: UInt8?
        var index = open
        while index < bytes.count {
            if bytes[index] == 0x5C {
                index += 2
                continue
            }
            if let activeQuote = quote {
                if bytes[index] == activeQuote { quote = nil }
                index += 1
                continue
            }
            if inAngleDestination {
                if bytes[index] == 0x3E { inAngleDestination = false }
                index += 1
                continue
            }
            if bytes[index] == 0x28 {
                depth += 1
            } else if bytes[index] == 0x3C, depth == 1 {
                inAngleDestination = true
            } else if bytes[index] == 0x22 || bytes[index] == 0x27, depth == 1 {
                quote = bytes[index]
            } else if bytes[index] == 0x29 {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private func hasValidInlineTitle(from start: Int, to end: Int) -> Bool {
        var cursor = start
        while cursor < end, isInlineWhitespace(bytes[cursor]) {
            cursor += 1
        }
        guard cursor < end else { return true }

        let opening = bytes[cursor]
        guard opening == 0x22 || opening == 0x27 || opening == 0x28 else { return false }
        let closing = opening == 0x28 ? UInt8(0x29) : opening
        var depth = opening == 0x28 ? 1 : 0
        cursor += 1
        while cursor < end {
            if bytes[cursor] == 0x5C {
                cursor += min(2, end - cursor)
                continue
            }
            if bytes[cursor] == opening, opening == 0x28 {
                depth += 1
            } else if bytes[cursor] == closing {
                if opening == 0x28 {
                    depth -= 1
                    if depth == 0 {
                        cursor += 1
                        while cursor < end, isInlineWhitespace(bytes[cursor]) {
                            cursor += 1
                        }
                        return cursor == end
                    }
                } else {
                    cursor += 1
                    while cursor < end, isInlineWhitespace(bytes[cursor]) {
                        cursor += 1
                    }
                    return cursor == end
                }
            }
            cursor += 1
        }
        return false
    }

    private func findBacktickRun(length: Int, from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        var index = start
        while index + length <= bytes.count {
            let beginsRun = index == 0 || bytes[index - 1] != 0x60
            if beginsRun,
               bytes[index..<(index + length)].allSatisfy({ $0 == 0x60 }),
               runLength(of: 0x60, at: index) == length {
                return index
            }
            index += 1
        }
        return nil
    }

    private func runLength(of byte: UInt8, at start: Int) -> Int {
        var index = start
        while index < bytes.count, bytes[index] == byte { index += 1 }
        return index - start
    }

    private func isInlineWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private func endOfLine(from start: Int) -> Int {
        var index = start
        while index < bytes.count, bytes[index] != 0x0A { index += 1 }
        return index < bytes.count ? index + 1 : index
    }

    private func matches(_ literal: String, at start: Int) -> Bool {
        let needle = Array(literal.utf8)
        guard start >= 0, start + needle.count <= bytes.count else { return false }
        return bytes[start..<(start + needle.count)].elementsEqual(needle)
    }

    private func isEscaped(at index: Int) -> Bool {
        var cursor = index - 1
        var slashCount = 0
        while cursor >= 0, bytes[cursor] == 0x5C {
            slashCount += 1
            cursor -= 1
        }
        return slashCount % 2 == 1
    }

    private func string(_ start: Int, _ end: Int) -> String {
        guard start >= 0, end >= start, start <= bytes.count else { return "" }
        let boundedEnd = min(end, bytes.count)
        return String(decoding: bytes[start..<boundedEnd], as: UTF8.self)
    }

    private func normaliseReferenceLabel(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}
