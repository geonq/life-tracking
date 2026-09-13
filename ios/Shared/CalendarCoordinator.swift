import Foundation
import Combine
#if canImport(WidgetKit)
import WidgetKit
#endif

public enum CalendarLocalSaveResult: Equatable, Sendable {
    case success
    case failure(String)
}

public typealias CalendarUpdateCompletion = (CalendarLocalSaveResult) -> Void
// The gesture layer may retain completion while the coordinator performs its
// asynchronous local save, so the handler contract must permit that escape.
public typealias CalendarUpdateHandler = (CalendarItem, Date, Date, @escaping CalendarUpdateCompletion) -> Void

/// The small defaults boundary used by calendar persistence metadata. Production
/// uses `UserDefaults.standard`; fixture hosts receive an isolated instance.
public protocol CalendarDefaultsStore: AnyObject {
    func string(forKey defaultName: String) -> String?
    func integer(forKey defaultName: String) -> Int
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: CalendarDefaultsStore {}

private final class CalendarFixtureDefaults: CalendarDefaultsStore {
    private var values: [String: Any] = [:]

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func integer(forKey defaultName: String) -> Int {
        if let value = values[defaultName] as? Int { return value }
        if let value = values[defaultName] as? NSNumber { return value.intValue }
        return 0
    }

    func bool(forKey defaultName: String) -> Bool {
        if let value = values[defaultName] as? Bool { return value }
        if let value = values[defaultName] as? NSNumber { return value.boolValue }
        return false
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }
}

private enum CalendarRemoteMutationError: Error {
    case attemptsExhausted
    case adoptionFailed
}

/// The coordinator owns Calendar behavior, but the concrete peer service is
/// deliberately hidden behind this small transport boundary. Fixture hosts
/// receive a no-op implementation and therefore cannot create a
/// MultipeerConnectivity advertiser/browser just by constructing a calendar
/// coordinator.
protocol CalendarPeerTransport: AnyObject {
    func setStatusHandler(_ handler: @escaping (CalendarPeerConnectionStatus) -> Void)
    func setSnapshotHandler(_ handler: @escaping (CalendarPeerSyncEnvelope, String) -> Void)
    func setPairingHandler(_ handler: @escaping (CalendarPairingState) -> Void)
    func createPairing() throws
    func importPairing(_ token: String) throws
    func confirmPairing() throws
    func cancelPairing()
    func retryPairingConnection()
    func start()
    func stop()
    func send(snapshot: CalendarSnapshot, senderID: String, revision: Int) throws
}

@available(iOS 17.0, macOS 14.0, *)
private final class LiveCalendarPeerTransport: CalendarPeerTransport {
    private let service: CalendarPeerSync

    init(displayName: String) {
        service = CalendarPeerSync(displayName: displayName)
    }

    func setStatusHandler(_ handler: @escaping (CalendarPeerConnectionStatus) -> Void) {
        service.onStatusChanged = handler
    }

    func setSnapshotHandler(_ handler: @escaping (CalendarPeerSyncEnvelope, String) -> Void) {
        service.onAuthenticatedSnapshotReceived = { envelope, senderID in
            handler(envelope, senderID)
        }
    }

    func setPairingHandler(_ handler: @escaping (CalendarPairingState) -> Void) { service.onPairingChanged = handler }
    func createPairing() throws { try service.createPairing() }
    func importPairing(_ token: String) throws { try service.importPairing(token) }
    func confirmPairing() throws { try service.confirmPairing() }
    func cancelPairing() { service.cancelPairing() }
    func retryPairingConnection() { service.retryPairingConnection() }
    func start() { service.start() }
    func stop() { service.stop() }

    func send(snapshot: CalendarSnapshot, senderID: String, revision: Int) throws {
        try service.send(snapshot: snapshot, senderID: senderID, revision: revision)
    }
}

/// Explicit fixture transport. It intentionally does not instantiate the
/// real peer service and never invokes a discovery or connection API.
private final class FixtureCalendarPeerTransport: CalendarPeerTransport {
    func setStatusHandler(_ handler: @escaping (CalendarPeerConnectionStatus) -> Void) {}
    func setSnapshotHandler(_ handler: @escaping (CalendarPeerSyncEnvelope, String) -> Void) {}
    func setPairingHandler(_ handler: @escaping (CalendarPairingState) -> Void) {
        handler(CalendarPairingState(message: "Nearby pairing is unavailable in fixtures and tests.", available: false))
    }
    func createPairing() throws { throw CalendarPeerSyncError.invalidPairing }
    func importPairing(_ token: String) throws { throw CalendarPeerSyncError.invalidPairing }
    func confirmPairing() throws { throw CalendarPeerSyncError.invalidPairing }
    func cancelPairing() {}
    func retryPairingConnection() {}
    func start() {}
    func stop() {}
    func send(snapshot: CalendarSnapshot, senderID: String, revision: Int) throws {}
}

enum CalendarPeerMutationFenceError: Error, Equatable, Sendable {
    case revoked
}

/// Crosses the MainActor/CalendarStore actor boundary for one peer commit.
/// Revocation and the store's final read/merge/write section use the same
/// lock, so a retired peer token cannot pass validation and then write later.
final class CalendarPeerMutationFence: @unchecked Sendable {
    struct Token: Sendable {
        fileprivate let generation: UInt64
        fileprivate let transportGeneration: UInt64
    }

    struct TransportToken: Sendable {
        fileprivate let generation: UInt64
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var transportGeneration: UInt64 = 0
    private var active = false

    /// Installs one coordinator-owned transport generation. Replacing a
    /// transport immediately retires all tokens from the previous one, while
    /// leaving activation to the authenticated-session callback.
    func installTransport() -> TransportToken {
        lock.lock(); defer { lock.unlock() }
        transportGeneration &+= 1
        generation &+= 1
        active = false
        return TransportToken(generation: transportGeneration)
    }

    func activate() {
        lock.lock(); defer { lock.unlock() }
        active = true
    }

    /// Re-opens the fence only for the currently installed transport. A late
    /// callback from a stopped or replaced transport therefore cannot
    /// authorize a new peer mutation.
    func activate(_ transport: TransportToken) {
        lock.lock(); defer { lock.unlock() }
        guard transport.generation == transportGeneration else { return }
        active = true
    }

    func invalidate(_ transport: TransportToken? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let transport {
            guard transport.generation == transportGeneration else { return }
        } else {
            // Coordinator-owned stop, cancel, or replacement retires the
            // transport itself. A delayed `.connected` callback from that
            // instance must not be able to activate it again.
            transportGeneration &+= 1
        }
        active = false
        generation &+= 1
    }

    func capture(_ transport: TransportToken? = nil) -> Token? {
        lock.lock(); defer { lock.unlock() }
        if let transport, transport.generation != transportGeneration { return nil }
        guard active else { return nil }
        return Token(generation: generation, transportGeneration: transportGeneration)
    }

    func isCurrent(_ token: Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && token.generation == generation && token.transportGeneration == transportGeneration
    }

    func isInstalled(_ transport: TransportToken) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return transport.generation == transportGeneration
    }

    /// Holds the fence through the caller's synchronous durable section.
    /// `CalendarStore.merge` uses this around its complete read/merge/write
    /// operation; revocation therefore waits for an already-authorized commit
    /// and invalidates all later commits.
    func withAuthorizedCommit<T>(_ token: Token, _ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard active && token.generation == generation && token.transportGeneration == transportGeneration else {
            throw CalendarPeerMutationFenceError.revoked
        }
        return try operation()
    }
}

private enum CalendarWidgetTimelineReloader {
    static let kinds = ["LifeOSCalendarWidget", "LifeOSNextEventWidget", "TasksWidget"]

    static func reload(_ kinds: [String]) {
#if canImport(WidgetKit)
        // Reload only projections of the shared CalendarSnapshot. This is a
        // one-way app-to-widget notification; widget timeline reads never call back into this path.
        for kind in kinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
#endif
    }
}

@available(iOS 17.0, macOS 14.0, *)
@MainActor
public final class CalendarCoordinator: ObservableObject {
    private typealias CalendarRemoteFetch = @Sendable () async throws -> CalendarRemoteResource
    private typealias CalendarRemotePush = @Sendable (Data, String, String) async throws -> CalendarRemoteResource
    private static let maximumRemoteMutationAttempts = 3

    /// Returns a fresh metadata store for a visual-fixture coordinator. The
    /// instance has no persistent or standard-defaults domain.
    public static func makeVisualFixtureDefaults() -> any CalendarDefaultsStore {
        CalendarFixtureDefaults()
    }

    @Published public private(set) var snapshot = CalendarSnapshot()
    @Published public private(set) var storageDescription = ""
    @Published public private(set) var syncStatus: CalendarPeerConnectionStatus = .stopped
    @Published public private(set) var pairingState = CalendarPairingState()
    @Published public private(set) var pairingError: String?
    @Published public private(set) var syncWarning: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isLoaded = false
    @Published public private(set) var canUndo = false
    @Published public private(set) var sharedStorageAvailable = false

    public let store: CalendarStore
    public let senderID: String
    private var revision: Int
    private var peerSync: CalendarPeerTransport
    private var livePeerSync: LiveCalendarPeerTransport?
    private let allowsLivePeerTransport: Bool
    private let tailscaleClient: TailscaleSyncClient?
    private let remoteFetch: CalendarRemoteFetch?
    private let remotePush: CalendarRemotePush?
    private let remoteSyncInjected: Bool
    private let widgetTimelineReload: (([String]) -> Void)?
    private var lastWidgetReloadData: Data?
    private let peerSend: ((CalendarSnapshot, String, Int) throws -> Void)?
    /// Fixture launches intentionally start from their injected snapshot and
    /// must not let a reused app container replace it on the first mutation.
    private let usesVisualFixtures: Bool
    private let defaults: any CalendarDefaultsStore
    private var nearbyDiscoveryObserver: NSObjectProtocol?
    private struct FailedMutation: Sendable {
        let id: UUID
        let mutation: CalendarMutation
    }

    private var pendingFailedMutation: FailedMutation?
    private var pendingFailedUndo = false
    private var peerSyncWarning: String?
    private var remoteSyncWarning: String?
    private var remoteMutationWarning: String?
    private var remoteSyncInFlight = false
    private struct UndoToken: Sendable {
        let id: UUID
        let snapshot: CalendarSnapshot
    }

    /// `CalendarStore.mutate` gives us the only atomic read/modify/write
    /// boundary available to the coordinator. The small reference box lets
    /// that synchronous transaction return its exact pre-mutation snapshot
    /// without adding a second, racy load.
    private final class SnapshotCapture: @unchecked Sendable {
        var value: CalendarSnapshot?
    }

    private var undoToken: UndoToken?
    private let peerMutationFence = CalendarPeerMutationFence()
#if DEBUG
    private var peerWarningObserverForTesting: (() -> Void)?
#endif
    // Every durable local or remote merge advances this generation. Async
    // network work captures the generation it started from and may only
    // publish its candidate if no newer durable operation completed first.
    private var durableGeneration: UInt64 = 0
    // MainActor reentrancy resumes each caller independently after the store
    // await. Chain the complete local commit outcome so snapshot publication,
    // revision assignment, and peer delivery cannot complete out of order.
    private var mutationTail: Task<CalendarLocalSaveResult, Never>?

    private enum CalendarMutation: Sendable {
        case upsert(CalendarItem)

        func applying(to snapshot: CalendarSnapshot) -> CalendarSnapshot {
            switch self {
            case .upsert(let item):
                // CalendarSnapshot's merge contract provides deterministic
                // last-write-wins for the same ID while retaining all
                // independent IDs from the latest durable snapshot.
                return snapshot.merged(with: CalendarSnapshot(items: [item]))
            }
        }
    }

    public init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        initialSnapshot: CalendarSnapshot = CalendarSnapshot(),
        usesVisualFixtures: Bool = false,
        storeURL: URL? = nil,
        /// Test-only seam for proving local durability is independent of
        /// peer delivery. Production callers leave this nil.
        peerSend: ((CalendarSnapshot, String, Int) throws -> Void)? = nil,
        /// Test-only seam for forcing overlapping local store awaits.
        storeMutationHook: (@Sendable () async throws -> Void)? = nil,
        /// Test-only seams for proving the production conditional calendar
        /// mutation protocol without replacing TailscaleSyncClient itself.
        calendarRemoteFetch: (@Sendable () async throws -> CalendarRemoteResource)? = nil,
        calendarRemotePush: (@Sendable (Data, String, String) async throws -> CalendarRemoteResource)? = nil,
        /// Test-only replacement for WidgetCenter; also permits an injected
        /// local store to exercise invalidation without an App Group entitlement.
        widgetTimelineReload: (([String]) -> Void)? = nil,
        defaults: (any CalendarDefaultsStore)? = nil
    ) {
        snapshot = initialSnapshot
        self.usesVisualFixtures = usesVisualFixtures
        let resolvedDefaults: any CalendarDefaultsStore = defaults
            ?? (usesVisualFixtures ? Self.makeVisualFixtureDefaults() : UserDefaults.standard)
        self.defaults = resolvedDefaults
        self.remoteSyncInjected = !usesVisualFixtures && (calendarRemoteFetch != nil && calendarRemotePush != nil)
        let usesInjectedTransport = usesVisualFixtures || storeURL != nil || peerSend != nil
            || storeMutationHook != nil || calendarRemoteFetch != nil || calendarRemotePush != nil
            || widgetTimelineReload != nil
        self.allowsLivePeerTransport = !usesInjectedTransport
        let selected: (URL, String, Bool) = {
            if let storeURL {
                return (storeURL, "Injected local store", false)
            }
            if usesVisualFixtures {
                // Fixture hosts must never resolve the personal App Group or
                // the normal Application Support calendar. Keep the store
                // file-backed so mutation tests still exercise the real
                // atomic CalendarStore path, but isolate every coordinator
                // instance under a unique temporary directory.
                let fixtureDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appendingPathComponent("LifeOS", isDirectory: true)
                    .appendingPathComponent("CalendarFixtures", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let url = CalendarStoreURL.localURL(baseDirectory: fixtureDirectory, fileManager: fileManager)
                return (url, "Isolated fixture store", false)
            }
            if let group = AppGroupConfiguration.identifier(bundle: bundle),
               let url = try? CalendarStoreURL.appGroupURL(identifier: group, fileManager: fileManager) {
                return (url, "App Group", true)
            }
            let url = CalendarStoreURL.localURL(fileManager: fileManager)
            return (url, "Local Application Support (this app only)", false)
        }()
        store = CalendarStore(url: selected.0, fileManager: fileManager, beforeMutation: storeMutationHook)
        storageDescription = selected.1
        sharedStorageAvailable = selected.2
        let key = "LifeOS.Calendar.senderID"
        if let existing = resolvedDefaults.string(forKey: key), !existing.isEmpty { senderID = existing }
        else { let value = UUID().uuidString; resolvedDefaults.set(value, forKey: key); senderID = value }
        revision = resolvedDefaults.integer(forKey: "LifeOS.Calendar.revision")
        if usesVisualFixtures {
            peerSync = FixtureCalendarPeerTransport()
            livePeerSync = nil
            tailscaleClient = nil
            self.remoteFetch = nil
            self.remotePush = nil
        } else {
            if !allowsLivePeerTransport || !resolvedDefaults.bool(forKey: CalendarNearbyDiscoveryPolicy.defaultsKey) {
                peerSync = FixtureCalendarPeerTransport()
                livePeerSync = nil
            } else {
                let live = LiveCalendarPeerTransport(displayName: senderID)
                peerSync = live
                livePeerSync = live
            }
            let client = TailscaleSyncClient()
            tailscaleClient = client
            self.remoteFetch = calendarRemoteFetch ?? { try await client.fetchCalendarResource() }
            self.remotePush = calendarRemotePush ?? { data, etag, idempotencyKey in
                try await client.pushCalendar(data, ifMatch: etag, idempotencyKey: idempotencyKey)
            }
        }
        self.widgetTimelineReload = widgetTimelineReload
        self.peerSend = peerSend
        configurePeerTransport(peerSync)
        if !usesVisualFixtures {
            nearbyDiscoveryObserver = NotificationCenter.default.addObserver(
                forName: CalendarNearbyDiscoveryPolicy.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.setNearbyDiscoveryEnabled(
                        self.defaults.bool(forKey: CalendarNearbyDiscoveryPolicy.defaultsKey)
                    )
                }
            }

            Task { [weak self] in
                guard let self, let client = self.tailscaleClient else { return }
                guard await client.isConfigured else { return }
                await client.connectChangeStream { type in
                    guard type == "calendar_changed" else { return }
                    Task { @MainActor in await self.pullMerge() }
                }
            }
        }
    }

    deinit {
        if let nearbyDiscoveryObserver {
            NotificationCenter.default.removeObserver(nearbyDiscoveryObserver)
        }
    }

    private func configurePeerTransport(_ transport: CalendarPeerTransport) {
        let peerMutationFence = peerMutationFence
        let transportToken = peerMutationFence.installTransport()
        transport.setPairingHandler { [weak self] state in
            DispatchQueue.main.async {
                guard let self, peerMutationFence.isInstalled(transportToken) else { return }
                self.pairingState = state
            }
        }
        transport.setStatusHandler { [weak self] status in
            // Revoke before handing the status to the MainActor. An
            // authenticated snapshot may already be queued behind the actor;
            // it must observe the retired generation before it can enter the
            // store's durable commit section.
            switch status {
            case .disconnected, .stopped, .failed:
                peerMutationFence.invalidate(transportToken)
            case .started, .connecting:
                break
            case .connected:
                // CalendarPeerSync emits this only after the pairing-secret
                // proof succeeds. Activation is scoped to this exact
                // installed transport, so an old callback cannot resurrect a
                // stopped or replaced connection.
                peerMutationFence.activate(transportToken)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard peerMutationFence.isInstalled(transportToken) else { return }
                self.syncStatus = status
                if case .connected = status, self.isLoaded {
                    self.sendPeer(snapshot: self.snapshot, revision: self.revision)
                }
            }
        }
        let localSenderID = senderID
        transport.setSnapshotHandler { [weak self] envelope, authenticatedSenderID in
            guard CalendarPeerEnvelopeAuthorization.isAuthorized(
                envelope: envelope,
                authenticatedSenderID: authenticatedSenderID,
                localSenderID: localSenderID
            ) else {
                Task { @MainActor [weak self] in
                    guard let self, peerMutationFence.isInstalled(transportToken) else { return }
                    self.rejectPeerEnvelope()
                }
                return
            }
            guard let peerToken = peerMutationFence.capture(transportToken) else {
                Task { @MainActor [weak self] in
                    guard let self, peerMutationFence.isInstalled(transportToken) else { return }
                    self.rejectPeerEnvelope()
                }
                return
            }
            Task { @MainActor in
                await self?.merge(
                    envelope.snapshot,
                    remoteRevision: envelope.revision,
                    remoteSentAt: envelope.sentAt,
                    peerToken: peerToken
                )
            }
        }
    }

    private func rejectPeerEnvelope() {
        peerSyncWarning = "Calendar sync rejected an unapproved peer message."
#if DEBUG
        peerWarningObserverForTesting?()
#endif
        refreshSyncWarning()
    }

    private func ensureLivePeerTransport() {
        guard allowsLivePeerTransport, livePeerSync == nil else { return }
        let live = LiveCalendarPeerTransport(displayName: senderID)
        peerSync = live
        livePeerSync = live
        configurePeerTransport(live)
    }

#if DEBUG
    /// Internal seam for deterministic lifecycle tests. Production construction
    /// still selects the fixture or live transport above; tests can replace it
    /// and retain the old callbacks to prove transport generations are fenced.
    func installPeerTransportForTesting(_ transport: CalendarPeerTransport) {
        peerMutationFence.invalidate()
        peerSync.stop()
        livePeerSync = nil
        peerSync = transport
        configurePeerTransport(transport)
    }

    func setPeerWarningObserverForTesting(_ observer: (() -> Void)?) {
        peerWarningObserverForTesting = observer
    }
#endif

    /// A stopped or cancelled live service retains its callback closures and
    /// in-memory pairing state. Replace it before the next pairing lifecycle
    /// so the new session receives a fresh mutation-fence generation and late
    /// callbacks from the predecessor cannot alter coordinator state.
    private func replaceLivePeerTransport() {
        guard allowsLivePeerTransport, let old = livePeerSync else { return }
        peerMutationFence.invalidate()
        let fresh = LiveCalendarPeerTransport(displayName: senderID)
        peerSync = fresh
        livePeerSync = fresh
        configurePeerTransport(fresh)
        old.stop()
        var state = CalendarPairingState()
        state.message = "Nearby sync is paused until this device is paired."
        state.available = true
        pairingState = state
        syncStatus = .stopped
    }

    private func deactivatePeerTransport() {
        peerMutationFence.invalidate()
        peerSync.stop()
        livePeerSync = nil
        peerSync = FixtureCalendarPeerTransport()
        configurePeerTransport(peerSync)
        publishDiscoveryDisabledState()
    }

    private func publishDiscoveryDisabledState() {
        var state = CalendarPairingState()
        state.message = "Nearby calendar discovery is disabled. Enable it in Sync & storage before pairing."
        state.available = false
        pairingState = state
        syncStatus = .stopped
    }

    public func load() async {
        let generation = durableGeneration
        do {
            let loaded = try await store.load()
            guard generation == durableGeneration else {
                isLoaded = true
                return
            }
            snapshot = loaded
            isLoaded = true
            if pendingFailedMutation == nil { errorMessage = nil }
            requestWidgetTimelineReloadIfNeeded()
        }
        catch { errorMessage = "Unable to load calendar: \(error.localizedDescription)"; isLoaded = true }
    }

    private func pairingAction(_ action: () throws -> Void) {
        pairingError = nil
        do { try action() }
        catch { pairingError = "Pairing rejected: invalid, expired, mismatched, or already used handoff. Cancel on both devices and create a new offer." }
    }
    public func createPairing() { pairingAction { try peerSync.createPairing() } }
    public func importPairing(_ token: String) { pairingAction { try peerSync.importPairing(token) } }
    public func confirmPairing() { pairingAction { try peerSync.confirmPairing() } }
    public func cancelPairing() {
        pairingError = nil
        if livePeerSync != nil {
            peerSync.cancelPairing()
            replaceLivePeerTransport()
        } else {
            peerMutationFence.invalidate()
            peerSync.cancelPairing()
        }
    }
    public func retryPairingConnection() {
        guard nearbyDiscoveryEnabled else { return }
        peerSync.retryPairingConnection()
    }

    public var nearbyDiscoveryEnabled: Bool {
        CalendarNearbyDiscoveryPolicy.allowsDiscovery(
            usesVisualFixtures: usesVisualFixtures,
            settingEnabled: defaults.bool(forKey: CalendarNearbyDiscoveryPolicy.defaultsKey)
        )
    }

    public func setNearbyDiscoveryEnabled(_ enabled: Bool) {
        guard !usesVisualFixtures else { return }
        defaults.set(enabled, forKey: CalendarNearbyDiscoveryPolicy.defaultsKey)
        if enabled {
            startSync()
        } else {
            deactivatePeerTransport()
        }
    }

    public func startSync() {
        guard nearbyDiscoveryEnabled, allowsLivePeerTransport else {
            if livePeerSync != nil { deactivatePeerTransport() }
            else { publishDiscoveryDisabledState() }
            return
        }
        ensureLivePeerTransport()
        peerSync.start()
    }

    public func stopSync() {
        if livePeerSync != nil {
            replaceLivePeerTransport()
        } else {
            peerMutationFence.invalidate()
            peerSync.stop()
        }
        if !nearbyDiscoveryEnabled { publishDiscoveryDisabledState() }
    }

    @discardableResult
    public func save(_ item: CalendarItem) async -> CalendarLocalSaveResult {
        await persist(.upsert(item))
    }

    @discardableResult
    public func delete(_ item: CalendarItem) async -> CalendarLocalSaveResult {
        await save(item.deleting(at: .now))
    }

    @discardableResult
    public func retryLastSave() async -> CalendarLocalSaveResult {
        if pendingFailedUndo {
            return await undoLastMutation()
        }
        guard let pendingFailedMutation else {
            return .failure("There is no failed calendar save to retry.")
        }
        return await persist(pendingFailedMutation.mutation, clearingFailureID: pendingFailedMutation.id)
    }

    /// Restores the exact durable snapshot immediately before the most recent
    /// successful local mutation. The operation is queued with saves and
    /// merges, so it cannot overwrite a newer durable result. A successful
    /// undo consumes its token; a persistence failure leaves it available for
    /// another attempt.
    @discardableResult
    public func undoLastMutation() async -> CalendarLocalSaveResult {
        await enqueueDurableOperation { [weak self] in
            guard let self else { return .failure("Calendar coordinator is unavailable.") }
            return await self.performUndo()
        }
    }

    /// Short alias for command/menu callers that only expose an Undo action.
    @discardableResult
    public func undo() async -> CalendarLocalSaveResult {
        await undoLastMutation()
    }

    @discardableResult
    func merge(
        _ remote: CalendarSnapshot,
        remoteRevision: Int? = nil,
        remoteSentAt: Date? = nil,
        peerToken: CalendarPeerMutationFence.Token? = nil,
        now: Date = .now
    ) async -> CalendarLocalSaveResult {
        await enqueueDurableOperation { [weak self] in
            guard let self else { return .failure("Calendar coordinator is unavailable.") }
            return await self.performRemoteMerge(
                remote,
                remoteRevision: remoteRevision,
                remoteSentAt: remoteSentAt,
                peerToken: peerToken,
                now: now
            )
        }
    }

    @discardableResult
    private func persist(_ mutation: CalendarMutation, clearingFailureID: UUID? = nil) async -> CalendarLocalSaveResult {
        await enqueueDurableOperation { [weak self] in
            guard let self else { return .failure("Calendar coordinator is unavailable.") }
            return await self.performPersist(mutation, clearingFailureID: clearingFailureID)
        }
    }

    /// All durable calendar operations share one FIFO tail. Swift actor
    /// reentrancy otherwise permits a remote merge or undo to resume between
    /// the store await and publication of a local save.
    private func enqueueDurableOperation(
        _ operation: @escaping @MainActor () async -> CalendarLocalSaveResult
    ) async -> CalendarLocalSaveResult {
        let previous = mutationTail
        let task: Task<CalendarLocalSaveResult, Never> = Task { @MainActor [weak self] in
            if let previous { _ = await previous.value }
            guard self != nil else { return .failure("Calendar coordinator is unavailable.") }
            return await operation()
        }
        mutationTail = task
        return await task.value
    }

    private func performPersist(_ mutation: CalendarMutation, clearingFailureID: UUID?) async -> CalendarLocalSaveResult {
        let publishedBefore = snapshot
        let loadedBeforeMutation = isLoaded
        let isFixtureMode = usesVisualFixtures
        let capture = SnapshotCapture()
        do {
            let committedSnapshot = try await store.mutate { current in
                // Fixture launches skip the initial durable load and use the
                // injected snapshot as their complete test/preview world. A
                // reused app container may still contain unrelated durable
                // data, so never read it into a fixture mutation.
                let before = isFixtureMode || (!loadedBeforeMutation && current.items.isEmpty && !publishedBefore.items.isEmpty)
                    ? publishedBefore
                    : current
                capture.value = before
                return mutation.applying(to: before)
            }
            guard let previousSnapshot = capture.value else {
                let message = "Unable to save calendar: missing pre-mutation snapshot."
                errorMessage = message
                pendingFailedUndo = false
                pendingFailedMutation = FailedMutation(id: UUID(), mutation: mutation)
                return .failure(message)
            }
            durableGeneration &+= 1
            snapshot = committedSnapshot
            isLoaded = true
            if let clearingFailureID, pendingFailedMutation?.id == clearingFailureID {
                pendingFailedMutation = nil
            }
            pendingFailedUndo = false
            revision += 1
            defaults.set(revision, forKey: "LifeOS.Calendar.revision")
            if pendingFailedMutation == nil { errorMessage = nil }

            // Every successful local mutation supersedes the previous one-shot
            // undo. The value is the exact snapshot read inside the atomic
            // store transaction, including tombstones and icon metadata.
            setUndoToken(UndoToken(id: UUID(), snapshot: previousSnapshot))

            // Keep the exact durable value associated with this queued
            // commit. A later MainActor task cannot alter what is delivered.
            let committedRevision = revision
            sendPeer(snapshot: committedSnapshot, revision: committedRevision)
            requestWidgetTimelineReloadIfNeeded()
        } catch {
            let message = "Unable to save calendar: \(error.localizedDescription)"
            errorMessage = message
            pendingFailedUndo = false
            pendingFailedMutation = FailedMutation(id: UUID(), mutation: mutation)
            return .failure(message)
        }
        return .success
    }

    private func performUndo() async -> CalendarLocalSaveResult {
        guard let token = undoToken else {
            return .failure("There is no calendar mutation to undo.")
        }

        do {
            // CalendarStore.save uses the same temporary-file + replace
            // sequence as every other local persistence operation. Exact
            // undo is deliberately local-only: sending this older snapshot
            // to a peer would lose to that peer's newer LWW mutation.
            let restoredSnapshot = try await store.save(token.snapshot)
            guard undoToken?.id == token.id else {
                return .failure("Undo is no longer available.")
            }
            durableGeneration &+= 1
            snapshot = restoredSnapshot
            isLoaded = true
            setUndoToken(nil)
            pendingFailedUndo = false
            revision += 1
            defaults.set(revision, forKey: "LifeOS.Calendar.revision")
            if pendingFailedMutation == nil { errorMessage = nil }
            requestWidgetTimelineReloadIfNeeded()
            return .success
        } catch {
            let message = "Unable to undo calendar mutation: \(error.localizedDescription)"
            errorMessage = message
            pendingFailedUndo = true
            // Keep the token: a failed atomic write did not change the
            // published or durable snapshot, so the user can retry Undo.
            return .failure(message)
        }
    }

    private func performRemoteMerge(
        _ remote: CalendarSnapshot,
        remoteRevision: Int?,
        remoteSentAt: Date?,
        peerToken: CalendarPeerMutationFence.Token?,
        now: Date
    ) async -> CalendarLocalSaveResult {
        let generation = durableGeneration
        do {
            if let peerToken, !peerMutationFence.isCurrent(peerToken) {
                return .failure("Calendar sync authorization expired; remote change was discarded.")
            }
            try remote.validatedForPersistence()
            let durable = try await store.load()
            let local = !isLoaded && durable.items.isEmpty && !snapshot.items.isEmpty ? snapshot : durable
            let report = CalendarRemoteMergePolicy.sanitize(
                remote,
                against: local,
                now: now,
                sentAt: remoteSentAt
            )
            if let warning = report.warning {
                markRemoteMutationWarning(warning)
            } else {
                clearRemoteMutationWarning()
            }
            let merged: CalendarSnapshot
            if let peerToken {
                merged = try await store.merge(
                    report.snapshot,
                    authorizedBy: peerMutationFence,
                    token: peerToken
                )
            } else {
                merged = try await store.merge(report.snapshot)
            }
            let persistedChange = merged != durable
            await publishRemoteMerge(
                merged,
                startedAt: generation,
                remoteRevision: remoteRevision,
                peerToken: peerToken,
                persistedChange: persistedChange
            )
            requestWidgetTimelineReloadIfNeeded()
            return .success
        } catch {
            errorMessage = "Unable to merge calendar: \(error.localizedDescription)"
            return .failure(errorMessage ?? "Unable to merge calendar.")
        }
    }

    private func requestWidgetTimelineReloadIfNeeded() {
        guard sharedStorageAvailable || widgetTimelineReload != nil else { return }
        // Loads, merges, and authoritative adoption can observe the same
        // durable value. Compare the persisted representation so date precision
        // lost in JSON round-trips cannot cause duplicate reloads.
        guard let data = try? JSONEncoder.calendar.encode(snapshot),
              lastWidgetReloadData != data else { return }
        lastWidgetReloadData = data
        if let widgetTimelineReload {
            widgetTimelineReload(CalendarWidgetTimelineReloader.kinds)
        } else {
            CalendarWidgetTimelineReloader.reload(CalendarWidgetTimelineReloader.kinds)
        }
    }

    private func sendPeer(snapshot: CalendarSnapshot, revision: Int) {
        peerSyncWarning = nil
        refreshSyncWarning()
        do {
            if let peerSend {
                try peerSend(snapshot, senderID, revision)
            } else {
                try peerSync.send(snapshot: snapshot, senderID: senderID, revision: revision)
            }
        } catch {
            peerSyncWarning = "Calendar saved locally; peer sync warning: \(error.localizedDescription)"
            refreshSyncWarning()
        }
    }

    private func setUndoToken(_ token: UndoToken?) {
        undoToken = token
        canUndo = token != nil
    }

    /// Pull-merge only, used when a remote change notification arrives over
    /// the WebSocket. The resource API validates the ETag-bearing response
    /// before merging; an explicit sync fetches a fresh ETag before writing.
    private func pullMerge() async {
        guard !usesVisualFixtures,
              let fetch = remoteFetch,
              await remoteFetchIsAvailable() else { return }
        do {
            let resource = try await fetch()
            let remote = try decodeRemoteSnapshot(resource.data)
            let result = await merge(remote)
            if case .success = result {
                clearRemoteSyncWarning()
            } else {
                markRemoteSyncWarning("Calendar sync is unavailable; local calendar remains available.")
            }
        } catch {
            markRemoteSyncWarning("Calendar sync is unavailable; local calendar remains available.")
        }
    }

    /// Pull-merge only on demand (pull-to-refresh, Cmd+R). Uploading local
    /// calendar data remains an explicit `syncNow()` action; refresh never
    /// turns into a hidden remote write.
    public func manualRefresh() async {
        guard !usesVisualFixtures else { return }
        guard await remoteFetchIsAvailable() else {
            markRemoteSyncWarning("Calendar sync is unavailable; configure a Tailscale server to refresh.")
            return
        }
        await pullMerge()
    }

    /// Explicitly synchronizes the current durable snapshot with the
    /// configured calendar authority. Local saves never call this implicitly.
    /// The operation uses one idempotency key across a maximum of three
    /// conditional attempts. A remote failure is reported as `.failure` while
    /// the already durable local snapshot remains visible and acknowledged.
    @discardableResult
    public func syncNow() async -> CalendarLocalSaveResult {
        guard !usesVisualFixtures else { return .failure("Calendar sync is unavailable for visual fixtures.") }
        guard await remoteMutationIsAvailable() else {
            markRemoteSyncWarning("Calendar sync is unavailable; local calendar remains available.")
            return .failure("Calendar sync is unavailable; local calendar remains available.")
        }
        guard !remoteSyncInFlight else {
            return .failure("Calendar sync is already in progress.")
        }
        remoteSyncInFlight = true
        defer { remoteSyncInFlight = false }
        if let mutationTail { _ = await mutationTail.value }
        return await synchronizeRemoteSnapshot(snapshot, idempotencyKey: "calendar-\(UUID().uuidString)")
    }

    private func remoteFetchIsAvailable() async -> Bool {
        guard remoteFetch != nil else { return false }
        if remoteSyncInjected { return true }
        guard let tailscaleClient else { return false }
        return await tailscaleClient.isConfigured
    }

    private func remoteMutationIsAvailable() async -> Bool {
        guard remoteFetch != nil, remotePush != nil else { return false }
        if remoteSyncInjected { return true }
        guard let tailscaleClient else { return false }
        return await tailscaleClient.isConfigured
    }

    private func decodeRemoteSnapshot(_ data: Data) throws -> CalendarSnapshot {
        guard data.count <= CalendarSnapshot.maximumEncodedBytes else {
            throw CalendarSnapshotError.payloadTooLarge
        }
        let snapshot = try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: data)
        try snapshot.validatedForPersistence()
        return snapshot
    }

    private func encodeRemoteSnapshot(_ snapshot: CalendarSnapshot) throws -> Data {
        try snapshot.validatedForPersistence()
        let data = try JSONEncoder.calendar.encode(snapshot)
        guard data.count <= CalendarSnapshot.maximumEncodedBytes else {
            throw CalendarSnapshotError.payloadTooLarge
        }
        return data
    }

    /// Performs one bounded read/merge/conditional-write sequence. A 412/428
    /// carries authoritative truth from the existing client API; that truth is
    /// merged before the next attempt. The idempotency key is created once by
    /// the explicit sync operation and reused for every retry.
    private func synchronizeRemoteSnapshot(_ localSnapshot: CalendarSnapshot, idempotencyKey: String) async -> CalendarLocalSaveResult {
        guard !usesVisualFixtures,
              let fetch = remoteFetch,
              let push = remotePush else {
            return .failure("Calendar sync is unavailable; local calendar remains available.")
        }
        guard await remoteMutationIsAvailable() else {
            return .failure("Calendar sync is unavailable; local calendar remains available.")
        }

        do {
            var resource = try await fetch()
            var candidate = localSnapshot

            for attempt in 0..<Self.maximumRemoteMutationAttempts {
                let remote = try decodeRemoteSnapshot(resource.data)
                let report = CalendarRemoteMergePolicy.sanitize(
                    remote,
                    against: candidate,
                    now: .now
                )
                if let warning = report.warning {
                    markRemoteMutationWarning(warning)
                }
                candidate = report.snapshot.merged(with: candidate)
                let body = try encodeRemoteSnapshot(candidate)

                do {
                    let accepted = try await push(body, resource.etag, idempotencyKey)
                    if let adopted = try await adoptRemoteResource(accepted) {
                        // A conflict may have added independent remote items;
                        // deliver the reconciled server truth to nearby peers.
                        sendPeer(snapshot: adopted, revision: revision)
                    }
                    clearRemoteSyncWarning()
                    defaults.set(Date.now.timeIntervalSince1970, forKey: "LifeOS.Sync.LastSuccess")
                    return .success
                } catch let syncError as CalendarSyncError {
                    guard case .calendarConflict(let data, let etag) = syncError else {
                        throw syncError
                    }
                    guard attempt + 1 < Self.maximumRemoteMutationAttempts else {
                        throw CalendarRemoteMutationError.attemptsExhausted
                    }
                    // The next loop merges this authoritative conflict body
                    // with the current candidate before retrying the PUT.
                    resource = CalendarRemoteResource(data: data, etag: etag)
                }
            }
        } catch {
            // The local snapshot remains acknowledged. Keep the limitation
            // visible without exposing raw endpoint or transport details.
            let message = "Calendar saved locally; remote sync is unavailable and will retry on the next refresh."
            markRemoteSyncWarning(message)
            return .failure(message)
        }
        return .failure("Calendar sync is unavailable; local calendar remains available.")
    }

    /// Stores the authoritative success resource without dropping a newer
    /// local item that may have appeared while the network request was in
    /// flight. Adoption is queued with local mutations so the store's atomic
    /// read/modify/write and coordinator publication cannot overtake each
    /// other. A changed authoritative snapshot invalidates local undo because
    /// it is now a remote merge as well as a local commit.
    private func adoptRemoteResource(_ resource: CalendarRemoteResource) async throws -> CalendarSnapshot? {
        let authoritative = try decodeRemoteSnapshot(resource.data)
        let capture = SnapshotCapture()
        let result = await enqueueDurableOperation { [weak self] in
            guard let self else { return .failure("Calendar coordinator is unavailable.") }
            do {
                let durable = try await self.store.load()
                let report = CalendarRemoteMergePolicy.sanitize(
                    authoritative,
                    against: durable,
                    now: .now
                )
                if let warning = report.warning {
                    self.markRemoteMutationWarning(warning)
                }
                let persisted = try await self.store.merge(report.snapshot)
                guard !self.isLoaded || persisted != self.snapshot else { return .success }
                self.durableGeneration &+= 1
                self.snapshot = persisted
                self.isLoaded = true
                self.setUndoToken(nil)
                self.pendingFailedUndo = false
                self.revision += 1
                self.defaults.set(self.revision, forKey: "LifeOS.Calendar.revision")
                if self.pendingFailedMutation == nil { self.errorMessage = nil }
                self.requestWidgetTimelineReloadIfNeeded()
                capture.value = persisted
                return .success
            } catch {
                return .failure("Unable to adopt authoritative calendar state.")
            }
        }
        guard case .success = result else { throw CalendarRemoteMutationError.adoptionFailed }
        return capture.value
    }

    private func markRemoteSyncWarning(_ message: String) {
        remoteSyncWarning = message
        refreshSyncWarning()
    }

    private func markRemoteMutationWarning(_ message: String) {
        remoteMutationWarning = message
        refreshSyncWarning()
    }

    private func clearRemoteMutationWarning() {
        remoteMutationWarning = nil
        refreshSyncWarning()
    }

    private func clearRemoteSyncWarning() {
        remoteSyncWarning = nil
        refreshSyncWarning()
    }

    private func refreshSyncWarning() {
        let warnings = [peerSyncWarning, remoteSyncWarning, remoteMutationWarning].compactMap { $0 }
        syncWarning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
    }

    /// Publishes a remote merge only if it was based on the current durable
    /// operation generation. If a newer operation won while the merge or its
    /// network round trip was suspended, reload the actor's durable truth and
    /// publish that instead (guarding the reload itself against another race).
    private func publishRemoteMerge(
        _ merged: CalendarSnapshot,
        startedAt generation: UInt64,
        remoteRevision: Int?,
        peerToken: CalendarPeerMutationFence.Token? = nil,
        persistedChange: Bool
    ) async {
        if let peerToken, !peerMutationFence.isCurrent(peerToken) {
            // `CalendarStore.merge` holds the same fence lock through its
            // complete read/merge/write transaction. If revocation waited
            // for that transaction, the peer change is already durable even
            // though its delivery token is now retired. Reconcile it here so
            // an older local Undo token cannot later erase the accepted peer
            // change. An idempotent replay leaves the local Undo available.
            if persistedChange {
                adoptCommittedRemoteMerge(merged, remoteRevision: remoteRevision)
            }
            return
        }
        if let remoteRevision {
            revision = max(revision, remoteRevision)
            defaults.set(revision, forKey: "LifeOS.Calendar.revision")
        }

        guard generation == durableGeneration else {
            do {
                let reloadGeneration = durableGeneration
                let latest = try await store.load()
                guard reloadGeneration == durableGeneration else { return }
                snapshot = latest
                isLoaded = true
                defaults.set(Date.now.timeIntervalSince1970, forKey: "LifeOS.Sync.LastSuccess")
                if pendingFailedMutation == nil { errorMessage = nil }
            } catch {
                // The newer local operation already owns publication/error
                // state; do not replace it with a stale sync failure.
            }
            return
        }

        guard !isLoaded || merged != snapshot else {
            isLoaded = true
            return
        }

        adoptCommittedRemoteMerge(merged, remoteRevision: remoteRevision)
    }

    /// Publishes a remote snapshot whose store transaction has already
    /// completed. This path deliberately clears local Undo because the
    /// previous snapshot no longer represents the durable state immediately
    /// before the latest accepted change.
    private func adoptCommittedRemoteMerge(_ merged: CalendarSnapshot, remoteRevision: Int?) {
        durableGeneration &+= 1
        snapshot = merged
        isLoaded = true
        setUndoToken(nil)
        pendingFailedUndo = false
        if let remoteRevision {
            revision = max(revision, remoteRevision)
            defaults.set(revision, forKey: "LifeOS.Calendar.revision")
        }
        defaults.set(Date.now.timeIntervalSince1970, forKey: "LifeOS.Sync.LastSuccess")
        if pendingFailedMutation == nil { errorMessage = nil }
    }
}
