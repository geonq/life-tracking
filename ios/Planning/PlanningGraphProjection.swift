import Foundation

public enum PlanningGraphError: Error, Equatable, LocalizedError, Sendable {
    case invalidInput(String)
    case inputTooLarge
    case tooManyVertices
    case tooManyRelationships
    case duplicatePath(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let field): return "Invalid planning graph input: " + field + "."
        case .inputTooLarge: return "The planning graph input exceeds its bounded size."
        case .tooManyVertices: return "The planning graph exceeds its vertex limit."
        case .tooManyRelationships: return "The planning graph exceeds its relationship limit."
        case .duplicatePath(let path): return "The planning graph contains a duplicate path: " + path + "."
        }
    }
}

public enum PlanningGraphLimits {
    public static let maximumSourceBytes = 32 * 1024 * 1024
    public static let maximumVertices = 10_000
    public static let maximumRelationships = 40_000
}

public struct PlanningGraphNoteSnapshot: Codable, Equatable, Sendable {
    public let path: PlanningRelativePath
    public let note: PlanningMarkdownNote
    public let bytes: Data
    public let version: PlanningContentVersion

    public init(path: PlanningRelativePath, note: PlanningMarkdownNote, bytes: Data? = nil) throws {
        guard note.relativePath == path else {
            throw PlanningGraphError.invalidInput("note.path")
        }
        let resolvedBytes = bytes ?? Data(note.source.utf8)
        guard resolvedBytes.count <= PlanningStorageLimits.markdownBytes,
              PlanningContentVersion(data: resolvedBytes).matches(resolvedBytes) else {
            throw PlanningGraphError.invalidInput("note.bytes")
        }
        let decoded = try PlanningMarkdownCodec.decode(relativePath: path.value, data: resolvedBytes)
        guard decoded == note else {
            throw PlanningGraphError.invalidInput("note.source")
        }
        self.path = path
        self.note = note
        self.bytes = resolvedBytes
        self.version = PlanningContentVersion(data: resolvedBytes)
    }

    public init(path: String, source: String) throws {
        let relativePath = try PlanningRelativePath(path)
        let note = try PlanningMarkdownCodec.decode(relativePath: relativePath.value, source: source)
        try self.init(path: relativePath, note: note)
    }

    public init(snapshot: PlanningDocumentSnapshot) throws {
        guard snapshot.path.isMarkdown else {
            throw PlanningGraphError.invalidInput("note.snapshot.path")
        }
        let note = try PlanningMarkdownCodec.decode(relativePath: snapshot.path.value, data: snapshot.bytes)
        let path = try PlanningRelativePath(snapshot.path.value)
        try self.init(path: path, note: note, bytes: snapshot.bytes)
    }
}

public struct PlanningReferenceCatalogue: Codable, Equatable, Sendable {
    public let paths: [PlanningRelativePath]
    /// `false` means this is a bounded partial catalogue. A failed lookup is
    /// then `notLoaded`, never silently reported as missing.
    public let isComplete: Bool

    public init(paths: [PlanningRelativePath], isComplete: Bool) throws {
        guard paths.count <= PlanningGraphLimits.maximumVertices else {
            throw PlanningGraphError.tooManyVertices
        }
        var seen = Set<String>()
        for path in paths {
            guard seen.insert(PlanningValidation.normalizedReferencePath(path.value)).inserted else {
                throw PlanningGraphError.duplicatePath(path.value)
            }
        }
        self.paths = paths
        self.isComplete = isComplete
    }

    public init(paths: [String], isComplete: Bool) throws {
        try self.init(paths: try paths.map(PlanningRelativePath.init), isComplete: isComplete)
    }
}

public struct PlanningProjectInput: Sendable {
    public let canvasPath: PlanningStoredPath
    public let canvasDocument: PlanningCanvasDocument
    public let canvasBytes: Data
    public let canvasVersion: PlanningContentVersion
    public let noteSnapshots: [PlanningGraphNoteSnapshot]
    public let catalogue: PlanningReferenceCatalogue
    public let vaultID: UUID
    public let accessGeneration: UUID

    public init(
        canvasPath: PlanningStoredPath,
        canvasDocument: PlanningCanvasDocument,
        canvasBytes: Data,
        canvasVersion: PlanningContentVersion? = nil,
        noteSnapshots: [PlanningGraphNoteSnapshot],
        catalogue: PlanningReferenceCatalogue? = nil,
        vaultID: UUID,
        accessGeneration: UUID
    ) throws {
        guard canvasPath.isCanvas else { throw PlanningGraphError.invalidInput("canvas.path") }
        guard canvasBytes.count <= PlanningStorageLimits.canvasBytes else {
            throw PlanningGraphError.inputTooLarge
        }
        let resolvedVersion = canvasVersion ?? PlanningContentVersion(data: canvasBytes)
        guard resolvedVersion.matches(canvasBytes) else {
            throw PlanningGraphError.invalidInput("canvas.version")
        }
        guard try PlanningCanvasCodec.decode(canvasBytes) == canvasDocument else {
            throw PlanningGraphError.invalidInput("canvas.document")
        }
        guard canvasDocument.nodes.count <= PlanningGraphLimits.maximumVertices else {
            throw PlanningGraphError.tooManyVertices
        }
        guard canvasDocument.nodes.count + noteSnapshots.count <= PlanningGraphLimits.maximumVertices else {
            throw PlanningGraphError.tooManyVertices
        }
        var totalSourceBytes = canvasBytes.count
        var seen = Set<String>()
        for snapshot in noteSnapshots {
            totalSourceBytes += snapshot.bytes.count
            guard totalSourceBytes <= PlanningGraphLimits.maximumSourceBytes else {
                throw PlanningGraphError.inputTooLarge
            }
            guard seen.insert(PlanningValidation.normalizedReferencePath(snapshot.path.value)).inserted else {
                throw PlanningGraphError.duplicatePath(snapshot.path.value)
            }
        }
        let resolvedCatalogue = try catalogue ?? PlanningReferenceCatalogue(
            paths: noteSnapshots.map(\.path),
            isComplete: true
        )
        self.canvasPath = canvasPath
        self.canvasDocument = canvasDocument
        self.canvasBytes = canvasBytes
        self.canvasVersion = resolvedVersion
        self.noteSnapshots = noteSnapshots
        self.catalogue = resolvedCatalogue
        self.vaultID = vaultID
        self.accessGeneration = accessGeneration
    }
}

public enum PlanningReferenceResolution: Codable, Equatable, Sendable {
    case resolved(path: PlanningRelativePath, anchor: String?, subpath: String?)
    case notLoaded(target: String, anchor: String?, subpath: String?)
    case missing(target: String, anchor: String?, subpath: String?)
    case ambiguous(target: String, candidates: [PlanningRelativePath], anchor: String?, subpath: String?)
    case outsideBoundary(target: String, anchor: String?, subpath: String?)
    case external(target: String, anchor: String?, subpath: String?)

    public var isResolved: Bool {
        if case .resolved = self { return true }
        return false
    }

    public var target: String? {
        switch self {
        case .resolved: return nil
        case .notLoaded(let target, _, _), .missing(let target, _, _),
             .ambiguous(let target, _, _, _), .outsideBoundary(let target, _, _),
             .external(let target, _, _):
            return target
        }
    }

    public var path: PlanningRelativePath? {
        if case .resolved(let path, _, _) = self { return path }
        return nil
    }

    public var anchor: String? {
        switch self {
        case .resolved(_, let anchor, _), .notLoaded(_, let anchor, _),
             .missing(_, let anchor, _), .ambiguous(_, _, let anchor, _),
             .outsideBoundary(_, let anchor, _), .external(_, let anchor, _):
            return anchor
        }
    }

    public var subpath: String? {
        switch self {
        case .resolved(_, _, let subpath), .notLoaded(_, _, let subpath),
             .missing(_, _, let subpath), .ambiguous(_, _, _, let subpath),
             .outsideBoundary(_, _, let subpath), .external(_, _, let subpath):
            return subpath
        }
    }
}

fileprivate struct PlanningReferenceLookup: Sendable {
    let exact: [String: PlanningRelativePath]
    let basenames: [String: [PlanningRelativePath]]

    init(catalogue: PlanningReferenceCatalogue) {
        var exact: [String: PlanningRelativePath] = [:]
        exact.reserveCapacity(catalogue.paths.count)
        var basenames: [String: [PlanningRelativePath]] = [:]
        for path in catalogue.paths {
            exact[PlanningValidation.normalizedReferencePath(path.value)] = path
            basenames[PlanningReferenceResolver.basenameKey(path.value), default: []].append(path)
        }
        self.exact = exact
        self.basenames = basenames
    }
}

public enum PlanningReferenceResolver {
    public static func resolve(
        _ occurrence: PlanningMarkdownLinkOccurrence,
        from sourcePath: PlanningRelativePath,
        catalogue: PlanningReferenceCatalogue
    ) -> PlanningReferenceResolution {
        resolve(
            occurrence.rawTarget,
            from: sourcePath,
            catalogue: catalogue,
            anchor: occurrence.anchor,
            subpath: occurrence.subpath
        )
    }

    public static func resolve(
        _ rawTarget: String,
        from sourcePath: PlanningRelativePath,
        catalogue: PlanningReferenceCatalogue,
        anchor: String? = nil,
        subpath: String? = nil
    ) -> PlanningReferenceResolution {
        resolve(
            rawTarget,
            from: sourcePath,
            lookup: PlanningReferenceLookup(catalogue: catalogue),
            isComplete: catalogue.isComplete,
            anchor: anchor,
            subpath: subpath
        )
    }

    fileprivate static func resolve(
        _ rawTarget: String,
        from sourcePath: PlanningRelativePath,
        lookup: PlanningReferenceLookup,
        isComplete: Bool,
        anchor: String? = nil,
        subpath: String? = nil
    ) -> PlanningReferenceResolution {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            if anchor != nil || subpath != nil {
                return .resolved(path: sourcePath, anchor: anchor, subpath: subpath)
            }
            return isComplete
                ? .missing(target: target, anchor: anchor, subpath: subpath)
                : .notLoaded(target: target, anchor: anchor, subpath: subpath)
        }
        if isExternal(target) {
            return .external(target: target, anchor: anchor, subpath: subpath)
        }
        if isOutsideBoundary(target) {
            return .outsideBoundary(target: target, anchor: anchor, subpath: subpath)
        }

        let allowsBasenameFallback = !target.contains("/")
        let internalTarget = target.hasPrefix("LifeOS/")
            ? String(target.dropFirst("LifeOS/".count))
            : target
        let exactCandidates = candidatePaths(
            target: internalTarget,
            sourcePath: sourcePath
        )
        for candidate in exactCandidates {
            if let exact = lookup.exact[PlanningValidation.normalizedReferencePath(candidate.value)] {
                return .resolved(path: exact, anchor: anchor, subpath: subpath)
            }
        }

        if allowsBasenameFallback {
            let basename = basenameKey(internalTarget)
            let matches = lookup.basenames[basename] ?? []
            if matches.count == 1, let match = matches.first {
                return .resolved(path: match, anchor: anchor, subpath: subpath)
            }
            if matches.count > 1 {
                return .ambiguous(
                    target: target,
                    candidates: matches,
                    anchor: anchor,
                    subpath: subpath
                )
            }
        }
        return isComplete
            ? .missing(target: target, anchor: anchor, subpath: subpath)
            : .notLoaded(target: target, anchor: anchor, subpath: subpath)
    }

    private static func candidatePaths(
        target: String,
        sourcePath: PlanningRelativePath
    ) -> [PlanningRelativePath] {
        var candidates: [PlanningRelativePath] = []
        let needsMarkdownExtension = !target.lowercased().hasSuffix(".md")
        if let root = try? PlanningRelativePath(target) {
            candidates.append(root)
        }
        if needsMarkdownExtension, let extensionCandidate = try? PlanningRelativePath(target + ".md") {
            candidates.append(extensionCandidate)
        }
        let directory = Array(sourcePath.segments.dropLast())
        let relative = directory + target.split(separator: "/").map(String.init)
        if !relative.isEmpty, let path = try? PlanningRelativePath(relative.joined(separator: "/")) {
            candidates.append(path)
        }
        if needsMarkdownExtension {
            let relativeMarkdown = directory + [target + ".md"]
            if let path = try? PlanningRelativePath(relativeMarkdown.joined(separator: "/")) {
                candidates.append(path)
            }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert(PlanningValidation.normalizedReferencePath($0.value)).inserted }
    }

    fileprivate static func basenameKey(_ raw: String) -> String {
        let last = raw.split(separator: "/").last.map(String.init) ?? raw
        let stem = last.lowercased().hasSuffix(".md") ? String(last.dropLast(3)) : last
        return stem.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func isExternal(_ target: String) -> Bool {
        guard let schemeEnd = target.firstIndex(of: ":") else { return false }
        let scheme = target[..<schemeEnd]
        guard !scheme.isEmpty else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }
    }

    private static func isOutsideBoundary(_ target: String) -> Bool {
        let bytes = Array(target.utf8)
        guard !bytes.isEmpty else { return false }
        if bytes[0] == 0x2F || bytes[0] == 0x5C || bytes[0] == 0x7E { return true }
        if bytes.count >= 2,
           ((0x41...0x5A).contains(bytes[0]) || (0x61...0x7A).contains(bytes[0])),
           bytes[1] == 0x3A { return true }
        let components = target.split(separator: "/", omittingEmptySubsequences: false)
        return components.contains("..") || target.contains("\\")
    }
}

public struct PlanningGraphCanvasInstance: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let canvasPath: PlanningStoredPath
    public let nodeIndex: Int
    public let node: PlanningCanvasNode
    public let reference: PlanningReferenceResolution?
}

public struct PlanningGraphNoteIdentity: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let path: PlanningRelativePath
    public let title: String

    public init(path: PlanningRelativePath, title: String) {
        self.id = path.value
        self.path = path
        self.title = title
    }
}

public struct PlanningGraphAuthoredEdge: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let edgeIndex: Int
    public let edge: PlanningCanvasEdge
    public let fromInstanceID: String
    public let toInstanceID: String
}

public struct PlanningGraphDerivedLink: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sourcePath: PlanningRelativePath
    public let occurrence: PlanningMarkdownLinkOccurrence
    public let resolution: PlanningReferenceResolution
}

public struct PlanningGraphUnresolvedReference: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let source: String
    public let target: String
    public let resolution: PlanningReferenceResolution
}

public struct PlanningProjectGraph: Sendable, Equatable {
    public let canvasPath: PlanningStoredPath
    public let canvasInstances: [PlanningGraphCanvasInstance]
    public let noteIdentities: [PlanningGraphNoteIdentity]
    public let authoredEdges: [PlanningGraphAuthoredEdge]
    public let derivedLinks: [PlanningGraphDerivedLink]
    public let unresolvedReferences: [PlanningGraphUnresolvedReference]
    public let adjacency: [String: [String]]
    public let bounds: PlanningSpatialRect
    public let vaultID: UUID
    public let accessGeneration: UUID
}

public enum PlanningGraphProjector {
    public static func project(_ input: PlanningProjectInput) throws -> PlanningProjectGraph {
        var instances: [PlanningGraphCanvasInstance] = []
        instances.reserveCapacity(input.canvasDocument.nodes.count)
        var unresolved: [PlanningGraphUnresolvedReference] = []
        var adjacency: [String: [String]] = [:]
        var bounds = PlanningSpatialRect.empty
        let sourcePath = try PlanningRelativePath(input.canvasPath.value)
        let referenceLookup = PlanningReferenceLookup(catalogue: input.catalogue)
        let canonicalNotePaths = Dictionary(uniqueKeysWithValues: input.noteSnapshots.map {
            (PlanningValidation.normalizedReferencePath($0.path.value), $0.path)
        })
        func canonicalize(_ resolution: PlanningReferenceResolution) -> PlanningReferenceResolution {
            guard case .resolved(let path, let anchor, let subpath) = resolution,
                  let canonical = canonicalNotePaths[PlanningValidation.normalizedReferencePath(path.value)] else {
                return resolution
            }
            return .resolved(path: canonical, anchor: anchor, subpath: subpath)
        }

        for (index, node) in input.canvasDocument.nodes.enumerated() {
            let instanceID = "\(input.canvasPath.value)#\(node.id)"
            let nodeAnchor = node.subpath.flatMap { raw -> String? in
                let value = String(raw.dropFirst())
                return value.isEmpty ? nil : value
            }
            let reference = node.file.map {
                canonicalize(PlanningReferenceResolver.resolve(
                    $0,
                    from: sourcePath,
                    lookup: referenceLookup,
                    isComplete: input.catalogue.isComplete,
                    anchor: nodeAnchor,
                    subpath: node.subpath
                ))
            }
            instances.append(PlanningGraphCanvasInstance(
                id: instanceID,
                canvasPath: input.canvasPath,
                nodeIndex: index,
                node: node,
                reference: reference
            ))
            bounds = bounds.union(PlanningSpatialRect(
                minX: node.x,
                minY: node.y,
                maxX: node.x + node.width,
                maxY: node.y + node.height
            ))
            if let reference, !reference.isResolved {
                unresolved.append(PlanningGraphUnresolvedReference(
                    id: "canvas:\(instanceID)",
                    source: input.canvasPath.value,
                    target: node.file ?? "",
                    resolution: reference
                ))
            } else if let path = reference?.path {
                adjacency[instanceID, default: []].append(path.value)
            }
        }

        var authoredEdges: [PlanningGraphAuthoredEdge] = []
        authoredEdges.reserveCapacity(input.canvasDocument.edges.count)
        for (index, edge) in input.canvasDocument.edges.enumerated() {
            authoredEdges.append(PlanningGraphAuthoredEdge(
                id: edge.id,
                edgeIndex: index,
                edge: edge,
                fromInstanceID: "\(input.canvasPath.value)#\(edge.fromNode)",
                toInstanceID: "\(input.canvasPath.value)#\(edge.toNode)"
            ))
            adjacency["\(input.canvasPath.value)#\(edge.fromNode)", default: []].append(
                "\(input.canvasPath.value)#\(edge.toNode)"
            )
        }

        let noteIdentities = input.noteSnapshots.map {
            PlanningGraphNoteIdentity(path: $0.path, title: $0.note.title)
        }
        var derivedLinks: [PlanningGraphDerivedLink] = []
        var relationshipCount = authoredEdges.count
        for snapshot in input.noteSnapshots {
            let scan = PlanningMarkdownLinkScanner.scan(source: snapshot.note.source)
            guard scan.isComplete else {
                if scan.diagnostics.contains(where: { $0.code == .inputTooLarge }) {
                    throw PlanningGraphError.inputTooLarge
                }
                if scan.diagnostics.contains(where: { $0.code == .occurrenceLimit }) {
                    throw PlanningGraphError.tooManyRelationships
                }
                throw PlanningGraphError.invalidInput("markdown.scan")
            }
            relationshipCount += scan.occurrences.count
            guard relationshipCount <= PlanningGraphLimits.maximumRelationships else {
                throw PlanningGraphError.tooManyRelationships
            }
            for occurrence in scan.occurrences {
                let resolution = canonicalize(PlanningReferenceResolver.resolve(
                    occurrence.rawTarget,
                    from: snapshot.path,
                    lookup: referenceLookup,
                    isComplete: input.catalogue.isComplete,
                    anchor: occurrence.anchor,
                    subpath: occurrence.subpath
                ))
                let linkID = "\(snapshot.path.value)#\(occurrence.id)"
                derivedLinks.append(PlanningGraphDerivedLink(
                    id: linkID,
                    sourcePath: snapshot.path,
                    occurrence: occurrence,
                    resolution: resolution
                ))
                if let target = resolution.path {
                    adjacency[snapshot.path.value, default: []].append(target.value)
                } else {
                    unresolved.append(PlanningGraphUnresolvedReference(
                        id: "markdown:\(linkID)",
                        source: snapshot.path.value,
                        target: occurrence.rawTarget,
                        resolution: resolution
                    ))
                }
            }
        }

        return PlanningProjectGraph(
            canvasPath: input.canvasPath,
            canvasInstances: instances,
            noteIdentities: noteIdentities,
            authoredEdges: authoredEdges,
            derivedLinks: derivedLinks,
            unresolvedReferences: unresolved,
            adjacency: adjacency,
            bounds: bounds,
            vaultID: input.vaultID,
            accessGeneration: input.accessGeneration
        )
    }
}
