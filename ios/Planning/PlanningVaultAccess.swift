import Foundation

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
public protocol PlanningVaultPickerAdapter: AnyObject {
    func selectDirectoryURL(presenting: AnyObject?) throws -> URL?
}

public struct PlanningUserSelectedDirectory: @unchecked Sendable, Equatable {
    public let url: URL
    public let selectionID: UUID
    public let hasObsidianMarker: Bool
    public let hasExplicitRootConfirmation: Bool
    public let providerIdentifier: String?

    fileprivate let provenance: PlanningSelectionProvenance
    fileprivate let rootConfirmed: Bool

    fileprivate init(
        url: URL,
        provenance: PlanningSelectionProvenance,
        rootConfirmed: Bool? = nil
    ) throws {
        guard url.isFileURL else { throw PlanningFilesystemError.invalid("selection.url") }
        let standardized = url.standardizedFileURL
        guard standardized.path != "/", !standardized.pathComponents.contains(where: {
            planningFilesystemCollisionKey($0) == planningFilesystemCollisionKey("Uni")
        }) else {
            throw PlanningFilesystemError.invalid("selection.root")
        }
        guard !FileManager.default.fileExists(atPath: standardized.appendingPathComponent(".symlink").path) else {
            throw PlanningFilesystemError.invalid("selection.symlink")
        }
        var info = stat()
#if canImport(Darwin)
        guard lstat(standardized.path, &info) == 0 else { throw PlanningFilesystemError.notFound }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw PlanningFilesystemError.invalid("selection.directory")
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw PlanningFilesystemError.needsReselection
        }
#else
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            throw PlanningFilesystemError.notFound
        }
#endif
        let marker = standardized.appendingPathComponent(".obsidian", isDirectory: true)
        let hasObsidianMarker = FileManager.default.fileExists(atPath: marker.path)
        self.url = standardized
        self.selectionID = UUID()
        self.hasObsidianMarker = hasObsidianMarker
        self.rootConfirmed = provenance == .testFactory || rootConfirmed == true || hasObsidianMarker
        self.hasExplicitRootConfirmation = self.rootConfirmed
        self.providerIdentifier = Self.providerIdentifier(for: standardized)
        self.provenance = provenance
    }

    internal static func picker(url: URL) throws -> PlanningUserSelectedDirectory {
        try PlanningUserSelectedDirectory(url: url, provenance: .picker)
    }

    internal static func testFactory(url: URL) throws -> PlanningUserSelectedDirectory {
        try PlanningUserSelectedDirectory(url: url, provenance: .testFactory)
    }

    internal var isTestFactory: Bool { provenance == .testFactory }

    private static func providerIdentifier(for url: URL) -> String? {
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
}

private enum PlanningSelectionProvenance: String, Sendable {
    case picker
    case testFactory
}

public struct PlanningVaultAccessSnapshot: Sendable, Equatable {
    public let state: PlanningVaultAccessState
    public let vaultID: UUID?
    public let selectionGeneration: UUID?
    public let rootIdentity: PlanningFileIdentity?
    public let lifeOSIdentity: PlanningFileIdentity?
    public let capabilities: PlanningFilesystemCapabilities
    public let providerIdentifier: String?

    public init(
        state: PlanningVaultAccessState,
        vaultID: UUID?,
        selectionGeneration: UUID?,
        rootIdentity: PlanningFileIdentity?,
        lifeOSIdentity: PlanningFileIdentity?,
        capabilities: PlanningFilesystemCapabilities,
        providerIdentifier: String?
    ) {
        self.state = state
        self.vaultID = vaultID
        self.selectionGeneration = selectionGeneration
        self.rootIdentity = rootIdentity
        self.lifeOSIdentity = lifeOSIdentity
        self.capabilities = capabilities
        self.providerIdentifier = providerIdentifier
    }
}

@MainActor
public enum PlanningVaultSelectionBroker {
    #if os(iOS)
    private static var installedAdapter: PlanningVaultPickerAdapter?

    public static func install(adapter: PlanningVaultPickerAdapter?) {
        installedAdapter = adapter
    }
    #endif

    /// The picker is intentionally an adapter only.  App navigation must call
    /// it after an explicit user action and then pass the resulting opaque
    /// selection to PlanningVaultAccess.
    public static func selectDirectory(
        presenting: AnyObject? = nil
    ) throws -> PlanningUserSelectedDirectory? {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Vault"
        if let window = presenting as? NSWindow {
            var result: NSApplication.ModalResponse = .abort
            panel.beginSheetModal(for: window) { response in result = response }
            while result == .abort && panel.isVisible {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
            guard result == .OK, let url = panel.url else { return nil }
            return try PlanningUserSelectedDirectory.picker(url: url)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try PlanningUserSelectedDirectory.picker(url: url)
#elseif os(iOS)
        guard let installedAdapter else {
            throw PlanningFilesystemError.unavailable("pickerAdapterUnavailable")
        }
        guard let url = try installedAdapter.selectDirectoryURL(presenting: presenting) else {
            return nil
        }
        return try PlanningUserSelectedDirectory.picker(url: url)
#else
        throw PlanningFilesystemError.unsupportedFilesystem
#endif
    }
}

public final class PlanningVaultAccess: @unchecked Sendable {
    private let lock = NSLock()
    private let applicationSupportDirectory: URL
    private let deviceID: UUID
    private let grantStore: PlanningVaultGrantStore
    private var selectedDirectory: PlanningUserSelectedDirectory?
    private var vaultIdentity: PlanningVaultIdentity?
    private var generation: UUID?
    private var state: PlanningVaultAccessState = .unselected
    private var capabilities = PlanningFilesystemCapabilities.unavailableSignedApp
    private var rootURL: URL?
    private var activeScopeURL: URL?
    private var scopeActive = false
    private var deferredScopeURLs: [URL] = []
    private var activeLeaseCount = 0
    private var rootAuthority: PlanningStableDirectoryIdentity?
    private var lifeOSAuthority: PlanningStableDirectoryIdentity?
    private var lifeOSIdentity: PlanningFileIdentity?
    private var testFactory = false
    private var testGrant: PlanningTestGrant?
    private let initializationStore: PlanningInitializationIntentStore
    private let testGrantStore: PlanningTestGrantStore
    private let authorityStore: PlanningAuthorityStore

    public init(
        applicationSupportDirectory: URL,
        deviceID: UUID = UUID()
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.deviceID = deviceID
        self.grantStore = PlanningVaultGrantStore(
            applicationSupportDirectory: applicationSupportDirectory,
            deviceID: deviceID
        )
        self.initializationStore = PlanningInitializationIntentStore(
            applicationSupportDirectory: applicationSupportDirectory,
            deviceID: deviceID
        )
        self.testGrantStore = PlanningTestGrantStore(
            applicationSupportDirectory: applicationSupportDirectory,
            deviceID: deviceID
        )
        self.authorityStore = PlanningAuthorityStore(
            applicationSupportDirectory: applicationSupportDirectory,
            deviceID: deviceID
        )
    }

    internal static func makeTesting(
        rootURL: URL,
        applicationSupportDirectory: URL,
        deviceID: UUID = UUID()
    ) throws -> PlanningVaultAccess {
        let access = PlanningVaultAccess(
            applicationSupportDirectory: applicationSupportDirectory,
            deviceID: deviceID
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: rootURL)
        access.selectedDirectory = selection
        access.testFactory = true
        access.testGrant = try access.testGrantStore.load()
        return access
    }

    public func select(
        selection: PlanningUserSelectedDirectory,
        intent: PlanningVaultSelectionIntent
    ) throws -> PlanningVaultAccessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        try validateSelection(selection)

        let oldScopes = takeActiveScopeLocked()
        stopScopes(oldScopes)

        let isTestSelection = selection.isTestFactory
        var startedScope = false
        var completed = false
        if !isTestSelection {
            guard selection.provenance == .picker,
                  selection.rootConfirmed,
                  selection.providerIdentifier == "icloud"
                    || selection.providerIdentifier == "icloud.shared" else {
                throw PlanningFilesystemError.unsupportedFilesystem
            }
            startedScope = selection.url.startAccessingSecurityScopedResource()
            guard startedScope else { throw PlanningFilesystemError.permissionDenied }
            activeScopeURL = selection.url
            scopeActive = true
        }
        defer {
            if startedScope && !completed {
                selection.url.stopAccessingSecurityScopedResource()
                activeScopeURL = nil
                scopeActive = false
            }
        }

        let vaultID: UUID
        let root = try rootIdentity(at: selection.url)
        let selectedRootAuthority = try PlanningSafeFileIO.stableIdentity(at: selection.url)
        let savedIntent = try initializationStore.load()
        if let savedIntent,
           savedIntent.rootAuthority != selectedRootAuthority {
            throw PlanningFilesystemError.identityChanged
        }
        switch intent {
        case .initialize:
            if !isTestSelection {
                // The current signed target has no user-selected read/write
                // entitlement. It may inspect an existing scoped vault, but it
                // must not create a marker before that capability is present.
                throw PlanningFilesystemError.unsupportedFilesystem
            }
            if let existing = try? readMarker(at: selection.url) {
                vaultID = existing.vaultID
            } else if let savedIntent,
                      savedIntent.rootIdentity == root {
                vaultID = savedIntent.vaultID
            } else {
                vaultID = UUID()
            }
            let temporaryName = savedIntent?.temporaryName
            ?? ".lifeos-tmp-\(UUID().uuidString.lowercased())"
            let generation = testGrant?.selectionGeneration ?? UUID()
            if (try? readMarker(at: selection.url)) == nil {
                let initialization = try PlanningInitializationIntent(
                    vaultID: vaultID,
                    selectionID: selection.selectionID,
                    rootIdentity: root,
                    rootAuthority: selectedRootAuthority,
                    generation: generation,
                    temporaryName: temporaryName
                )
                try initializationStore.save(initialization)
                _ = try PlanningSafeFileIO.initializeLifeOS(
                    at: selection.url,
                    vaultID: vaultID,
                    ownedTemporaryName: temporaryName
                )
            }
            try initializationStore.remove()
        case .attach(let expectedVaultID):
            let marker = try readMarker(at: selection.url)
            guard marker.vaultID == expectedVaultID else { throw PlanningFilesystemError.identityChanged }
            vaultID = expectedVaultID
        }

        let nextGeneration = testGrant?.vaultID == vaultID
            && testGrant?.rootIdentity == root
            ? testGrant!.selectionGeneration
            : UUID()
        let lease = try PlanningSafeFileIO.openRoot(
            selection.url,
            generation: nextGeneration,
            expectedVaultID: vaultID
        )
        let selectedLifeOSIdentity = lease.lifeOSIdentity
        let selectedLifeOSAuthority = lease.lifeOSAuthority
        guard lease.rootAuthority == selectedRootAuthority else {
            lease.close()
            throw PlanningFilesystemError.identityChanged
        }
        let safeCapabilities = PlanningSafeFileIO.capabilities(for: lease)
        lease.close()
        let productionCapable = selection.isTestFactory
        let detected = PlanningFilesystemCapabilities(
            signedAppAccessAvailable: productionCapable,
            canRead: true,
            canPublish: productionCapable
                && safeCapabilities.exclusiveRename
                && safeCapabilities.swapRename
                && safeCapabilities.descriptorTraversal
                && safeCapabilities.directoryFlush,
            supportsDescriptorTraversal: safeCapabilities.descriptorTraversal,
            supportsExclusiveRename: safeCapabilities.exclusiveRename,
            supportsSwapRename: safeCapabilities.swapRename,
            supportsDirectoryFlush: safeCapabilities.directoryFlush,
            providerIdentifier: selection.providerIdentifier,
            reasonCode: productionCapable ? nil : "userSelectedReadWriteUnavailable"
        )

        let grant = try makeGrant(
            selection: selection,
            vaultID: vaultID,
            generation: nextGeneration,
            rootIdentity: root
        )
        if !selection.isTestFactory {
            try grantStore.save(grant)
        } else {
            let testingGrant = try PlanningTestGrant(
                deviceID: deviceID,
                vaultID: vaultID,
                rootIdentity: root,
                selectionGeneration: nextGeneration
            )
            try testGrantStore.save(testingGrant)
            testGrant = testingGrant
        }
        try authorityStore.save(
            PlanningAuthorityRecord(
                root: selectedRootAuthority,
                lifeOS: selectedLifeOSAuthority,
                providerIdentifier: selection.providerIdentifier
            )
        )
        selectedDirectory = selection
        vaultIdentity = try PlanningVaultIdentity(vaultID: vaultID)
        generation = nextGeneration
        rootURL = selection.url
        rootAuthority = selectedRootAuthority
        lifeOSAuthority = selectedLifeOSAuthority
        lifeOSIdentity = selectedLifeOSIdentity
        state = .ready
        capabilities = detected
        testFactory = selection.isTestFactory
        completed = true
        return snapshotLocked()
    }

    public func restore() throws -> PlanningVaultAccessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let oldScopes = takeActiveScopeLocked()
        stopScopes(oldScopes)
        guard let stored = try grantStore.load() else {
            state = .unselected
            return snapshotLocked()
        }
        guard stored.deviceID == deviceID else {
            state = .needsReselection
            return snapshotLocked()
        }
        guard let storedAuthority = try authorityStore.load() else {
            state = .needsReselection
            throw PlanningFilesystemError.needsReselection
        }
        var resolvedURL: URL?
        var scopeStarted = false
        do {
            var stale = false
            let url: URL
#if os(macOS)
            url = try URL(
                resolvingBookmarkData: stored.bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
#else
            url = try URL(
                resolvingBookmarkData: stored.bookmarkData,
                options: [.withoutUI, .withoutImplicitStartAccessing],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
#endif
            resolvedURL = url
            scopeStarted = url.startAccessingSecurityScopedResource()
            guard scopeStarted else { throw PlanningFilesystemError.permissionDenied }
            let lease = try PlanningSafeFileIO.openRoot(
                url,
                generation: stored.selectionGeneration,
                expectedVaultID: stored.vaultID
            )
            let root = lease.rootIdentity
            let selectedLifeOSIdentity = lease.lifeOSIdentity
            let selectedRootAuthority = lease.rootAuthority
            let selectedLifeOSAuthority = lease.lifeOSAuthority
            let safeCapabilities = PlanningSafeFileIO.capabilities(for: lease)
            lease.close()
            guard stored.lastValidatedRootIdentity == nil || stored.lastValidatedRootIdentity == root else {
                throw PlanningFilesystemError.identityChanged
            }
            guard storedAuthority.root == selectedRootAuthority,
                  storedAuthority.lifeOS == selectedLifeOSAuthority else {
                throw PlanningFilesystemError.identityChanged
            }
            if stale {
                let refreshed = try makeGrant(
                    selection: try PlanningUserSelectedDirectory.picker(url: url),
                    vaultID: stored.vaultID,
                    generation: stored.selectionGeneration,
                    rootIdentity: root
                )
                try grantStore.save(refreshed)
            }
            activeScopeURL = url
            scopeActive = true
            selectedDirectory = try PlanningUserSelectedDirectory.picker(url: url)
            vaultIdentity = try PlanningVaultIdentity(vaultID: stored.vaultID)
            generation = stored.selectionGeneration
            rootURL = url
            rootAuthority = selectedRootAuthority
            lifeOSAuthority = selectedLifeOSAuthority
            lifeOSIdentity = selectedLifeOSIdentity
            state = .ready
            capabilities = PlanningFilesystemCapabilities(
                signedAppAccessAvailable: false,
                canRead: true,
                canPublish: false,
                supportsDescriptorTraversal: safeCapabilities.descriptorTraversal,
                supportsExclusiveRename: safeCapabilities.exclusiveRename,
                supportsSwapRename: safeCapabilities.swapRename,
                supportsDirectoryFlush: safeCapabilities.directoryFlush,
                providerIdentifier: selectedDirectory?.providerIdentifier,
                reasonCode: "userSelectedReadWriteUnavailable"
            )
            return snapshotLocked()
        } catch {
            if scopeStarted {
                resolvedURL?.stopAccessingSecurityScopedResource()
                activeScopeURL = nil
                scopeActive = false
            }
            state = .needsReselection
            throw mapAccessError(error)
        }
    }

    public func withLease<T>(_ body: (PlanningDirectoryLease) throws -> T) throws -> T {
        try withLease(coordinatedRootURL: nil, expectedGeneration: nil, body)
    }

    internal func withLease<T>(
        coordinatedRootURL: URL?,
        expectedGeneration: UUID?,
        _ body: (PlanningDirectoryLease) throws -> T
    ) throws -> T {
        lock.lock()
        guard let rootURL, let generation, let vaultIdentity, state == .ready else {
            lock.unlock()
            throw PlanningFilesystemError.unselected
        }
        let activeScope = activeScopeURL
        let isTestFactory = testFactory
        let leaseGeneration = expectedGeneration ?? generation
        guard leaseGeneration == generation,
              isTestFactory || (activeScope != nil && scopeActive) else {
            lock.unlock()
            throw isTestFactory ? PlanningFilesystemError.identityChanged : PlanningFilesystemError.needsReselection
        }
        activeLeaseCount += 1
        lock.unlock()
        defer { releaseLease() }

        let openedURL = coordinatedRootURL ?? rootURL
        if coordinatedRootURL != nil {
            let openedIdentity = try rootIdentity(at: openedURL)
            let selectedIdentity = try rootIdentity(at: rootURL)
            guard openedIdentity == selectedIdentity else {
                throw PlanningFilesystemError.identityChanged
            }
        }
        let lease = try PlanningSafeFileIO.openRoot(
            openedURL,
            generation: leaseGeneration,
            expectedVaultID: vaultIdentity.vaultID
        )
        defer { lease.close() }
        try validateLease(lease)
        let result = try body(lease)
        try validateLease(lease)
        return result
    }

    internal var selectedRootURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        guard state == .ready else { return nil }
        return rootURL
    }

    internal func validateLease(_ lease: PlanningDirectoryLease) throws {
        lock.lock()
        let expectedRootAuthority = rootAuthority
        let expectedLifeOSAuthority = lifeOSAuthority
        let valid = state == .ready
            && generation == lease.generation
            && vaultIdentity?.vaultID == lease.vaultID
            && (testFactory || (activeScopeURL != nil && scopeActive))
        lock.unlock()
        guard valid,
              expectedRootAuthority == lease.rootAuthority,
              expectedLifeOSAuthority == lease.lifeOSAuthority else {
            throw PlanningFilesystemError.identityChanged
        }
    }

    internal func requirePublishCapability() throws {
        lock.lock()
        let allowed = state == .ready
            && capabilities.canPublish
            && generation != nil
            && rootURL != nil
            && (testFactory || (activeScopeURL != nil && scopeActive))
        let currentState = state
        lock.unlock()
        guard allowed else {
            throw currentState == .ready
                ? PlanningFilesystemError.unsupportedFilesystem
                : PlanningFilesystemError.unselected
        }
    }

    public func revoke() {
        lock.lock()
        let scopes = takeActiveScopeLocked()
        selectedDirectory = nil
        vaultIdentity = nil
        lifeOSIdentity = nil
        rootAuthority = nil
        lifeOSAuthority = nil
        generation = UUID()
        rootURL = nil
        state = .unselected
        capabilities = PlanningFilesystemCapabilities.unavailableSignedApp
        testFactory = false
        lock.unlock()
        stopScopes(scopes)
        try? grantStore.remove()
        try? authorityStore.remove()
    }

    /// Releases the current security scope exactly once. The persisted grant
    /// remains available for an explicit restore or re-selection.
    public func close() {
        lock.lock()
        let scopes = takeActiveScopeLocked()
        if state == .ready {
            state = .needsReselection
            capabilities = PlanningFilesystemCapabilities.unavailableSignedApp
        }
        lock.unlock()
        stopScopes(scopes)
    }

    public var snapshot: PlanningVaultAccessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    public var selectedVault: PlanningVaultIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return vaultIdentity
    }

    private func validateSelection(_ selection: PlanningUserSelectedDirectory) throws {
        guard selection.url.isFileURL else { throw PlanningFilesystemError.invalid("selection.url") }
        guard !selection.url.pathComponents.contains(where: {
            planningFilesystemCollisionKey($0) == planningFilesystemCollisionKey("Uni")
        }) else { throw PlanningFilesystemError.invalid("selection.uni") }
        let components = selection.url.pathComponents
        guard components.last.map({ planningFilesystemCollisionKey($0) }) != Optional(planningFilesystemCollisionKey("LifeOS")),
              !components.dropLast().contains(where: {
                  planningFilesystemCollisionKey($0) == planningFilesystemCollisionKey("LifeOS")
              }) else {
            throw PlanningFilesystemError.invalid("selection.nestedLifeOS")
        }
        if !selection.isTestFactory {
            guard selection.rootConfirmed,
                  selection.hasObsidianMarker,
                  selection.providerIdentifier == "icloud"
                    || selection.providerIdentifier == "icloud.shared" else {
                throw PlanningFilesystemError.unsupportedFilesystem
            }
        }
        let rootIdentity = try rootIdentity(at: selection.url)
        guard rootIdentity.fileType == 2 else { throw PlanningFilesystemError.invalid("selection.directory") }
        try PlanningSafeFileIO.validateSelectionRoot(selection.url)
    }

    private func takeActiveScopeLocked() -> [URL] {
        var scopes: [URL] = []
        let scope = activeScopeURL
        activeScopeURL = nil
        scopeActive = false
        if let scope {
            if activeLeaseCount == 0 {
                scopes.append(scope)
            } else {
                // Each successful startAccessing call owns one matching stop,
                // even when the URL is identical to a prior acquisition.
                deferredScopeURLs.append(scope)
            }
        }
        if activeLeaseCount == 0, !deferredScopeURLs.isEmpty {
            scopes.append(contentsOf: deferredScopeURLs)
            deferredScopeURLs.removeAll(keepingCapacity: false)
        }
        return scopes
    }

    private func releaseLease() {
        lock.lock()
        activeLeaseCount = max(0, activeLeaseCount - 1)
        let scopes: [URL]
        if activeLeaseCount == 0 {
            scopes = deferredScopeURLs
            deferredScopeURLs.removeAll(keepingCapacity: false)
        } else {
            scopes = []
        }
        lock.unlock()
        stopScopes(scopes)
    }

    private func stopScopes(_ scopes: [URL]) {
        for scope in scopes {
            scope.stopAccessingSecurityScopedResource()
        }
    }

    deinit {
        lock.lock()
        let scopes = takeActiveScopeLocked()
        lock.unlock()
        stopScopes(scopes)
    }

    private func makeGrant(
        selection: PlanningUserSelectedDirectory,
        vaultID: UUID,
        generation: UUID,
        rootIdentity: PlanningFileIdentity
    ) throws -> PlanningDeviceVaultGrant {
        let bookmark: Data
        if selection.isTestFactory {
            bookmark = Data()
        } else {
#if os(macOS)
            bookmark = try selection.url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
#else
            bookmark = try selection.url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
#endif
        }
        return try PlanningDeviceVaultGrant(
            deviceID: deviceID,
            vaultID: vaultID,
            bookmarkData: bookmark,
            selectionGeneration: generation,
            lastValidatedRootIdentity: rootIdentity
        )
    }

    private func snapshotLocked() -> PlanningVaultAccessSnapshot {
        PlanningVaultAccessSnapshot(
            state: state,
            vaultID: vaultIdentity?.vaultID,
            selectionGeneration: generation,
            rootIdentity: selectedDirectory.flatMap { try? rootIdentity(at: $0.url) },
            lifeOSIdentity: lifeOSIdentity,
            capabilities: capabilities,
            providerIdentifier: selectedDirectory?.providerIdentifier
        )
    }

    private func rootIdentity(at url: URL) throws -> PlanningFileIdentity {
        let identity = try PlanningSafeFileIO.stableIdentity(at: url)
        return try PlanningFileIdentity(
            device: identity.device,
            inode: identity.inode,
            fileType: 2
        )
    }

    private func readMarker(at url: URL) throws -> PlanningVaultIdentity {
        let lease = try PlanningSafeFileIO.openRoot(url)
        defer { lease.close() }
        return try PlanningVaultIdentity(vaultID: lease.vaultID)
    }

    private func mapAccessError(_ error: Error) -> PlanningFilesystemError {
        if let error = error as? PlanningFilesystemError { return error }
        if let error = error as? PlanningStorageError, error == .staleAccess {
            return .needsReselection
        }
        return .unavailable("grant")
    }
}

internal final class PlanningVaultGrantStore: @unchecked Sendable {
    private let store: PlanningBoundedPrivateStore

    init(applicationSupportDirectory: URL, deviceID: UUID) {
        self.store = PlanningBoundedPrivateStore(
            directoryURL: applicationSupportDirectory
                .appendingPathComponent("LifeOS", isDirectory: true)
                .appendingPathComponent("Planning", isDirectory: true),
            fileName: "vault-grant-\(deviceID.uuidString.lowercased()).json",
            maximumBytes: PlanningFilesystemLimits.maximumGrantBytes
        )
    }

    func load() throws -> PlanningDeviceVaultGrant? {
        guard let data = try store.load() else { return nil }
        do {
            let grant = try JSONDecoder().decode(PlanningDeviceVaultGrant.self, from: data)
            guard grant.bookmarkData.count <= PlanningStorageLimits.bookmarkBytes else {
                throw PlanningFilesystemError.corruptEvidence
            }
            return grant
        } catch let error as PlanningFilesystemError {
            throw error
        } catch {
            throw PlanningFilesystemError.corruptEvidence
        }
    }

    func save(_ grant: PlanningDeviceVaultGrant) throws {
        guard grant.bookmarkData.count <= PlanningStorageLimits.bookmarkBytes else {
            throw PlanningFilesystemError.backpressure("grantBookmark")
        }
        let data = try JSONEncoder().encode(grant)
        try store.save(data)
    }

    func remove() throws {
        try store.remove()
    }
}

private struct PlanningInitializationIntent: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let vaultID: UUID
    let selectionID: UUID
    let rootIdentity: PlanningFileIdentity
    let rootAuthority: PlanningStableDirectoryIdentity?
    let generation: UUID
    let temporaryName: String

    init(
        vaultID: UUID,
        selectionID: UUID,
        rootIdentity: PlanningFileIdentity,
        rootAuthority: PlanningStableDirectoryIdentity,
        generation: UUID,
        temporaryName: String
    ) throws {
        guard temporaryName.hasPrefix(".lifeos-tmp-"), temporaryName.utf8.count <= 255 else {
            throw PlanningFilesystemError.invalid("initializationIntent.temporaryName")
        }
        self.schemaVersion = 1
        self.vaultID = vaultID
        self.selectionID = selectionID
        self.rootIdentity = rootIdentity
        self.rootAuthority = rootAuthority
        self.generation = generation
        self.temporaryName = temporaryName
    }
}

private struct PlanningTestGrant: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let deviceID: UUID
    let vaultID: UUID
    let rootIdentity: PlanningFileIdentity
    let selectionGeneration: UUID

    init(
        deviceID: UUID,
        vaultID: UUID,
        rootIdentity: PlanningFileIdentity,
        selectionGeneration: UUID
    ) throws {
        self.schemaVersion = 1
        self.deviceID = deviceID
        self.vaultID = vaultID
        self.rootIdentity = rootIdentity
        self.selectionGeneration = selectionGeneration
    }
}

private struct PlanningAuthorityRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let root: PlanningStableDirectoryIdentity
    let lifeOS: PlanningStableDirectoryIdentity
    let providerIdentifier: String?

    init(
        root: PlanningStableDirectoryIdentity,
        lifeOS: PlanningStableDirectoryIdentity,
        providerIdentifier: String?
    ) {
        self.schemaVersion = 1
        self.root = root
        self.lifeOS = lifeOS
        self.providerIdentifier = providerIdentifier
    }
}

private final class PlanningAuthorityStore: @unchecked Sendable {
    private let store: PlanningBoundedPrivateStore

    init(applicationSupportDirectory: URL, deviceID: UUID) {
        self.store = PlanningBoundedPrivateStore(
            directoryURL: applicationSupportDirectory
                .appendingPathComponent("LifeOS", isDirectory: true)
                .appendingPathComponent("Planning", isDirectory: true),
            fileName: "authority-\(deviceID.uuidString.lowercased()).json",
            maximumBytes: PlanningFilesystemLimits.maximumAuthorityBytes
        )
    }

    func load() throws -> PlanningAuthorityRecord? {
        guard let data = try store.load() else { return nil }
        do {
            let record = try JSONDecoder().decode(PlanningAuthorityRecord.self, from: data)
            guard record.schemaVersion == 1 else { throw PlanningFilesystemError.corruptEvidence }
            return record
        } catch let error as PlanningFilesystemError {
            throw error
        } catch {
            throw PlanningFilesystemError.corruptEvidence
        }
    }

    func save(_ record: PlanningAuthorityRecord) throws {
        try store.save(JSONEncoder().encode(record))
    }

    func remove() throws { try store.remove() }
}

private final class PlanningInitializationIntentStore: @unchecked Sendable {
    private let store: PlanningBoundedPrivateStore

    init(applicationSupportDirectory: URL, deviceID: UUID) {
        self.store = PlanningBoundedPrivateStore(
            directoryURL: applicationSupportDirectory
                .appendingPathComponent("LifeOS", isDirectory: true)
                .appendingPathComponent("Planning", isDirectory: true),
            fileName: "initialization-\(deviceID.uuidString.lowercased()).json",
            maximumBytes: PlanningFilesystemLimits.maximumManifestBytes
        )
    }

    func load() throws -> PlanningInitializationIntent? {
        guard let data = try store.load() else { return nil }
        do { return try JSONDecoder().decode(PlanningInitializationIntent.self, from: data) }
        catch { throw PlanningFilesystemError.corruptEvidence }
    }

    func save(_ intent: PlanningInitializationIntent) throws {
        let data = try JSONEncoder().encode(intent)
        try store.save(data)
    }

    func remove() throws {
        try store.remove()
    }
}

private final class PlanningTestGrantStore: @unchecked Sendable {
    private let store: PlanningBoundedPrivateStore

    init(applicationSupportDirectory: URL, deviceID: UUID) {
        self.store = PlanningBoundedPrivateStore(
            directoryURL: applicationSupportDirectory
                .appendingPathComponent("LifeOS", isDirectory: true)
                .appendingPathComponent("Planning", isDirectory: true),
            fileName: "test-grant-\(deviceID.uuidString.lowercased()).json",
            maximumBytes: PlanningFilesystemLimits.maximumManifestBytes
        )
    }

    func load() throws -> PlanningTestGrant? {
        guard let data = try store.load() else { return nil }
        do {
            let grant = try JSONDecoder().decode(PlanningTestGrant.self, from: data)
            guard grant.schemaVersion == 1 else { throw PlanningFilesystemError.corruptEvidence }
            return grant
        } catch let error as PlanningFilesystemError {
            throw error
        } catch {
            throw PlanningFilesystemError.corruptEvidence
        }
    }

    func save(_ grant: PlanningTestGrant) throws {
        let data = try JSONEncoder().encode(grant)
        try store.save(data)
    }
}

private final class PlanningBoundedPrivateStore: @unchecked Sendable {
    private let directoryURL: URL
    private let fileName: String
    private let maximumBytes: Int
    private let lock = NSLock()

    init(directoryURL: URL, fileName: String, maximumBytes: Int) {
        self.directoryURL = directoryURL
        self.fileName = fileName
        self.maximumBytes = maximumBytes
    }

    func load() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let directory: PlanningPrivateDirectoryLease
        do {
            directory = try PlanningSafeFileIO.openPrivateDirectory(at: directoryURL, create: false)
        } catch let error as PlanningFilesystemError where error == .notFound {
            return nil
        }
        defer { directory.close() }
        guard let size = try PlanningSafeFileIO.privateFileSize(
            in: directory,
            name: fileName,
            maximum: maximumBytes
        ) else { return nil }
        guard size <= maximumBytes,
              let data = try PlanningSafeFileIO.readPrivateFile(
                  in: directory,
                  name: fileName,
                  maximum: maximumBytes
              ),
              data.count == size else {
            throw PlanningFilesystemError.corruptEvidence
        }
        return data
    }

    func save(_ data: Data) throws {
        guard data.count <= maximumBytes else {
            throw PlanningFilesystemError.backpressure("privateFile")
        }
        lock.lock()
        defer { lock.unlock() }
        let directory = try PlanningSafeFileIO.openPrivateDirectory(at: directoryURL, create: true)
        defer { directory.close() }
        try PlanningSafeFileIO.writePrivateFileAtomically(
            data,
            in: directory,
            name: fileName,
            replacing: true,
            maximum: maximumBytes
        )
    }

    func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        let directory: PlanningPrivateDirectoryLease
        do {
            directory = try PlanningSafeFileIO.openPrivateDirectory(at: directoryURL, create: false)
        } catch let error as PlanningFilesystemError where error == .notFound {
            return
        }
        defer { directory.close() }
        try PlanningSafeFileIO.removePrivateFile(in: directory, name: fileName)
    }
}
