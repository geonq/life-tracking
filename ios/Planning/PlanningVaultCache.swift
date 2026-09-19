import Foundation

/// A bounded, stale-only cache for planning documents.
///
/// The cache is deliberately content addressed.  The index contains only
/// metadata and the document bytes live in descriptor-relative private files;
/// a cache hit is accepted only after the vault, selection generation, path,
/// digest, and byte count all agree.
final class PlanningVaultCache: @unchecked Sendable {
    private struct Entry: Codable, Equatable {
        let vaultID: UUID
        let selectionGeneration: UUID
        let path: PlanningStoredPath
        let version: PlanningContentVersion
        let observation: PlanningFileObservation
        let blobName: String?

        var key: String {
            "\(vaultID.uuidString.lowercased())/\(selectionGeneration.uuidString.lowercased())/\(path.collisionKey)"
        }

        init(
            vaultID: UUID,
            selectionGeneration: UUID,
            snapshot: PlanningDocumentSnapshot,
            blobName: String?
        ) throws {
            guard snapshot.observation.path == snapshot.path,
                  snapshot.observation.version == snapshot.version,
                  snapshot.observation.byteCount == snapshot.bytes.count else {
                throw PlanningFilesystemError.invalid("cache.observation")
            }
            if let blobName {
                guard case .bytes(let digest, let byteCount) = snapshot.version,
                      blobName == digest,
                      byteCount == snapshot.bytes.count,
                      planningDigestIsValid(blobName) else {
                    throw PlanningFilesystemError.invalid("cache.blob")
                }
            } else {
                guard snapshot.version == .absent, snapshot.bytes.isEmpty else {
                    throw PlanningFilesystemError.invalid("cache.absent")
                }
            }
            self.vaultID = vaultID
            self.selectionGeneration = selectionGeneration
            self.path = snapshot.path
            self.version = snapshot.version
            self.observation = snapshot.observation
            self.blobName = blobName
        }

        func validate() throws {
            guard observation.path == path,
                  observation.version == version,
                  observation.byteCount == version.byteCount else {
                throw PlanningFilesystemError.corruptEvidence
            }
            switch (version, blobName) {
            case (.absent, nil):
                break
            case (.bytes(let digest, let count), .some(let blob)):
                guard digest == blob,
                      count == observation.byteCount,
                      planningDigestIsValid(blob) else {
                    throw PlanningFilesystemError.corruptEvidence
                }
            default:
                throw PlanningFilesystemError.corruptEvidence
            }
        }
    }

    private struct Index: Codable {
        let schemaVersion: Int
        var entries: [Entry]

        init(entries: [Entry]) throws {
            guard entries.count <= PlanningFilesystemLimits.maximumCacheRecords else {
                throw PlanningFilesystemError.backpressure("cacheRecords")
            }
            self.schemaVersion = 1
            self.entries = entries
        }

        func validate() throws {
            guard schemaVersion == 1,
                  entries.count <= PlanningFilesystemLimits.maximumCacheRecords else {
                throw PlanningFilesystemError.corruptEvidence
            }
            var keys = Set<String>()
            for entry in entries {
                try entry.validate()
                guard keys.insert(entry.key).inserted else {
                    throw PlanningFilesystemError.corruptEvidence
                }
            }
        }
    }

    private let directory: URL
    private let lock = NSLock()
    private let indexName = "index.json"
    private let blobsName = "blobs"

    init(directory: URL) {
        self.directory = directory
    }

    func store(
        _ snapshot: PlanningDocumentSnapshot,
        vaultID: UUID,
        selectionGeneration: UUID
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let root = try openRoot(create: true)
        defer { root.close() }
        let blobs = try openBlobs(create: true)
        defer { blobs.close() }

        var index = try loadIndex(from: root)
        try pruneUnowned(index: index, blobs: blobs)
        let entryKey = "\(vaultID.uuidString.lowercased())/\(selectionGeneration.uuidString.lowercased())/\(snapshot.path.collisionKey)"
        if index.entries.contains(where: { $0.key == entryKey }) {
            index.entries.removeAll { $0.key == entryKey }
            index = try Index(entries: index.entries)
            try saveIndex(index, in: root)
            try pruneUnowned(index: index, blobs: blobs)
        }
        while index.entries.count >= PlanningFilesystemLimits.maximumCacheRecords {
            index.entries.removeFirst()
            index = try Index(entries: index.entries)
            try saveIndex(index, in: root)
            try pruneUnowned(index: index, blobs: blobs)
        }
        let blobName: String?
        switch snapshot.version {
        case .absent:
            blobName = nil
        case .bytes(let digest, let count):
            guard count == snapshot.bytes.count,
                  planningDigestIsValid(digest) else {
                throw PlanningFilesystemError.corruptEvidence
            }
            blobName = digest
            if let existingSize = try PlanningSafeFileIO.privateFileSize(
                in: blobs,
                name: digest,
                maximum: documentLimit(for: snapshot.path)
            ) {
                guard existingSize == snapshot.bytes.count,
                      try PlanningSafeFileIO.readPrivateFile(
                          in: blobs,
                          name: digest,
                          maximum: documentLimit(for: snapshot.path)
                      ) == snapshot.bytes else {
                    throw PlanningFilesystemError.corruptEvidence
                }
            } else {
                let inventory = try cacheInventory(blobs)
                let (nextBytes, addOverflow) = inventory.bytes.addingReportingOverflow(snapshot.bytes.count)
                guard !addOverflow,
                      nextBytes <= PlanningFilesystemLimits.maximumCacheBytes else {
                    throw PlanningFilesystemError.backpressure("cacheBytes")
                }
                try PlanningSafeFileIO.writePrivateFileAtomically(
                    snapshot.bytes,
                    in: blobs,
                    name: digest,
                    replacing: false,
                    maximum: documentLimit(for: snapshot.path)
                )
            }
        }

        let entry = try Entry(
            vaultID: vaultID,
            selectionGeneration: selectionGeneration,
            snapshot: snapshot,
            blobName: blobName
        )
        index.entries.removeAll { $0.key == entry.key }
        index.entries.append(entry)
        index = try Index(entries: index.entries)
        try saveIndex(index, in: root)
        try pruneUnowned(index: index, blobs: blobs)
    }

    func load(
        vaultID: UUID,
        selectionGeneration: UUID,
        path: PlanningStoredPath,
        version: PlanningContentVersion
    ) throws -> PlanningDocumentSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        let root = try openRoot(create: false)
        defer { root.close() }
        let index = try loadIndex(from: root)
        guard let entry = index.entries.first(where: {
            $0.vaultID == vaultID
                && $0.selectionGeneration == selectionGeneration
                && $0.path.collisionKey == path.collisionKey
                && $0.version == version
        }) else { return nil }
        return try materialize(entry: entry)
    }

    func loadLatest(
        vaultID: UUID,
        selectionGeneration: UUID,
        path: PlanningStoredPath
    ) throws -> PlanningDocumentSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        let root = try openRoot(create: false)
        defer { root.close() }
        let index = try loadIndex(from: root)
        guard let entry = index.entries.last(where: {
            $0.vaultID == vaultID
                && $0.selectionGeneration == selectionGeneration
                && $0.path.collisionKey == path.collisionKey
        }) else { return nil }
        return try materialize(entry: entry)
    }

    func evictClean() throws {
        lock.lock()
        defer { lock.unlock() }
        let root = try openRoot(create: false)
        defer { root.close() }
        let blobs = try openBlobs(create: false)
        defer { blobs.close() }
        let index = try loadIndex(from: root)
        try pruneUnowned(index: index, blobs: blobs)
    }

    private func pruneUnowned(
        index: Index,
        blobs: PlanningPrivateDirectoryLease
    ) throws {
        let owned = Set(index.entries.compactMap(\.blobName))
        var visited = 0
        try PlanningSafeFileIO.enumeratePrivateFiles(
            in: blobs,
            maximumEntries: PlanningFilesystemLimits.maximumDirectoryEntries
        ) { name in
            visited += 1
            guard visited <= PlanningFilesystemLimits.maximumVisitedEntries else {
                throw PlanningFilesystemError.backpressure("cacheVisited")
            }
            if name.hasPrefix(".lifeos-private-tmp-") {
                try PlanningSafeFileIO.removePrivateFile(in: blobs, name: name)
                return
            }
            guard planningDigestIsValid(name) else {
                throw PlanningFilesystemError.corruptEvidence
            }
            let size = try PlanningSafeFileIO.privateFileSize(
                in: blobs,
                name: name,
                maximum: PlanningStorageLimits.canvasBytes
            )
            guard let size else { return }
            let bytes = try PlanningSafeFileIO.readPrivateFile(
                in: blobs,
                name: name,
                maximum: PlanningStorageLimits.canvasBytes
            )
            guard bytes != nil, size == bytes?.count,
                  PlanningContentVersion(data: bytes ?? Data()).digest == name else {
                throw PlanningFilesystemError.corruptEvidence
            }
            if !owned.contains(name) {
                try PlanningSafeFileIO.removePrivateFile(in: blobs, name: name)
            }
        }
    }

    private func materialize(entry: Entry) throws -> PlanningDocumentSnapshot {
        try entry.validate()
        let bytes: Data
        if let blob = entry.blobName {
            let blobs = try openBlobs(create: false)
            defer { blobs.close() }
            guard let data = try PlanningSafeFileIO.readPrivateFile(
                in: blobs,
                name: blob,
                maximum: documentLimit(for: entry.path)
            ) else { throw PlanningFilesystemError.corruptEvidence }
            guard entry.version.matches(data) else {
                throw PlanningFilesystemError.corruptEvidence
            }
            bytes = data
        } else {
            bytes = Data()
        }
        do {
            return try PlanningDocumentSnapshot(
                path: entry.path,
                bytes: bytes,
                version: entry.version,
                observation: entry.observation
            )
        } catch {
            throw PlanningFilesystemError.corruptEvidence
        }
    }

    private func openRoot(create: Bool) throws -> PlanningPrivateDirectoryLease {
        try PlanningSafeFileIO.openPrivateDirectory(at: directory, create: create)
    }

    private func openBlobs(create: Bool) throws -> PlanningPrivateDirectoryLease {
        try PlanningSafeFileIO.openPrivateDirectory(
            at: directory.appendingPathComponent(blobsName, isDirectory: true),
            create: create
        )
    }

    private func loadIndex(from root: PlanningPrivateDirectoryLease) throws -> Index {
        guard let data = try PlanningSafeFileIO.readPrivateFile(
            in: root,
            name: indexName,
            maximum: PlanningFilesystemLimits.maximumCacheIndexBytes
        ) else {
            return try Index(entries: [])
        }
        do {
            let index = try JSONDecoder().decode(Index.self, from: data)
            try index.validate()
            return index
        } catch let error as PlanningFilesystemError {
            throw error
        } catch {
            throw PlanningFilesystemError.corruptEvidence
        }
    }

    private func saveIndex(_ index: Index, in root: PlanningPrivateDirectoryLease) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(index)
        } catch {
            throw PlanningFilesystemError.corruptEvidence
        }
        guard data.count <= PlanningFilesystemLimits.maximumCacheIndexBytes else {
            throw PlanningFilesystemError.backpressure("cacheIndex")
        }
        try PlanningSafeFileIO.writePrivateFileAtomically(
            data,
            in: root,
            name: indexName,
            replacing: true,
            maximum: PlanningFilesystemLimits.maximumCacheIndexBytes
        )
    }

    private struct Inventory {
        var bytes = 0
        var entries = 0
    }

    private func cacheInventory(_ blobs: PlanningPrivateDirectoryLease) throws -> Inventory {
        var inventory = Inventory()
        var visited = 0
        try PlanningSafeFileIO.enumeratePrivateFiles(
            in: blobs,
            maximumEntries: PlanningFilesystemLimits.maximumDirectoryEntries
        ) { name in
            visited += 1
            guard visited <= PlanningFilesystemLimits.maximumVisitedEntries else {
                throw PlanningFilesystemError.backpressure("cacheVisited")
            }
            guard planningDigestIsValid(name) else {
                throw PlanningFilesystemError.corruptEvidence
            }
            guard let size = try PlanningSafeFileIO.privateFileSize(
                in: blobs,
                name: name,
                maximum: PlanningStorageLimits.canvasBytes
            ) else { return }
            inventory.entries += 1
            let (next, overflow) = inventory.bytes.addingReportingOverflow(size)
            guard !overflow,
                  inventory.entries <= PlanningFilesystemLimits.maximumCacheRecords,
                  next <= PlanningFilesystemLimits.maximumCacheBytes else {
                throw PlanningFilesystemError.backpressure("cache")
            }
            inventory.bytes = next
        }
        return inventory
    }

    private func documentLimit(for path: PlanningStoredPath) -> Int {
        path.isCanvas ? PlanningStorageLimits.canvasBytes : PlanningStorageLimits.markdownBytes
    }
}
