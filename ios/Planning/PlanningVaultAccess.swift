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
    public private(set) var hasObsidianMarker: Bool
    public private(set) var hasExplicitRootConfirmation: Bool
    public private(set) var providerIdentifier: String?

    fileprivate let provenance: PlanningSelectionProvenance
    fileprivate var rootConfirmed: Bool

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
        self.url = standardized
        self.selectionID = UUID()
        self.hasObsidianMarker = false
        self.rootConfirmed = provenance == .testFactory || rootConfirmed == true
        self.hasExplicitRootConfirmation = self.rootConfirmed
        self.providerIdentifier = nil
        self.provenance = provenance
        if provenance == .testFactory {
            try refreshScopedFacts()
        }
    }

    internal static func picker(url: URL) throws -> PlanningUserSelectedDirectory {
        try PlanningUserSelectedDirectory(url: url, provenance: .picker)
    }

    internal static func testFactory(url: URL) throws -> PlanningUserSelectedDirectory {
        try PlanningUserSelectedDirectory(url: url, provenance: .testFactory)
    }

    internal var isTestFactory: Bool { provenance == .testFactory }

    /// Picker URLs are opaque until their temporary security scope is active.
    /// Test fixtures may refresh immediately because they are process-owned.
    fileprivate mutating func refreshScopedFacts() throws {
        guard !FileManager.default.fileExists(
            atPath: url.appendingPathComponent(".symlink").path
        ) else {
            throw PlanningFilesystemError.invalid("selection.symlink")
        }
#if canImport(Darwin)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw PlanningFilesystemError.notFound }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw PlanningFilesystemError.invalid("selection.directory")
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw PlanningFilesystemError.needsReselection
        }
#else
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlanningFilesystemError.notFound
        }
#endif
        hasObsidianMarker = FileManager.default.fileExists(
            atPath: url.appendingPathComponent(".obsidian", isDirectory: true).path
        )
        rootConfirmed = provenance == .testFactory || rootConfirmed || hasObsidianMarker
        hasExplicitRootConfirmation = rootConfirmed
        providerIdentifier = Self.providerIdentifier(for: url)
    }

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

internal final class PlanningSecurityScopeStrategy: @unchecked Sendable {
    let start: (URL) -> Bool
    let stop: (URL) -> Void

    init(
        start: @escaping (URL) -> Bool,
        stop: @escaping (URL) -> Void
    ) {
        self.start = start
        self.stop = stop
    }

    static let system = PlanningSecurityScopeStrategy(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
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
    private let selectionStore: PlanningVaultSelectionStore
    private let scopeStrategy: PlanningSecurityScopeStrategy
    private let emulateTestFactoryScopes: Bool

    public convenience init(
        applicationSupportDirectory: URL,
        deviceID: UUID = UUID()
    ) {
        self.init(
            applicationSupportDirectory: applicationSupportDirectory,
            deviceID: deviceID,
            scopeStrategy: .system,
            emulateTestFactoryScopes: false,
            selectionCommitHook: nil,
            selectionAfterReplacementHook: nil,
            selectionDecisionCommitHook: nil,
            selectionPendingCleanupHook: nil
        )
    }

    private init(
        applicationSupportDirectory: URL,
        deviceID: UUID,
        scopeStrategy: PlanningSecurityScopeStrategy,
        emulateTestFactoryScopes: Bool,
        selectionCommitHook: (() throws -> Void)?,
        selectionAfterReplacementHook: (() throws -> Void)?,
        selectionDecisionCommitHook: (() throws -> Void)?,
        selectionPendingCleanupHook: (() throws -> Void)?,
        selectionRemovalBarrierHook: ((String) throws -> Void)? = nil
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
        self.selectionStore = PlanningVaultSelectionStore(
            applicationSupportDirectory: applicationSupportDirectory,
            deviceID: deviceID,
            beforeReplacement: selectionCommitHook,
            afterReplacement: selectionAfterReplacementHook,
            afterDecision: selectionDecisionCommitHook,
            afterPendingRemoval: selectionPendingCleanupHook,
            beforeRemovalFlush: selectionRemovalBarrierHook
        )
        self.scopeStrategy = scopeStrategy
        self.emulateTestFactoryScopes = emulateTestFactoryScopes
    }

    internal static func makeTesting(
        rootURL: URL,
        applicationSupportDirectory: URL,
        deviceID: UUID = UUID(),
        scopeStrategy: PlanningSecurityScopeStrategy? = nil,
        selectionCommitHook: (() throws -> Void)? = nil,
        selectionAfterReplacementHook: (() throws -> Void)? = nil,
        selectionDecisionCommitHook: (() throws -> Void)? = nil,
        selectionPendingCleanupHook: (() throws -> Void)? = nil,
        selectionRemovalBarrierHook: ((String) throws -> Void)? = nil
    ) throws -> PlanningVaultAccess {
        let access = PlanningVaultAccess(
            applicationSupportDirectory: applicationSupportDirectory,
            deviceID: deviceID,
            scopeStrategy: scopeStrategy ?? .system,
            emulateTestFactoryScopes: scopeStrategy != nil,
            selectionCommitHook: selectionCommitHook,
            selectionAfterReplacementHook: selectionAfterReplacementHook,
            selectionDecisionCommitHook: selectionDecisionCommitHook,
            selectionPendingCleanupHook: selectionPendingCleanupHook,
            selectionRemovalBarrierHook: selectionRemovalBarrierHook
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: rootURL)
        access.selectedDirectory = selection
        access.testFactory = true
        if let stored = try access.selectionStore.load(),
           stored.grant.deviceID == deviceID,
           stored.grant.bookmarkData.isEmpty,
           let rootIdentity = stored.grant.lastValidatedRootIdentity {
            access.testGrant = try PlanningTestGrant(
                deviceID: deviceID,
                vaultID: stored.grant.vaultID,
                rootIdentity: rootIdentity,
                selectionGeneration: stored.grant.selectionGeneration
            )
        } else {
            access.testGrant = try access.testGrantStore.load()
        }
        return access
    }

    public func select(
        selection: PlanningUserSelectedDirectory,
        intent: PlanningVaultSelectionIntent
    ) throws -> PlanningVaultAccessSnapshot {
        try select(selection: selection, intent: intent, prepareResources: { _ in })
    }

    /// Runs synchronously under the access lock, before persistence and scope
    /// handoff. The callback must not reenter access or suspend actor execution.
    internal func select(
        selection: PlanningUserSelectedDirectory,
        intent: PlanningVaultSelectionIntent,
        prepareResources: (UUID) throws -> Void
    ) throws -> PlanningVaultAccessSnapshot {
        lock.lock()
        defer { lock.unlock() }

        var selection = selection
        let isTestSelection = selection.isTestFactory
        let shouldStartScope = !isTestSelection || emulateTestFactoryScopes
        var startedScope = false
        var committedScope = false
        defer {
            if startedScope && !committedScope {
                scopeStrategy.stop(selection.url)
            }
        }
        do {
            if shouldStartScope {
                if !isTestSelection {
                    guard selection.provenance == .picker else {
                        throw PlanningFilesystemError.unsupportedFilesystem
                    }
                }
                startedScope = scopeStrategy.start(selection.url)
                guard startedScope else { throw PlanningFilesystemError.permissionDenied }
                try selection.refreshScopedFacts()
                if !isTestSelection {
                    guard selection.rootConfirmed,
                          selection.hasObsidianMarker,
                          selection.providerIdentifier == "icloud"
                            || selection.providerIdentifier == "icloud.shared" else {
                        throw PlanningFilesystemError.unsupportedFilesystem
                    }
                }
            }
            // All filesystem-backed validation below must run while the picker
            // grant is active. URL/provenance metadata is checked first so an
            // unsupported selection never acquires a scope.
            try validateSelection(selection)

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
            let authority = PlanningAuthorityRecord(
                root: selectedRootAuthority,
                lifeOS: selectedLifeOSAuthority,
                providerIdentifier: selection.providerIdentifier
            )
            let savedTestGrant = selection.isTestFactory
                ? try PlanningTestGrant(
                    deviceID: deviceID,
                    vaultID: vaultID,
                    rootIdentity: root,
                    selectionGeneration: nextGeneration
                )
                : nil
            let selectedVaultIdentity = try PlanningVaultIdentity(vaultID: vaultID)
            try prepareResources(selectedVaultIdentity.vaultID)
            try selectionStore.save(
                PlanningVaultSelectionRecord(
                    grant: grant,
                    authority: authority
                )
            )

            // The old scope remains committed until every throwing check and
            // durable write above has succeeded. Materialize the final
            // throwing identity before beginning the handoff.
            let oldScopes = takeActiveScopeLocked()
            selectedDirectory = selection
            vaultIdentity = selectedVaultIdentity
            generation = nextGeneration
            rootURL = selection.url
            rootAuthority = selectedRootAuthority
            lifeOSAuthority = selectedLifeOSAuthority
            lifeOSIdentity = selectedLifeOSIdentity
            activeScopeURL = startedScope ? selection.url : nil
            scopeActive = startedScope
            state = .ready
            capabilities = detected
            testFactory = selection.isTestFactory
            testGrant = savedTestGrant
            committedScope = startedScope
            stopScopes(oldScopes)
            return snapshotLocked()
        } catch {
            if error is PlanningSelectionCommitError {
                stopScopes(takeActiveScopeLocked())
                rootURL = nil
                vaultIdentity = nil
                rootAuthority = nil
                lifeOSAuthority = nil
                lifeOSIdentity = nil
                generation = UUID()
                state = .needsReselection
                capabilities = .unavailableSignedApp
                throw PlanningFilesystemError.unavailable("selectionCommitUncertain")
            }
            if state == .ready && !hasLiveCommittedSelectionLocked() {
                state = .needsReselection
                capabilities = PlanningFilesystemCapabilities.unavailableSignedApp
            }
            throw error
        }
    }

    /// Validates and inspects an already-enabled vault without changing the
    /// selected access, grant, marker, journal, or filesystem contents. The
    /// picker URL is scoped only for the bounded marker read and that scope is
    /// balanced on every exit.
    public func inspectExistingSelection(
        _ selection: PlanningUserSelectedDirectory
    ) throws -> PlanningVaultIdentity {
        lock.lock()
        defer { lock.unlock() }

        var selection = selection
        let isTestSelection = selection.isTestFactory
        var startedScope = false
        defer {
            if startedScope {
                scopeStrategy.stop(selection.url)
            }
        }
        let shouldStartScope = !isTestSelection || emulateTestFactoryScopes
        if shouldStartScope {
            if !isTestSelection {
                guard selection.provenance == .picker else {
                    throw PlanningFilesystemError.unsupportedFilesystem
                }
            }
            startedScope = scopeStrategy.start(selection.url)
            guard startedScope else { throw PlanningFilesystemError.permissionDenied }
            try selection.refreshScopedFacts()
            if !isTestSelection {
                guard selection.rootConfirmed,
                      selection.hasObsidianMarker,
                      selection.providerIdentifier == "icloud"
                        || selection.providerIdentifier == "icloud.shared" else {
                    throw PlanningFilesystemError.unsupportedFilesystem
                }
            }
        }

        // Root identity, symlink, marker and bounded-root validation all run
        // only after the temporary picker scope is active.
        try validateSelection(selection)
        let lease = try PlanningSafeFileIO.openRoot(selection.url)
        defer { lease.close() }
        return try PlanningVaultIdentity(vaultID: lease.vaultID)
    }

    public func restore() throws -> PlanningVaultAccessSnapshot {
        try restore(prepareResources: { _ in })
    }

    /// Runs synchronously under the access lock, before publishing readiness.
    /// The callback must not reenter access or suspend actor execution.
    internal func restore(
        prepareResources: (UUID) throws -> Void
    ) throws -> PlanningVaultAccessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let wasTestFactory = testFactory
        let oldScopes = takeActiveScopeLocked()
        invalidateStateLocked(preserveTestFactorySelection: wasTestFactory)
        stopScopes(oldScopes)

        var resolvedURL: URL?
        var scopeStarted = false
        do {
            let persisted: (
                grant: PlanningDeviceVaultGrant,
                authority: PlanningAuthorityRecord,
                isComposite: Bool
            )
            if let composite = try selectionStore.load() {
                persisted = (composite.grant, composite.authority, true)
            } else {
                let legacyGrant: PlanningDeviceVaultGrant?
                if let grant = try grantStore.load() {
                    legacyGrant = grant
                } else if testFactory, let testGrant = try testGrantStore.load() {
                    legacyGrant = try PlanningDeviceVaultGrant(
                        deviceID: testGrant.deviceID,
                        vaultID: testGrant.vaultID,
                        bookmarkData: Data(),
                        selectionGeneration: testGrant.selectionGeneration,
                        lastValidatedRootIdentity: testGrant.rootIdentity
                    )
                } else {
                    state = .unselected
                    capabilities = PlanningFilesystemCapabilities.unavailableSignedApp
                    return snapshotLocked()
                }
                guard let legacyGrant,
                      let legacyAuthority = try authorityStore.load() else {
                    throw PlanningFilesystemError.needsReselection
                }
                persisted = (legacyGrant, legacyAuthority, false)
            }

            let stored = persisted.grant
            let storedAuthority = persisted.authority
            guard stored.deviceID == deviceID else {
                state = .needsReselection
                capabilities = PlanningFilesystemCapabilities.unavailableSignedApp
                return snapshotLocked()
            }

            var stale = false
            let url: URL
            var restoredSelection: PlanningUserSelectedDirectory
            let usesTestFactoryURL = testFactory && stored.bookmarkData.isEmpty
            if usesTestFactoryURL {
                guard let selectedDirectory else {
                    throw PlanningFilesystemError.needsReselection
                }
                url = selectedDirectory.url
                if emulateTestFactoryScopes {
                    scopeStarted = scopeStrategy.start(url)
                    guard scopeStarted else { throw PlanningFilesystemError.permissionDenied }
                    resolvedURL = url
                }
                restoredSelection = selectedDirectory
                try restoredSelection.refreshScopedFacts()
            } else {
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
                scopeStarted = scopeStrategy.start(url)
                guard scopeStarted else { throw PlanningFilesystemError.permissionDenied }
                restoredSelection = try PlanningUserSelectedDirectory.picker(url: url)
                try restoredSelection.refreshScopedFacts()
            }
            guard restoredSelection.rootConfirmed,
                  usesTestFactoryURL || restoredSelection.hasObsidianMarker,
                  usesTestFactoryURL
                    || restoredSelection.providerIdentifier == "icloud"
                    || restoredSelection.providerIdentifier == "icloud.shared" else {
                throw PlanningFilesystemError.unsupportedFilesystem
            }
            try validateSelection(restoredSelection)
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
            let restoredIdentity = try PlanningVaultIdentity(vaultID: stored.vaultID)
            let restoredTestGrant = usesTestFactoryURL
                ? try PlanningTestGrant(
                    deviceID: stored.deviceID,
                    vaultID: stored.vaultID,
                    rootIdentity: root,
                    selectionGeneration: stored.selectionGeneration
                )
                : nil
            try prepareResources(stored.vaultID)

            var restoredGrant = stored
            if stale {
                restoredGrant = try makeGrant(
                    selection: restoredSelection,
                    vaultID: stored.vaultID,
                    generation: stored.selectionGeneration,
                    rootIdentity: root
                )
            }
            if persisted.isComposite {
                if stale {
                    try selectionStore.save(
                        PlanningVaultSelectionRecord(
                            grant: restoredGrant,
                            authority: storedAuthority
                        )
                    )
                }
            } else {
                do {
                    try selectionStore.save(
                        PlanningVaultSelectionRecord(
                            grant: restoredGrant,
                            authority: storedAuthority
                        )
                    )
                } catch {
                    // Legacy records remain authoritative when a best-effort
                    // migration cannot be completed. The selection store has
                    // retained its transaction evidence for a later retry.
                }
            }
            activeScopeURL = scopeStarted ? url : nil
            scopeActive = scopeStarted
            selectedDirectory = restoredSelection
            vaultIdentity = restoredIdentity
            generation = stored.selectionGeneration
            rootURL = url
            rootAuthority = selectedRootAuthority
            lifeOSAuthority = selectedLifeOSAuthority
            lifeOSIdentity = selectedLifeOSIdentity
            testGrant = restoredTestGrant
            state = .ready
            capabilities = PlanningFilesystemCapabilities(
                signedAppAccessAvailable: usesTestFactoryURL,
                canRead: true,
                canPublish: usesTestFactoryURL
                    && safeCapabilities.exclusiveRename
                    && safeCapabilities.swapRename
                    && safeCapabilities.descriptorTraversal
                    && safeCapabilities.directoryFlush,
                supportsDescriptorTraversal: safeCapabilities.descriptorTraversal,
                supportsExclusiveRename: safeCapabilities.exclusiveRename,
                supportsSwapRename: safeCapabilities.swapRename,
                supportsDirectoryFlush: safeCapabilities.directoryFlush,
                providerIdentifier: restoredSelection.providerIdentifier,
                reasonCode: usesTestFactoryURL ? nil : "userSelectedReadWriteUnavailable"
            )
            return snapshotLocked()
        } catch {
            if scopeStarted {
                if let resolvedURL {
                    scopeStrategy.stop(resolvedURL)
                }
            }
            invalidateStateLocked(preserveTestFactorySelection: wasTestFactory)
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

    /// Returns false when persisted access could not be fully removed. In that
    /// case access fails closed and an explicit restore may recover the grant.
    @discardableResult
    public func revoke() -> Bool {
        lock.lock()
        // Serialize persistence with select/restore: no later selection may be
        // committed until every removal belonging to this revocation is done.
        let succeeded: Bool
        do {
            try selectionStore.remove()
            try grantStore.remove()
            try authorityStore.remove()
            try testGrantStore.remove()
            succeeded = true
        } catch {
            succeeded = false
        }
        let scopes = takeActiveScopeLocked()
        invalidateStateLocked(preserveTestFactorySelection: !succeeded && testFactory)
        if succeeded {
            testGrant = nil
            testFactory = false
            state = .unselected
        }
        lock.unlock()
        stopScopes(scopes)
        return succeeded
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

    private func invalidateStateLocked(preserveTestFactorySelection: Bool) {
        if !preserveTestFactorySelection { selectedDirectory = nil }
        rootURL = nil
        vaultIdentity = nil
        rootAuthority = nil
        lifeOSAuthority = nil
        lifeOSIdentity = nil
        activeScopeURL = nil
        scopeActive = false
        generation = UUID()
        state = .needsReselection
        capabilities = .unavailableSignedApp
    }

    private func hasLiveCommittedSelectionLocked() -> Bool {
        guard state == .ready,
              selectedDirectory != nil,
              vaultIdentity != nil,
              generation != nil,
              rootURL != nil,
              capabilities.canRead else {
            return false
        }
        return testFactory || (activeScopeURL != nil && scopeActive)
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
            scopeStrategy.stop(scope)
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

private struct PlanningVaultSelectionRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let grant: PlanningDeviceVaultGrant
    let authority: PlanningAuthorityRecord

    init(
        grant: PlanningDeviceVaultGrant,
        authority: PlanningAuthorityRecord
    ) {
        self.schemaVersion = 1
        self.grant = grant
        self.authority = authority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else {
            throw PlanningFilesystemError.corruptEvidence
        }
        let authority = try container.decode(PlanningAuthorityRecord.self, forKey: .authority)
        guard authority.schemaVersion == 1 else {
            throw PlanningFilesystemError.corruptEvidence
        }
        self.schemaVersion = schemaVersion
        self.grant = try container.decode(PlanningDeviceVaultGrant.self, forKey: .grant)
        self.authority = authority
    }
}

private enum PlanningVaultSelectionStorageLimits {
    static let compositeBytes = PlanningFilesystemLimits.maximumGrantBytes
        + PlanningFilesystemLimits.maximumAuthorityBytes + 4 * 1024
    // JSON encodes embedded Data as base64: allow both bounded composites.
    static let pendingBytes = compositeBytes * 3 + 4 * 1024
    static let decisionBytes = compositeBytes * 2 + 4 * 1024
}

private struct PlanningVaultSelectionPendingRecord: Codable {
    let schemaVersion: Int
    let transactionID: UUID?
    let previousComposite: Data?
    let candidateComposite: Data?
}

private struct PlanningVaultSelectionDecisionRecord: Codable {
    let schemaVersion: Int
    let transactionID: UUID
    let candidateComposite: Data
}

private enum PlanningSelectionCommitError: Error {
    // A decision write may have replaced the file before its flush failed.
    // Neither the old nor candidate selection may be published until recovery.
    case uncertain
}

private final class PlanningVaultSelectionStore: @unchecked Sendable {
    private let store: PlanningBoundedPrivateStore
    private let pendingStore: PlanningBoundedPrivateStore
    private let decisionStore: PlanningBoundedPrivateStore
    private let deviceID: UUID
    private let beforeReplacement: (() throws -> Void)?
    private let afterReplacement: (() throws -> Void)?
    private let afterDecision: (() throws -> Void)?
    private let afterPendingRemoval: (() throws -> Void)?

    init(
        applicationSupportDirectory: URL,
        deviceID: UUID,
        beforeReplacement: (() throws -> Void)? = nil,
        afterReplacement: (() throws -> Void)? = nil,
        afterDecision: (() throws -> Void)? = nil,
        afterPendingRemoval: (() throws -> Void)? = nil,
        beforeRemovalFlush: ((String) throws -> Void)? = nil
    ) {
        let directory = applicationSupportDirectory
            .appendingPathComponent("LifeOS/Planning", isDirectory: true)
        let suffix = deviceID.uuidString.lowercased() + ".json"
        self.store = PlanningBoundedPrivateStore(directoryURL: directory,
            fileName: "vault-selection-" + suffix,
            maximumBytes: PlanningVaultSelectionStorageLimits.compositeBytes,
            beforeRemovalFlush: beforeRemovalFlush)
        self.pendingStore = PlanningBoundedPrivateStore(directoryURL: directory,
            fileName: "vault-selection-pending-" + suffix,
            maximumBytes: PlanningVaultSelectionStorageLimits.pendingBytes,
            beforeRemovalFlush: beforeRemovalFlush)
        self.decisionStore = PlanningBoundedPrivateStore(directoryURL: directory,
            fileName: "vault-selection-decision-" + suffix,
            maximumBytes: PlanningVaultSelectionStorageLimits.decisionBytes,
            beforeRemovalFlush: beforeRemovalFlush)
        self.deviceID = deviceID
        self.beforeReplacement = beforeReplacement
        self.afterReplacement = afterReplacement
        self.afterDecision = afterDecision
        self.afterPendingRemoval = afterPendingRemoval
    }

    private func composite(_ data: Data) throws -> PlanningVaultSelectionRecord {
        guard !data.isEmpty,
              data.count <= PlanningVaultSelectionStorageLimits.compositeBytes else {
            throw PlanningFilesystemError.corruptEvidence
        }
        do {
            let record = try JSONDecoder().decode(PlanningVaultSelectionRecord.self, from: data)
            guard record.grant.deviceID == deviceID else {
                throw PlanningFilesystemError.corruptEvidence
            }
            return record
        } catch { throw PlanningFilesystemError.corruptEvidence }
    }

    func load() throws -> PlanningVaultSelectionRecord? {
        try recoverPending()
        guard let data = try store.load() else { return nil }
        return try composite(data)
    }

    func save(_ record: PlanningVaultSelectionRecord) throws {
        try recoverPending()
        let data = try JSONEncoder().encode(record)
        _ = try composite(data)
        let previous = try store.load()
        if let previous { _ = try composite(previous) }
        try beforeReplacement?()
        let transactionID = UUID()
        let pending = PlanningVaultSelectionPendingRecord(schemaVersion: 2,
            transactionID: transactionID, previousComposite: previous, candidateComposite: data)
        try pendingStore.save(JSONEncoder().encode(pending))
        try store.save(data)
        try afterReplacement?()
        let decision = PlanningVaultSelectionDecisionRecord(schemaVersion: 1,
            transactionID: transactionID, candidateComposite: data)
        do {
            try decisionStore.save(JSONEncoder().encode(decision))
            try afterDecision?()
        } catch { throw PlanningSelectionCommitError.uncertain }
        // The durable decision is authoritative. Cleanup can never reject an
        // acknowledged commit, and its evidence remains until pending is gone.
        do { try cleanupCommitted() } catch { /* Retry normalization on next operation. */ }
    }

    func remove() throws {
        // Normalize and remove decisions before deleting selection, so a stale
        // decision can never resurrect a successfully removed selection.
        try recoverPending()
        try store.remove()
    }

    private func cleanupCommitted() throws {
        try pendingStore.remove()
        // This hook models interruption AFTER removal, not an unflushed unlink.
        try afterPendingRemoval?()
        try decisionStore.remove()
    }

    private func recoverPending() throws {
        let pendingData = try pendingStore.load()
        let decisionData = try decisionStore.load()
        let pending: PlanningVaultSelectionPendingRecord?
        let decision: PlanningVaultSelectionDecisionRecord?
        do {
            pending = try pendingData.map {
                try JSONDecoder().decode(PlanningVaultSelectionPendingRecord.self, from: $0)
            }
            decision = try decisionData.map {
                try JSONDecoder().decode(PlanningVaultSelectionDecisionRecord.self, from: $0)
            }
        } catch { throw PlanningFilesystemError.corruptEvidence }
        if let decision {
            guard decision.schemaVersion == 1 else { throw PlanningFilesystemError.corruptEvidence }
            _ = try composite(decision.candidateComposite)
        }
        guard let pending else {
            if let decision {
                // Pending cleanup completed, but decision cleanup did not.
                // Never use an orphan decision to overwrite unrelated data.
                guard try store.load() == decision.candidateComposite else {
                    throw PlanningFilesystemError.corruptEvidence
                }
                try decisionStore.remove()
            }
            return
        }
        if let previous = pending.previousComposite { _ = try composite(previous) }
        switch pending.schemaVersion {
        case 1:
            guard pending.transactionID == nil, pending.candidateComposite == nil,
                  decision == nil else { throw PlanningFilesystemError.corruptEvidence }
        case 2:
            guard pending.transactionID != nil, let candidate = pending.candidateComposite else {
                throw PlanningFilesystemError.corruptEvidence
            }
            _ = try composite(candidate)
        default: throw PlanningFilesystemError.corruptEvidence
        }
        let resolved: Data?
        if let decision {
            guard decision.transactionID == pending.transactionID,
                  decision.candidateComposite == pending.candidateComposite else {
                throw PlanningFilesystemError.corruptEvidence
            }
            resolved = decision.candidateComposite
        } else {
            resolved = pending.previousComposite
        }
        if let resolved { try store.save(resolved) } else { try store.remove() }
        guard try store.load() == resolved else { throw PlanningFilesystemError.corruptEvidence }
        // The resolved composite is durable before cleanup. If unlink/flush
        // fails, either remaining evidence or the resolved composite is safe.
        try pendingStore.remove()
        try afterPendingRemoval?()
        try decisionStore.remove()
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

    func remove() throws {
        try store.remove()
    }
}

private final class PlanningBoundedPrivateStore: @unchecked Sendable {
    private let directoryURL: URL
    private let fileName: String
    private let maximumBytes: Int
    private let lock = NSLock()

    private let beforeRemovalFlush: ((String) throws -> Void)?

    init(directoryURL: URL, fileName: String, maximumBytes: Int,
         beforeRemovalFlush: ((String) throws -> Void)? = nil) {
        self.beforeRemovalFlush = beforeRemovalFlush
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
        try PlanningSafeFileIO.removePrivateFile(in: directory, name: fileName,
            beforeDirectoryFlush: { try self.beforeRemovalFlush?(self.fileName) })
    }
}
