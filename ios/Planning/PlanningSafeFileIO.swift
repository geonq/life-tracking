import Foundation

#if canImport(Darwin)
import Darwin
#endif

public final class PlanningDirectoryLease: @unchecked Sendable {
    public let rootURL: URL
    public let generation: UUID
    public let rootIdentity: PlanningFileIdentity
    public let lifeOSIdentity: PlanningFileIdentity
    internal let rootAuthority: PlanningStableDirectoryIdentity
    internal let lifeOSAuthority: PlanningStableDirectoryIdentity
    public let vaultID: UUID

    fileprivate let rootDescriptor: Int32
    fileprivate let lifeOSDescriptor: Int32
    private let closeLock = NSLock()
    private var isClosed = false

    fileprivate init(
        rootURL: URL,
        generation: UUID,
        rootIdentity: PlanningFileIdentity,
        lifeOSIdentity: PlanningFileIdentity,
        rootAuthority: PlanningStableDirectoryIdentity,
        lifeOSAuthority: PlanningStableDirectoryIdentity,
        vaultID: UUID,
        rootDescriptor: Int32,
        lifeOSDescriptor: Int32
    ) {
        self.rootURL = rootURL
        self.generation = generation
        self.rootIdentity = rootIdentity
        self.lifeOSIdentity = lifeOSIdentity
        self.rootAuthority = rootAuthority
        self.lifeOSAuthority = lifeOSAuthority
        self.vaultID = vaultID
        self.rootDescriptor = rootDescriptor
        self.lifeOSDescriptor = lifeOSDescriptor
    }

    public var closed: Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        return isClosed
    }

    public func close() {
        closeLock.lock()
        guard !isClosed else {
            closeLock.unlock()
            return
        }
        isClosed = true
        closeLock.unlock()
#if canImport(Darwin)
        _ = Darwin.close(lifeOSDescriptor)
        _ = Darwin.close(rootDescriptor)
#endif
    }

    deinit { close() }
}

public final class PlanningParentHandle: @unchecked Sendable {
    internal let fileDescriptor: Int32
    internal let leafName: String
    public let parentChain: [PlanningFileIdentity]
    public let path: PlanningStoredPath
    private let closeLock = NSLock()
    private var isClosed = false

    fileprivate init(
        fileDescriptor: Int32,
        leafName: String,
        parentChain: [PlanningFileIdentity],
        path: PlanningStoredPath
    ) {
        self.fileDescriptor = fileDescriptor
        self.leafName = leafName
        self.parentChain = parentChain
        self.path = path
    }

    public func close() {
        closeLock.lock()
        guard !isClosed else {
            closeLock.unlock()
            return
        }
        isClosed = true
        closeLock.unlock()
#if canImport(Darwin)
        _ = Darwin.close(fileDescriptor)
#endif
    }

    deinit { close() }
}

/// An application-support directory opened from a trusted descriptor chain.
/// Callers never receive a path based handle for private persistence.
internal final class PlanningPrivateDirectoryLease: @unchecked Sendable {
    let fileDescriptor: Int32
    private let closeLock = NSLock()
    private var isClosed = false

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    var closed: Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        return isClosed
    }

    func close() {
        closeLock.lock()
        guard !isClosed else {
            closeLock.unlock()
            return
        }
        isClosed = true
        closeLock.unlock()
#if canImport(Darwin)
        _ = Darwin.close(fileDescriptor)
#endif
    }

    deinit { close() }
}

public struct PlanningSafeFileCapabilities: Sendable, Equatable {
    public let exclusiveRename: Bool
    public let swapRename: Bool
    public let descriptorTraversal: Bool
    public let directoryFlush: Bool

    public init(
        exclusiveRename: Bool,
        swapRename: Bool,
        descriptorTraversal: Bool,
        directoryFlush: Bool
    ) {
        self.exclusiveRename = exclusiveRename
        self.swapRename = swapRename
        self.descriptorTraversal = descriptorTraversal
        self.directoryFlush = directoryFlush
    }
}

public enum PlanningSafeFileIO {
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    private static let leafFlags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC

    public static func openRoot(
        _ url: URL,
        generation: UUID = UUID(),
        expectedVaultID: UUID? = nil
    ) throws -> PlanningDirectoryLease {
#if canImport(Darwin)
        guard url.isFileURL else { throw PlanningFilesystemError.invalid("root.url") }
        let rootFD = try openDirectory(path: url.path)
        do {
            let rootIdentity = try identity(for: rootFD)
            let providerIdentifier = Self.providerIdentifier(at: url)
            let rootAuthority = try stableIdentity(
                for: rootFD,
                providerIdentifier: providerIdentifier
            )
            let lifeOSFD: Int32
            do {
                lifeOSFD = try openDirectory(parent: rootFD, name: "LifeOS")
            } catch {
                throw map(error)
            }
            do {
                let lifeOSIdentity = try identity(for: lifeOSFD)
                let lifeOSAuthority = try stableIdentity(
                    for: lifeOSFD,
                    providerIdentifier: providerIdentifier
                )
                let marker = try readMarker(fd: lifeOSFD)
                if let expectedVaultID, marker.vaultID != expectedVaultID {
                    throw PlanningFilesystemError.identityChanged
                }
                return PlanningDirectoryLease(
                    rootURL: url,
                    generation: generation,
                    rootIdentity: rootIdentity,
                    lifeOSIdentity: lifeOSIdentity,
                    rootAuthority: rootAuthority,
                    lifeOSAuthority: lifeOSAuthority,
                    vaultID: marker.vaultID,
                    rootDescriptor: rootFD,
                    lifeOSDescriptor: lifeOSFD
                )
            } catch {
                _ = Darwin.close(lifeOSFD)
                throw map(error)
            }
        } catch {
            _ = Darwin.close(rootFD)
            throw map(error)
        }
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    public static func initializeLifeOS(
        at rootURL: URL,
        vaultID: UUID,
        ownedTemporaryName: String? = nil
    ) throws -> PlanningVaultIdentity {
#if canImport(Darwin)
        guard rootURL.isFileURL else { throw PlanningFilesystemError.invalid("root.url") }
        let rootFD = try openDirectory(path: rootURL.path)
        defer { _ = Darwin.close(rootFD) }

        let lifeOSFD: Int32
        do {
            lifeOSFD = try openDirectory(parent: rootFD, name: "LifeOS")
        } catch let error as PlanningFilesystemError where error == .notFound {
            let result = rootURL.appendingPathComponent("LifeOS", isDirectory: true)
            _ = result
            if mkdirat(rootFD, "LifeOS", mode_t(0o700)) != 0 && errno != EEXIST {
                throw mapErrno(errno)
            }
            lifeOSFD = try openDirectory(parent: rootFD, name: "LifeOS")
        }
        defer { _ = Darwin.close(lifeOSFD) }

        let entries = try enumerateNames(fd: lifeOSFD)
        let markerName = ".lifeos-vault.json"
        if let ownedTemporaryName,
           entries == [ownedTemporaryName] {
            try validateComponent(ownedTemporaryName)
            guard let temporaryFD = try openLeaf(parent: lifeOSFD, name: ownedTemporaryName) else {
                throw PlanningFilesystemError.corruptEvidence
            }
            defer { _ = Darwin.close(temporaryFD) }
            let (_, size) = try regularIdentityAndSize(
                fd: temporaryFD,
                maximumBytes: PlanningFilesystemLimits.maximumMarkerBytes
            )
            guard size > 0 else { throw PlanningFilesystemError.corruptEvidence }
            _ = lseek(temporaryFD, 0, SEEK_SET)
            let data = try readAll(temporaryFD, maximumBytes: PlanningFilesystemLimits.maximumMarkerBytes)
            let expected = try JSONEncoder().encode(PlanningVaultIdentity(vaultID: vaultID))
            guard data == expected else { throw PlanningFilesystemError.corruptEvidence }
            guard unlinkat(lifeOSFD, ownedTemporaryName, 0) == 0 else {
                throw mapErrno(errno)
            }
        }
        let refreshedEntries = try enumerateNames(fd: lifeOSFD)
        if refreshedEntries.count > 1 || (refreshedEntries.count == 1 && refreshedEntries.first != markerName) {
            throw PlanningFilesystemError.invalid("lifeOS.nonEmpty")
        }
        let identity = try PlanningVaultIdentity(vaultID: vaultID)
        if entries.contains(markerName) {
            let existing = try readMarker(fd: lifeOSFD)
            guard existing == identity else { throw PlanningFilesystemError.identityChanged }
            return existing
        }

        let markerData = try JSONEncoder().encode(identity)
        guard markerData.count <= PlanningFilesystemLimits.maximumMarkerBytes else {
            throw PlanningFilesystemError.backpressure("marker")
        }
        let temporaryName = ownedTemporaryName ?? ".lifeos-tmp-\(UUID().uuidString.lowercased())"
        var temporaryFD = try createExclusive(parentFD: lifeOSFD, name: temporaryName, mode: 0o600)
        defer {
            if temporaryFD >= 0 {
                _ = Darwin.close(temporaryFD)
                temporaryFD = -1
            }
        }
        do {
            try writeAll(temporaryFD, data: markerData)
            try flush(temporaryFD, directory: false)
            let descriptorToClose = temporaryFD
            temporaryFD = -1
            guard Darwin.close(descriptorToClose) == 0 else {
                throw mapErrno(errno)
            }
            try rename(parentFD: lifeOSFD, source: temporaryName, destination: markerName, flags: UInt32(RENAME_EXCL))
            try flush(lifeOSFD, directory: true)
        } catch {
            throw map(error)
        }
        return identity
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    internal static func validateSelectionRoot(_ url: URL) throws {
#if canImport(Darwin)
        guard url.isFileURL else { throw PlanningFilesystemError.invalid("selection.url") }
        let rootFD = try openDirectory(path: url.standardizedFileURL.path)
        defer { _ = Darwin.close(rootFD) }
        let names = try enumerateNames(fd: rootFD)
        if let lifeOS = names.first(where: {
            planningFilesystemCollisionKey($0) == planningFilesystemCollisionKey("LifeOS")
        }), lifeOS != "LifeOS" {
            throw PlanningFilesystemError.caseCollision
        }
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    public static func openParent(
        _ lease: PlanningDirectoryLease,
        path: PlanningStoredPath,
        createMissing: Bool = false,
        checkCancellation: (() throws -> Void)? = nil
    ) throws -> PlanningParentHandle {
#if canImport(Darwin)
        guard !lease.closed else { throw PlanningFilesystemError.needsReselection }
        guard path.value.utf8.count <= PlanningFilesystemLimits.maximumPathBytes else {
            throw PlanningFilesystemError.backpressure("path")
        }
        let segments = path.value.split(separator: "/").map(String.init)
        guard !segments.isEmpty,
              segments.count <= PlanningFilesystemLimits.maximumDepth else {
            throw PlanningFilesystemError.invalid("path")
        }
        return try openParent(
            lifeOSDescriptor: lease.lifeOSDescriptor,
            path: path,
            createMissing: createMissing,
            checkCancellation: checkCancellation
        )
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    public static func readBounded(
        _ lease: PlanningDirectoryLease,
        path: PlanningStoredPath
    ) throws -> PlanningRawFileRead? {
#if canImport(Darwin)
        let parent: PlanningParentHandle
        do {
            parent = try openParent(lease, path: path)
        } catch let error as PlanningFilesystemError where error == .notFound {
            return nil
        }
        defer { parent.close() }
        try verifyChain(
            lease,
            expectedRoot: lease.rootIdentity,
            expectedLifeOS: lease.lifeOSIdentity,
            expectedParentChain: parent.parentChain,
            path: path,
            expectedVaultID: lease.vaultID
        )
        let result = try readBoundedFromParent(parent)
        try verifyChain(
            lease,
            expectedRoot: lease.rootIdentity,
            expectedLifeOS: lease.lifeOSIdentity,
            expectedParentChain: parent.parentChain,
            path: path,
            expectedVaultID: lease.vaultID
        )
        return result
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    internal static func readNamedBoundedFromParent(
        _ parent: PlanningParentHandle,
        name: String
    ) throws -> PlanningRawFileRead? {
#if canImport(Darwin)
        try validateComponent(name)
        guard let fd = try openLeaf(parent: parent.fileDescriptor, name: name) else {
            return nil
        }
        defer { _ = Darwin.close(fd) }
        let limit = parent.path.isCanvas ? PlanningStorageLimits.canvasBytes : PlanningStorageLimits.markdownBytes
        let before = try regularIdentityAndSize(fd: fd, maximumBytes: limit)
        var data = Data()
        data.reserveCapacity(min(before.size, limit))
        var buffer = [UInt8](repeating: 0, count: PlanningFilesystemLimits.ioChunkBytes)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw mapErrno(errno)
            }
            if count == 0 { break }
            guard data.count <= limit - count else { throw PlanningFilesystemError.backpressure("document") }
            data.append(buffer, count: count)
        }
        let after = try regularIdentityAndSize(fd: fd, maximumBytes: limit)
        guard before.identity == after.identity,
              before.size == after.size,
              before.size == data.count,
              let current = try identityIfPresent(parent: parent.fileDescriptor, name: name),
              current == before.identity else {
            throw PlanningFilesystemError.changedDuringRead
        }
        return PlanningRawFileRead(data: data, identity: before.identity, parentChain: parent.parentChain)
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    internal static func verifyParentChain(
        _ lease: PlanningDirectoryLease,
        path: PlanningStoredPath,
        expected: [PlanningFileIdentity]
    ) throws {
#if canImport(Darwin)
        guard let freshLifeOS = try? openDirectory(path: lease.rootURL
            .appendingPathComponent("LifeOS", isDirectory: true).path) else {
            throw PlanningFilesystemError.identityChanged
        }
        defer { _ = Darwin.close(freshLifeOS) }
        let fresh = try openParent(
            lifeOSDescriptor: freshLifeOS,
            path: path,
            createMissing: false
        )
        defer { fresh.close() }
        guard fresh.parentChain == expected else {
            throw PlanningFilesystemError.identityChanged
        }
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

#if canImport(Darwin)
    private static func openParent(
        lifeOSDescriptor: Int32,
        path: PlanningStoredPath,
        createMissing: Bool,
        checkCancellation: (() throws -> Void)? = nil
    ) throws -> PlanningParentHandle {
        guard path.value.utf8.count <= PlanningFilesystemLimits.maximumPathBytes else {
            throw PlanningFilesystemError.backpressure("path")
        }
        let segments = path.value.split(separator: "/").map(String.init)
        guard let leaf = segments.last,
              segments.count <= PlanningFilesystemLimits.maximumDepth else {
            throw PlanningFilesystemError.invalid("path")
        }
        var current = try duplicate(lifeOSDescriptor)
        var chain: [PlanningFileIdentity] = [try identity(for: current)]
        do {
            for segment in segments.dropLast() {
                try validateComponent(segment)
                try rejectCollision(in: current, requested: segment)
                let child: Int32
                do {
                    child = try openDirectory(parent: current, name: segment)
                } catch let error as PlanningFilesystemError where error == .notFound && createMissing {
                    try checkCancellation?()
                    if mkdirat(current, segment, mode_t(0o700)) != 0 && errno != EEXIST {
                        throw mapErrno(errno)
                    }
                    child = try openDirectory(parent: current, name: segment)
                }
                let childIdentity = try identity(for: child)
                chain.append(childIdentity)
                _ = Darwin.close(current)
                current = child
            }
            try validateComponent(leaf)
            try rejectCollision(in: current, requested: leaf)
            return PlanningParentHandle(
                fileDescriptor: current,
                leafName: leaf,
                parentChain: chain,
                path: path
            )
        } catch {
            _ = Darwin.close(current)
            throw map(error)
        }
    }
#endif

    internal static func readBoundedFromParent(
        _ parent: PlanningParentHandle
    ) throws -> PlanningRawFileRead? {
#if canImport(Darwin)
        guard let fd = try openLeaf(parent: parent.fileDescriptor, name: parent.leafName) else {
            return nil
        }
        defer { _ = Darwin.close(fd) }
        let limit = parent.path.isCanvas ? PlanningStorageLimits.canvasBytes : PlanningStorageLimits.markdownBytes
        let before = try regularIdentityAndSize(fd: fd, maximumBytes: limit)
        var data = Data()
        data.reserveCapacity(min(before.size, limit))
        var buffer = [UInt8](repeating: 0, count: PlanningFilesystemLimits.ioChunkBytes)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw mapErrno(errno)
            }
            if count == 0 { break }
            guard data.count <= limit - count else { throw PlanningFilesystemError.backpressure("document") }
            data.append(buffer, count: count)
        }
        let after = try regularIdentityAndSize(fd: fd, maximumBytes: limit)
        guard before.identity == after.identity,
              before.size == after.size,
              before.size == data.count else {
            throw PlanningFilesystemError.changedDuringRead
        }
        guard let current = try identityIfPresent(parent: parent.fileDescriptor, name: parent.leafName),
              current == before.identity else {
            throw PlanningFilesystemError.changedDuringRead
        }
        return PlanningRawFileRead(data: data, identity: before.identity, parentChain: parent.parentChain)
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    public static func enumerateBounded(_ parent: PlanningParentHandle) throws -> [String] {
#if canImport(Darwin)
        try enumerateNames(fd: parent.fileDescriptor)
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    public static func createExclusive(
        _ parent: PlanningParentHandle,
        name: String,
        data: Data,
        mode: Int32 = 0o600
    ) throws -> PlanningFileIdentity {
#if canImport(Darwin)
        try validateComponent(name)
        guard data.count <= PlanningStorageLimits.canvasBytes else {
            throw PlanningFilesystemError.backpressure("document")
        }
        let fd = try createExclusive(parentFD: parent.fileDescriptor, name: name, mode: mode)
        defer { _ = Darwin.close(fd) }
        do {
            try writeAll(fd, data: data)
            try flush(fd, directory: false)
            return try regularIdentityAndSize(fd: fd, maximumBytes: max(data.count, 1)).identity
        } catch {
            throw map(error)
        }
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    public static func identity(
        _ parent: PlanningParentHandle,
        name: String
    ) throws -> PlanningFileIdentity? {
#if canImport(Darwin)
        try identityIfPresent(parent: parent.fileDescriptor, name: name)
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    public static func removeVerified(
        _ parent: PlanningParentHandle,
        name: String,
        expected: PlanningFileIdentity
    ) throws {
#if canImport(Darwin)
        try validateComponent(name)
        guard let actual = try identityIfPresent(parent: parent.fileDescriptor, name: name),
              actual == expected,
              actual.fileType == 1 else {
            throw PlanningFilesystemError.corruptEvidence
        }
        guard unlinkat(parent.fileDescriptor, name, 0) == 0 else { throw mapErrno(errno) }
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    public static func flush(_ descriptor: Int32, directory: Bool) throws {
#if canImport(Darwin)
        guard fsync(descriptor) == 0 else { throw mapErrno(errno) }
        if !directory {
            #if os(macOS)
            let fullSyncResult = fcntl(descriptor, F_FULLFSYNC)
            if fullSyncResult != 0 {
                let fullSyncError = errno
                guard fullSyncError == ENOTSUP || fullSyncError == EINVAL else {
                    throw mapErrno(fullSyncError)
                }
                // APFS and some provider-backed filesystems do not expose
                // F_FULLFSYNC.  fsync above is the explicit portable fallback;
                // all other F_FULLFSYNC failures remain visible to callers.
            }
            #endif
        }
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    public static func renameExclusive(
        _ parent: PlanningParentHandle,
        source: String,
        destination: String
    ) throws {
#if canImport(Darwin)
        try validateComponent(source)
        try validateComponent(destination)
        try rename(parentFD: parent.fileDescriptor, source: source, destination: destination, flags: UInt32(RENAME_EXCL))
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    public static func swap(
        _ parent: PlanningParentHandle,
        source: String,
        destination: String
    ) throws {
#if canImport(Darwin)
        try validateComponent(source)
        try validateComponent(destination)
        try rename(parentFD: parent.fileDescriptor, source: source, destination: destination, flags: UInt32(RENAME_SWAP))
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    public static func verifyChain(
        _ lease: PlanningDirectoryLease,
        expectedRoot: PlanningFileIdentity,
        expectedLifeOS: PlanningFileIdentity,
        expectedParentChain: [PlanningFileIdentity]? = nil,
        path: PlanningStoredPath? = nil,
        expectedVaultID: UUID? = nil
    ) throws {
#if canImport(Darwin)
        guard !lease.closed,
              lease.rootIdentity == expectedRoot,
              lease.lifeOSIdentity == expectedLifeOS,
              try identity(for: lease.rootDescriptor) == expectedRoot,
              try identity(for: lease.lifeOSDescriptor) == expectedLifeOS else {
            throw PlanningFilesystemError.identityChanged
        }
        let providerIdentifier = providerIdentifier(at: lease.rootURL)
        guard try stableIdentity(
            for: lease.rootDescriptor,
            providerIdentifier: providerIdentifier
        ) == lease.rootAuthority,
        try stableIdentity(
            for: lease.lifeOSDescriptor,
            providerIdentifier: providerIdentifier
        ) == lease.lifeOSAuthority else {
            throw PlanningFilesystemError.identityChanged
        }
        let freshRoot = try openDirectory(path: lease.rootURL.path)
        defer { _ = Darwin.close(freshRoot) }
        guard try identity(for: freshRoot) == expectedRoot,
              try stableIdentity(
                  for: freshRoot,
                  providerIdentifier: providerIdentifier
              ) == lease.rootAuthority else {
            throw PlanningFilesystemError.identityChanged
        }
        let freshLifeOS = try openDirectory(parent: freshRoot, name: "LifeOS")
        defer { _ = Darwin.close(freshLifeOS) }
        guard try identity(for: freshLifeOS) == expectedLifeOS,
              try stableIdentity(
                  for: freshLifeOS,
                  providerIdentifier: providerIdentifier
              ) == lease.lifeOSAuthority else {
            throw PlanningFilesystemError.identityChanged
        }
        let marker = try readMarker(fd: freshLifeOS)
        guard marker.vaultID == (expectedVaultID ?? lease.vaultID) else {
            throw PlanningFilesystemError.identityChanged
        }
        guard let markerIdentity = try identityIfPresent(parent: freshLifeOS, name: ".lifeos-vault.json"),
              markerIdentity.fileType == 1 else {
            throw PlanningFilesystemError.identityChanged
        }
        if let expectedParentChain, let path {
            let freshParent = try openParent(
                lifeOSDescriptor: freshLifeOS,
                path: path,
                createMissing: false
            )
            defer { freshParent.close() }
            guard freshParent.parentChain == expectedParentChain else {
                throw PlanningFilesystemError.identityChanged
            }
        }
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    public static func capabilities(for lease: PlanningDirectoryLease) -> PlanningSafeFileCapabilities {
#if canImport(Darwin)
        guard !lease.closed else {
            return PlanningSafeFileCapabilities(
                exclusiveRename: false,
                swapRename: false,
                descriptorTraversal: false,
                directoryFlush: false
            )
        }
        let values = try? lease.rootURL.resourceValues(forKeys: [
            .volumeSupportsExclusiveRenamingKey,
            .volumeSupportsSwapRenamingKey
        ])
        let directoryFlush: Bool
        if let descriptor = try? duplicate(lease.rootDescriptor) {
            let syncResult = fsync(descriptor)
            let closeResult = Darwin.close(descriptor)
            directoryFlush = syncResult == 0 && closeResult == 0
        } else {
            directoryFlush = false
        }
        return PlanningSafeFileCapabilities(
            exclusiveRename: values?.volumeSupportsExclusiveRenaming == true,
            swapRename: values?.volumeSupportsSwapRenaming == true,
            descriptorTraversal: true,
            directoryFlush: directoryFlush
        )
#else
        return PlanningSafeFileCapabilities(
            exclusiveRename: false,
            swapRename: false,
            descriptorTraversal: false,
            directoryFlush: false
        )
#endif
    }

    internal static func absoluteURL(
        for path: PlanningStoredPath,
        in lease: PlanningDirectoryLease
    ) -> URL {
        lease.rootURL
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent(path.value, isDirectory: false)
    }

    internal static func authorityIdentity(
        for lease: PlanningDirectoryLease,
        providerIdentifier: String?
    ) throws -> (root: PlanningStableDirectoryIdentity, lifeOS: PlanningStableDirectoryIdentity) {
#if canImport(Darwin)
        guard !lease.closed else { throw PlanningFilesystemError.needsReselection }
        return (
            try stableIdentity(for: lease.rootDescriptor, providerIdentifier: providerIdentifier),
            try stableIdentity(for: lease.lifeOSDescriptor, providerIdentifier: providerIdentifier)
        )
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    internal static func stableIdentity(at url: URL) throws -> PlanningStableDirectoryIdentity {
#if canImport(Darwin)
        guard url.isFileURL else { throw PlanningFilesystemError.invalid("authority.url") }
        let descriptor = try openDirectory(path: url.path)
        defer { _ = Darwin.close(descriptor) }
        return try stableIdentity(
            for: descriptor,
            providerIdentifier: providerIdentifier(at: url)
        )
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    internal static func openPrivateDirectory(
        at url: URL,
        create: Bool
    ) throws -> PlanningPrivateDirectoryLease {
#if canImport(Darwin)
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/" else {
            throw PlanningFilesystemError.invalid("privateDirectory")
        }
        let descriptor = try openDirectoryPathNoFollow(url.path, create: create, privateMode: true)
        return PlanningPrivateDirectoryLease(fileDescriptor: descriptor)
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    internal static func privateFileSize(
        in directory: PlanningPrivateDirectoryLease,
        name: String,
        maximum: Int
    ) throws -> Int? {
#if canImport(Darwin)
        guard !directory.closed else { throw PlanningFilesystemError.unavailable("privateDirectoryClosed") }
        guard let opened = try openPrivateRegular(
            parentFD: directory.fileDescriptor,
            name: name,
            maximum: maximum
        ) else { return nil }
        let descriptor = opened
        defer { _ = Darwin.close(descriptor.fd) }
        return descriptor.size
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    internal static func readPrivateFile(
        in directory: PlanningPrivateDirectoryLease,
        name: String,
        maximum: Int
    ) throws -> Data? {
#if canImport(Darwin)
        guard !directory.closed else { throw PlanningFilesystemError.unavailable("privateDirectoryClosed") }
        guard let opened = try openPrivateRegular(
            parentFD: directory.fileDescriptor,
            name: name,
            maximum: maximum
        ) else { return nil }
        defer { _ = Darwin.close(opened.fd) }
        return try readPrivateDescriptor(opened.fd, expectedSize: opened.size, maximum: maximum)
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    internal static func writePrivateFileAtomically(
        _ data: Data,
        in directory: PlanningPrivateDirectoryLease,
        name: String,
        replacing: Bool,
        maximum: Int
    ) throws {
#if canImport(Darwin)
        guard !directory.closed else { throw PlanningFilesystemError.unavailable("privateDirectoryClosed") }
        guard data.count <= maximum else { throw PlanningFilesystemError.backpressure("privateFile") }
        try validatePrivateComponent(name)
        let temporaryName = ".lifeos-private-tmp-\(UUID().uuidString.lowercased())"
        var descriptor: Int32 = -1
        var temporaryPresent = false
        do {
            descriptor = try createPrivateExclusive(
                parentFD: directory.fileDescriptor,
                name: temporaryName
            )
            temporaryPresent = true
            try writeAll(descriptor, data: data)
            try flush(descriptor, directory: false)
            let descriptorToClose = descriptor
            descriptor = -1
            guard Darwin.close(descriptorToClose) == 0 else {
                throw mapErrno(errno)
            }
            if !replacing,
               try privateFileSize(in: directory, name: name, maximum: maximum) != nil {
                throw PlanningFilesystemError.alreadyExists
            }
            if replacing {
                // Validate an existing destination when present.  The rename
                // itself replaces the directory entry atomically and never
                // follows a destination symlink.
                _ = try privateFileSize(in: directory, name: name, maximum: maximum)
            }
            let result = temporaryName.withCString { source in
                name.withCString { destination in
                    if replacing {
                        return renameat(
                            directory.fileDescriptor,
                            source,
                            directory.fileDescriptor,
                            destination
                        )
                    }
                    return renameatx_np(
                        directory.fileDescriptor,
                        source,
                        directory.fileDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard result == 0 else { throw mapErrno(errno) }
            temporaryPresent = false
            try flush(directory.fileDescriptor, directory: true)
        } catch {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
                descriptor = -1
            }
            // Keep an unlinked temporary as durable evidence if cleanup itself
            // cannot be proven.  The bounded inventory will classify it on the
            // next open instead of hiding a failed persistence operation.
            _ = temporaryPresent
            throw error
        }
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    internal static func removePrivateFile(
        in directory: PlanningPrivateDirectoryLease,
        name: String,
        beforeDirectoryFlush: (() throws -> Void)? = nil
    ) throws {
#if canImport(Darwin)
        guard !directory.closed else { throw PlanningFilesystemError.unavailable("privateDirectoryClosed") }
        try validatePrivateComponent(name)
        if unlinkat(directory.fileDescriptor, name, 0) != 0 {
            guard errno == ENOENT else { throw mapErrno(errno) }
        }
        // Also barrier an absent entry: a prior unlink may have failed to flush.
        // Instance-scoped injection exercises the actual unlink-to-flush boundary.
        try beforeDirectoryFlush?()
        try flush(directory.fileDescriptor, directory: true)
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    internal static func enumeratePrivateFiles(
        in directory: PlanningPrivateDirectoryLease,
        maximumEntries: Int,
        _ body: (String) throws -> Void
    ) throws {
#if canImport(Darwin)
        guard !directory.closed else { throw PlanningFilesystemError.unavailable("privateDirectoryClosed") }
        try enumerateNamesStreaming(
            fd: directory.fileDescriptor,
            maximumEntries: maximumEntries,
            errorReason: "privateEntries",
            body
        )
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    internal static func preservationInventory(
        _ lease: PlanningDirectoryLease
    ) throws -> PlanningPreservationInventory {
#if canImport(Darwin)
        guard !lease.closed else { throw PlanningFilesystemError.needsReselection }
        let inventory = PreservationInventoryAccumulator()
        try inventoryVaultArtifacts(
            directoryFD: lease.lifeOSDescriptor,
            depth: 0,
            accumulator: inventory
        )
        return inventory.value
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }

    internal static func reservePreservationCapacity(
        _ lease: PlanningDirectoryLease,
        additionalBytes: Int,
        additionalArtifacts: Int
    ) throws {
        let inventory = try preservationInventory(lease)
        try inventory.reserving(bytes: additionalBytes, artifacts: additionalArtifacts)
    }

#if canImport(Darwin)
    private static func openDirectory(path: String) throws -> Int32 {
        try openDirectoryPathNoFollow(path, create: false, privateMode: false)
    }

    private static func openDirectoryPathNoFollow(
        _ path: String,
        create: Bool,
        privateMode: Bool
    ) throws -> Int32 {
        guard path.hasPrefix("/"), path.utf8.count <= PlanningFilesystemLimits.maximumPathBytes else {
            throw PlanningFilesystemError.invalid("directoryPath")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, components.count <= PlanningFilesystemLimits.maximumDepth else {
            throw PlanningFilesystemError.invalid("directoryPath")
        }
        for component in components { try validateComponent(component) }

        let rootFD = "/".withCString { Darwin.open($0, directoryFlags) }
        guard rootFD >= 0 else { throw mapErrno(errno) }
        var current = rootFD
        var componentIndex = 0
        do {
            if let first = components.first, first == "var" || first == "tmp" {
                if privateMode {
                    try requireTrustedPrivateAnchor(rootFD)
                }
                // macOS exposes /var and /tmp as root-owned compatibility
                // symlinks to /private/var and /private/tmp. Validate the
                // exact alias once, then continue from its opened descriptor.
                let aliasFD = try openTrustedPrivateAlias(rootFD: rootFD, name: first)
                _ = Darwin.close(current)
                current = aliasFD
                componentIndex = 1
            }
            while componentIndex < components.count {
                let component = components[componentIndex]
                let isLeaf = componentIndex == components.count - 1
                var created = false
                let child: Int32
                do {
                    child = try openDirectory(parent: current, name: component)
                } catch let error as PlanningFilesystemError where error == .notFound && create {
                    let mkdirResult = component.withCString {
                        mkdirat(current, $0, mode_t(0o700))
                    }
                    let mkdirError = errno
                    if mkdirResult == 0 {
                        created = true
                        try flush(current, directory: true)
                    } else if mkdirError != EEXIST {
                        throw mapErrno(mkdirError)
                    }
                    child = try openDirectory(parent: current, name: component)
                }
                if privateMode && (created || isLeaf) {
                    do {
                        guard fchmod(child, mode_t(0o700)) == 0 else {
                            throw mapErrno(errno)
                        }
                        try excludeFromBackup(child)
                    } catch {
                        _ = Darwin.close(child)
                        throw error
                    }
                }
                _ = Darwin.close(current)
                current = child
                componentIndex += 1
            }
            return current
        } catch {
            _ = Darwin.close(current)
            throw map(error)
        }
    }

    private static func requireTrustedPrivateAnchor(_ fd: Int32) throws {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw mapErrno(errno) }
        guard (value.st_mode & S_IFMT) == S_IFDIR,
              value.st_uid == 0,
              (value.st_mode & mode_t(0o022)) == 0 else {
            throw PlanningFilesystemError.corruptEvidence
        }
    }

    private static func openTrustedPrivateAlias(rootFD: Int32, name: String) throws -> Int32 {
        guard name == "var" || name == "tmp" else {
            throw PlanningFilesystemError.invalid("privateAlias")
        }
        var alias = stat()
        let aliasResult = name.withCString {
            fstatat(rootFD, $0, &alias, AT_SYMLINK_NOFOLLOW)
        }
        guard aliasResult == 0 else { throw mapErrno(errno) }
        guard (alias.st_mode & S_IFMT) == S_IFLNK, alias.st_uid == 0 else {
            throw PlanningFilesystemError.corruptEvidence
        }
        let expectedTarget = Array("private/\(name)".utf8)
        var target = [UInt8](repeating: 0, count: expectedTarget.count + 1)
        let targetLength = target.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return name.withCString {
                readlinkat(rootFD, $0, base.assumingMemoryBound(to: CChar.self), rawBuffer.count)
            }
        }
        guard targetLength == expectedTarget.count,
              Array(target.prefix(targetLength)) == expectedTarget else {
            throw PlanningFilesystemError.corruptEvidence
        }
        var privateFD = try openDirectory(parent: rootFD, name: "private")
        do {
            let aliasFD = try openDirectory(parent: privateFD, name: name)
            let privateToClose = privateFD
            privateFD = -1
            _ = Darwin.close(privateToClose)
            var finalAlias = stat()
            let finalResult = name.withCString {
                fstatat(rootFD, $0, &finalAlias, AT_SYMLINK_NOFOLLOW)
            }
            guard finalResult == 0,
                  finalAlias.st_dev == alias.st_dev,
                  finalAlias.st_ino == alias.st_ino,
                  finalAlias.st_mode == alias.st_mode,
                  finalAlias.st_uid == alias.st_uid,
                  finalAlias.st_gid == alias.st_gid else {
                _ = Darwin.close(aliasFD)
                throw PlanningFilesystemError.corruptEvidence
            }
            return aliasFD
        } catch {
            if privateFD >= 0 { _ = Darwin.close(privateFD) }
            throw error
        }
    }

    private static func openDirectory(parent: Int32, name: String) throws -> Int32 {
        try validateComponent(name)
        let fd = name.withCString { Darwin.openat(parent, $0, directoryFlags) }
        guard fd >= 0 else { throw mapErrno(errno) }
        do {
            guard try fileType(for: fd) == 2 else { throw PlanningFilesystemError.invalid("directory") }
            return fd
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    private static func stableIdentity(
        for fd: Int32,
        providerIdentifier: String?
    ) throws -> PlanningStableDirectoryIdentity {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw mapErrno(errno) }
        guard (value.st_mode & S_IFMT) == S_IFDIR else {
            throw PlanningFilesystemError.invalid("authority.directory")
        }
        return try PlanningStableDirectoryIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: UInt32(value.st_mode),
            owner: UInt32(value.st_uid),
            group: UInt32(value.st_gid),
            providerIdentifier: providerIdentifier
        )
    }

    private static func providerIdentifier(at url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemIsSharedKey,
            .volumeLocalizedFormatDescriptionKey
        ]) else { return nil }
        if values.isUbiquitousItem == true {
            return values.ubiquitousItemIsShared == true ? "icloud.shared" : "icloud"
        }
        return values.volumeLocalizedFormatDescription
    }

    private static func openPrivateRegular(
        parentFD: Int32,
        name: String,
        maximum: Int
    ) throws -> (fd: Int32, size: Int)? {
        try validatePrivateComponent(name)
        let fd = name.withCString {
            Darwin.openat(parentFD, $0, leafFlags)
        }
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw mapErrno(errno)
        }
        do {
            let metadata = try regularIdentityAndSize(fd: fd, maximumBytes: maximum)
            guard metadata.identity.fileType == 1 else {
                throw PlanningFilesystemError.unsupportedFilesystem
            }
            return (fd, metadata.size)
        } catch {
            _ = Darwin.close(fd)
            throw map(error)
        }
    }

    private static func readPrivateDescriptor(
        _ fd: Int32,
        expectedSize: Int,
        maximum: Int
    ) throws -> Data {
        let before = try regularIdentityAndSize(fd: fd, maximumBytes: maximum)
        guard before.size == expectedSize else { throw PlanningFilesystemError.changedDuringRead }
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw mapErrno(errno) }
        let data = try readAll(fd, maximumBytes: maximum)
        let after = try regularIdentityAndSize(fd: fd, maximumBytes: maximum)
        guard before.identity == after.identity,
              before.size == after.size,
              data.count == expectedSize else {
            throw PlanningFilesystemError.changedDuringRead
        }
        return data
    }

    private static func createPrivateExclusive(parentFD: Int32, name: String) throws -> Int32 {
        try validatePrivateComponent(name)
        let fd = name.withCString {
            Darwin.openat(
                parentFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard fd >= 0 else { throw mapErrno(errno) }
        do {
            guard fchmod(fd, mode_t(0o600)) == 0 else { throw mapErrno(errno) }
            try excludeFromBackup(fd)
            return fd
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    private static func excludeFromBackup(_ fd: Int32) throws {
        let key = "com.apple.metadata:com_apple_backup_exclude_item"
        let value = try PropertyListSerialization.data(
            fromPropertyList: true,
            format: .binary,
            options: 0
        )
        let result = value.withUnsafeBytes { rawBuffer -> Int32 in
            key.withCString { keyPointer in
                fsetxattr(
                    fd,
                    keyPointer,
                    rawBuffer.baseAddress,
                    value.count,
                    0,
                    0
                )
            }
        }
        if result != 0 {
            let error = errno
            guard error == ENOTSUP || error == EINVAL else { throw mapErrno(error) }
            // Filesystems without Apple backup xattrs retain descriptor and
            // fsync protection; the unsupported capability is explicit.
        }
    }

    private static func openLeaf(parent: Int32, name: String) throws -> Int32? {
        let fd = name.withCString { Darwin.openat(parent, $0, leafFlags) }
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw mapErrno(errno)
        }
        do {
            guard try fileType(for: fd) == 1 else { throw PlanningFilesystemError.unsupportedFilesystem }
            var stat = stat()
            guard fstat(fd, &stat) == 0 else { throw mapErrno(errno) }
            guard stat.st_nlink == 1 else { throw PlanningFilesystemError.unsupportedFilesystem }
            return fd
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    private static func duplicate(_ fd: Int32) throws -> Int32 {
        let result = Darwin.dup(fd)
        guard result >= 0 else { throw mapErrno(errno) }
        return result
    }

    private static func createExclusive(parentFD: Int32, name: String, mode: Int32) throws -> Int32 {
        let fd = name.withCString {
            Darwin.openat(parentFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(mode))
        }
        guard fd >= 0 else { throw mapErrno(errno) }
        return fd
    }

    private static func rename(
        parentFD: Int32,
        source: String,
        destination: String,
        flags: UInt32
    ) throws {
        let result = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                renameatx_np(parentFD, sourcePointer, parentFD, destinationPointer, flags)
            }
        }
        guard result == 0 else { throw mapErrno(errno) }
    }

    private static func identity(for fd: Int32) throws -> PlanningFileIdentity {
        var stat = stat()
        guard fstat(fd, &stat) == 0 else { throw mapErrno(errno) }
        return try PlanningFileIdentity(
            device: UInt64(stat.st_dev),
            inode: UInt64(stat.st_ino),
            fileType: try fileType(for: stat)
        )
    }

    private static func identityIfPresent(parent: Int32, name: String) throws -> PlanningFileIdentity? {
        var stat = stat()
        let result = name.withCString { fstatat(parent, $0, &stat, AT_SYMLINK_NOFOLLOW) }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw mapErrno(errno)
        }
        return try PlanningFileIdentity(
            device: UInt64(stat.st_dev),
            inode: UInt64(stat.st_ino),
            fileType: try fileType(for: stat)
        )
    }

    private static func regularIdentityAndSize(
        fd: Int32,
        maximumBytes: Int
    ) throws -> (identity: PlanningFileIdentity, size: Int) {
        var stat = stat()
        guard fstat(fd, &stat) == 0 else { throw mapErrno(errno) }
        guard try fileType(for: stat) == 1, stat.st_nlink == 1 else {
            throw PlanningFilesystemError.unsupportedFilesystem
        }
        let size = Int(stat.st_size)
        guard size >= 0, size <= maximumBytes else {
            throw PlanningFilesystemError.backpressure("document")
        }
        return (
            try PlanningFileIdentity(device: UInt64(stat.st_dev), inode: UInt64(stat.st_ino), fileType: 1),
            size
        )
    }

    private static func fileType(for fd: Int32) throws -> UInt32 {
        var stat = stat()
        guard fstat(fd, &stat) == 0 else { throw mapErrno(errno) }
        return try fileType(for: stat)
    }

    private static func fileType(for stat: stat) throws -> UInt32 {
        let mode = stat.st_mode & S_IFMT
        if mode == S_IFREG { return 1 }
        if mode == S_IFDIR { return 2 }
        throw PlanningFilesystemError.unsupportedFilesystem
    }

    private static func rejectSymlink(at path: String) throws {
        var stat = stat()
        guard lstat(path, &stat) == 0 else { throw mapErrno(errno) }
        guard (stat.st_mode & S_IFMT) != S_IFLNK else {
            throw PlanningFilesystemError.needsReselection
        }
        guard (stat.st_mode & S_IFMT) == S_IFDIR else {
            throw PlanningFilesystemError.invalid("root.directory")
        }
    }

    private static func readMarker(fd: Int32) throws -> PlanningVaultIdentity {
        guard let markerFD = try openLeaf(parent: fd, name: ".lifeos-vault.json") else {
            throw PlanningFilesystemError.needsReselection
        }
        defer { _ = Darwin.close(markerFD) }
        let (_, size) = try regularIdentityAndSize(fd: markerFD, maximumBytes: PlanningFilesystemLimits.maximumMarkerBytes)
        var data = Data()
        data.reserveCapacity(size)
        var buffer = [UInt8](repeating: 0, count: min(PlanningFilesystemLimits.ioChunkBytes, max(size, 1)))
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                Darwin.read(markerFD, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw mapErrno(errno)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= PlanningFilesystemLimits.maximumMarkerBytes else {
                throw PlanningFilesystemError.backpressure("marker")
            }
        }
        do {
            return try JSONDecoder().decode(PlanningVaultIdentity.self, from: data)
        } catch {
            throw PlanningFilesystemError.corruptEvidence
        }
    }

    private static func readAll(_ fd: Int32, maximumBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(PlanningFilesystemLimits.ioChunkBytes, maximumBytes))
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw mapErrno(errno)
            }
            if count == 0 { return data }
            guard data.count <= maximumBytes - count else {
                throw PlanningFilesystemError.backpressure("read")
            }
            data.append(buffer, count: count)
        }
    }

    private static func writeAll(_ fd: Int32, data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw mapErrno(errno)
                }
                guard count > 0 else { throw PlanningFilesystemError.unavailable("shortWrite") }
                offset += count
            }
        }
    }

    private static func enumerateNames(fd: Int32) throws -> [String] {
        var names: [String] = []
        try enumerateNamesStreaming(
            fd: fd,
            maximumEntries: PlanningFilesystemLimits.maximumDirectoryEntries,
            errorReason: "directoryEntries"
        ) { names.append($0) }
        return names
    }

    private static func enumerateNamesStreaming(
        fd: Int32,
        maximumEntries: Int,
        errorReason: String,
        _ body: (String) throws -> Void
    ) throws {
        let directoryFD = ".".withCString {
            Darwin.openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else {
            throw mapErrno(errno)
        }
        guard let directory = fdopendir(directoryFD) else {
            _ = Darwin.close(directoryFD)
            throw mapErrno(errno)
        }
        var completed = false
        defer {
            if !completed { _ = closedir(directory) }
        }
        var collisionKeys: Set<String> = []
        var count = 0
        do {
            while true {
                errno = 0
                guard let entry = readdir(directory) else { break }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }
                guard name.utf8.count <= PlanningFilesystemLimits.maximumDirectoryNameBytes else {
                    throw PlanningFilesystemError.backpressure("directoryName")
                }
                count += 1
                guard count <= maximumEntries else {
                    throw PlanningFilesystemError.backpressure(errorReason)
                }
                let key = planningFilesystemCollisionKey(name)
                guard collisionKeys.insert(key).inserted else {
                    throw PlanningFilesystemError.caseCollision
                }
                try body(name)
            }
            guard errno == 0 else { throw mapErrno(errno) }
            guard closedir(directory) == 0 else { throw mapErrno(errno) }
            completed = true
        } catch {
            throw map(error)
        }
    }

    private final class PreservationInventoryAccumulator {
        private(set) var bytes = 0
        private(set) var artifacts = 0
        private(set) var visitedEntries = 0

        var value: PlanningPreservationInventory {
            PlanningPreservationInventory(
                bytes: bytes,
                artifacts: artifacts,
                visitedEntries: visitedEntries
            )
        }

        func visit() throws {
            let (next, overflow) = visitedEntries.addingReportingOverflow(1)
            guard !overflow, next <= PlanningFilesystemLimits.maximumVisitedEntries else {
                throw PlanningFilesystemError.backpressure("preservationEntries")
            }
            visitedEntries = next
        }

        func addArtifact(bytes size: Int) throws {
            guard size >= 0 else { throw PlanningFilesystemError.corruptEvidence }
            let (nextArtifacts, artifactOverflow) = artifacts.addingReportingOverflow(1)
            let (nextBytes, byteOverflow) = bytes.addingReportingOverflow(size)
            guard !artifactOverflow, !byteOverflow,
                  nextArtifacts <= PlanningFilesystemLimits.maximumPreservedArtifacts,
                  nextBytes <= PlanningFilesystemLimits.maximumPreservedBytes else {
                throw PlanningFilesystemError.backpressure("preservation")
            }
            artifacts = nextArtifacts
            bytes = nextBytes
        }
    }

    private static func inventoryVaultArtifacts(
        directoryFD: Int32,
        depth: Int,
        accumulator: PreservationInventoryAccumulator
    ) throws {
        guard depth <= PlanningFilesystemLimits.maximumDepth else {
            throw PlanningFilesystemError.backpressure("preservationDepth")
        }
        try enumerateNamesStreaming(
            fd: directoryFD,
            maximumEntries: PlanningFilesystemLimits.maximumDirectoryEntries,
            errorReason: "preservationEntries"
        ) { name in
            try accumulator.visit()
            var entry = stat()
            let result = name.withCString {
                fstatat(directoryFD, $0, &entry, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0 else { throw mapErrno(errno) }
            let type = entry.st_mode & S_IFMT
            if type == S_IFDIR {
                if isPreservationArtifactName(name) {
                    try accumulator.addArtifact(bytes: 0)
                }
                let child = try openDirectory(parent: directoryFD, name: name)
                defer { _ = Darwin.close(child) }
                try inventoryVaultArtifacts(
                    directoryFD: child,
                    depth: depth + 1,
                    accumulator: accumulator
                )
            } else if type == S_IFREG {
                if isPreservationArtifactName(name) {
                    let size = Int(entry.st_size)
                    guard size >= 0, size <= PlanningFilesystemLimits.maximumPreservedBytes else {
                        throw PlanningFilesystemError.backpressure("preservationFile")
                    }
                    try accumulator.addArtifact(bytes: size)
                }
            } else {
                throw PlanningFilesystemError.unsupportedFilesystem
            }
        }
    }

    private static func isPreservationArtifactName(_ name: String) -> Bool {
        guard name != ".lifeos-vault.json" else { return false }
        let lowercased = name.lowercased()
        return lowercased.hasPrefix(".lifeos-")
            || lowercased.hasPrefix(".tmp-")
            || lowercased.hasPrefix(".backup-")
            || lowercased.hasPrefix(".witness-")
            || lowercased.hasPrefix(".displaced-")
            || lowercased.hasPrefix(".orphan-")
            || lowercased.contains("witness")
            || lowercased.contains("displaced")
            || lowercased.contains("orphan")
    }

    private static func rejectCollision(in fd: Int32, requested: String) throws {
        let requestedKey = planningFilesystemCollisionKey(requested)
        for name in try enumerateNames(fd: fd) where planningFilesystemCollisionKey(name) == requestedKey && name != requested {
            throw PlanningFilesystemError.caseCollision
        }
    }

    private static func validateComponent(_ component: String) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !component.unicodeScalars.contains(where: { $0.value == 0 }),
              component.utf8.count <= PlanningFilesystemLimits.maximumDirectoryNameBytes else {
            throw PlanningFilesystemError.invalid("pathComponent")
        }
    }

    private static func validatePrivateComponent(_ component: String) throws {
        try validateComponent(component)
        guard !component.hasPrefix("/") else {
            throw PlanningFilesystemError.invalid("privateComponent")
        }
    }

    private static func map(_ error: Error) -> PlanningFilesystemError {
        if let error = error as? PlanningFilesystemError { return error }
        if let error = error as? PlanningStorageError {
            switch error {
            case .databaseFull: return .diskFull
            case .staleAccess: return .needsReselection
            case .backpressure(let reason): return .backpressure(reason)
            default: return .unavailable("storage")
            }
        }
        return .unavailable("operation")
    }

    private static func mapErrno(_ value: Int32) -> PlanningFilesystemError {
        switch value {
        case ENOENT: return .notFound
        case EEXIST: return .alreadyExists
        case EACCES, EPERM: return .permissionDenied
        case EROFS: return .readOnly
        case ENOSPC, EDQUOT: return .diskFull
        case ENOTDIR, ELOOP: return .needsReselection
        case ENXIO, EAGAIN, ETIMEDOUT: return .providerOffline
        case EINTR: return .cancelled
        default: return .unavailable("errno(value)")
        }
    }
#endif
}
