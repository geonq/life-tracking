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

private enum CalendarRemoteMutationError: Error {
    case attemptsExhausted
    case adoptionFailed
}

/// The coordinator owns Calendar behavior, but the concrete peer service is
/// deliberately hidden behind this small transport boundary. Fixture hosts
/// receive a no-op implementation and therefore cannot create a
/// MultipeerConnectivity advertiser/browser just by constructing a calendar
/// coordinator.
private protocol CalendarPeerTransport: AnyObject {
    func setStatusHandler(_ handler: @escaping (CalendarPeerConnectionStatus) -> Void)
    func setSnapshotHandler(_ handler: @escaping (CalendarPeerSyncEnvelope) -> Void)
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

    func setSnapshotHandler(_ handler: @escaping (CalendarPeerSyncEnvelope) -> Void) {
        service.onSnapshotReceived = { envelope, _ in handler(envelope) }
    }

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
    func setSnapshotHandler(_ handler: @escaping (CalendarPeerSyncEnvelope) -> Void) {}
    func start() {}
    func stop() {}
    func send(snapshot: CalendarSnapshot, senderID: String, revision: Int) throws {}
}

private enum CalendarWidgetTimelineReloader {
    static func reload() {
#if canImport(WidgetKit)
        // Reload only the calendar kinds. This is a one-way app-to-widget
        // notification; widget timeline reads never call back into this path.
        WidgetCenter.shared.reloadTimelines(ofKind: "LifeOSCalendarWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "LifeOSNextEventWidget")
#endif
    }
}

@available(iOS 17.0, macOS 14.0, *)
@MainActor
public final class CalendarCoordinator: ObservableObject {
    private typealias CalendarRemoteFetch = @Sendable () async throws -> CalendarRemoteResource
    private typealias CalendarRemotePush = @Sendable (Data, String, String) async throws -> CalendarRemoteResource
    private static let maximumRemoteMutationAttempts = 3

    @Published public private(set) var snapshot = CalendarSnapshot()
    @Published public private(set) var storageDescription = ""
    @Published public private(set) var syncStatus: CalendarPeerConnectionStatus = .stopped
    @Published public private(set) var syncWarning: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isLoaded = false
    @Published public private(set) var canUndo = false
    @Published public private(set) var sharedStorageAvailable = false

    public let store: CalendarStore
    public let senderID: String
    private var revision: Int
    private let peerSync: CalendarPeerTransport
    private let tailscaleClient: TailscaleSyncClient?
    private let remoteFetch: CalendarRemoteFetch?
    private let remotePush: CalendarRemotePush?
    private let remoteSyncInjected: Bool
    private let peerSend: ((CalendarSnapshot, String, Int) throws -> Void)?
    /// Fixture launches intentionally start from their injected snapshot and
    /// must not let a reused app container replace it on the first mutation.
    private let usesVisualFixtures: Bool
    private struct FailedMutation: Sendable {
        let id: UUID
        let mutation: CalendarMutation
    }

    private var pendingFailedMutation: FailedMutation?
    private var pendingFailedUndo = false
    private var peerSyncWarning: String?
    private var remoteSyncWarning: String?
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
        calendarRemotePush: (@Sendable (Data, String, String) async throws -> CalendarRemoteResource)? = nil
    ) {
        snapshot = initialSnapshot
        self.usesVisualFixtures = usesVisualFixtures
        self.remoteSyncInjected = !usesVisualFixtures && (calendarRemoteFetch != nil && calendarRemotePush != nil)
        let selected: (URL, String, Bool) = {
            if let storeURL {
                return (storeURL, "Injected local store", false)
            }
            if let group = AppGroupConfiguration.identifier(bundle: bundle),
               let url = try? CalendarStoreURL.appGroupURL(identifier: group, fileManager: fileManager) {
                return (url, "App Group", true)
            }
            let url = storeURL ?? CalendarStoreURL.localURL(fileManager: fileManager)
            return (url, "Local Application Support (this app only)", false)
        }()
        store = CalendarStore(url: selected.0, fileManager: fileManager, beforeMutation: storeMutationHook)
        storageDescription = selected.1
        sharedStorageAvailable = selected.2
        let defaults = UserDefaults.standard
        let key = "LifeOS.Calendar.senderID"
        if let existing = defaults.string(forKey: key), !existing.isEmpty { senderID = existing }
        else { let value = UUID().uuidString; defaults.set(value, forKey: key); senderID = value }
        revision = defaults.integer(forKey: "LifeOS.Calendar.revision")
        if usesVisualFixtures {
            peerSync = FixtureCalendarPeerTransport()
            tailscaleClient = nil
            self.remoteFetch = nil
            self.remotePush = nil
        } else {
            peerSync = LiveCalendarPeerTransport(displayName: senderID)
            let client = TailscaleSyncClient()
            tailscaleClient = client
            self.remoteFetch = calendarRemoteFetch ?? { try await client.fetchCalendarResource() }
            self.remotePush = calendarRemotePush ?? { data, etag, idempotencyKey in
                try await client.pushCalendar(data, ifMatch: etag, idempotencyKey: idempotencyKey)
            }
        }
        self.peerSend = peerSend
        peerSync.setStatusHandler { [weak self] status in
            Task { @MainActor in self?.syncStatus = status }
        }
        peerSync.setSnapshotHandler { [weak self] envelope in
            Task { @MainActor in await self?.merge(envelope.snapshot, remoteRevision: envelope.revision) }
        }

        if !usesVisualFixtures {
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

    public func startSync() { peerSync.start() }
    public func stopSync() { peerSync.stop() }

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
    func merge(_ remote: CalendarSnapshot, remoteRevision: Int? = nil) async -> CalendarLocalSaveResult {
        await enqueueDurableOperation { [weak self] in
            guard let self else { return .failure("Calendar coordinator is unavailable.") }
            return await self.performRemoteMerge(remote, remoteRevision: remoteRevision)
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
            UserDefaults.standard.set(revision, forKey: "LifeOS.Calendar.revision")
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
            UserDefaults.standard.set(revision, forKey: "LifeOS.Calendar.revision")
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

    private func performRemoteMerge(_ remote: CalendarSnapshot, remoteRevision: Int?) async -> CalendarLocalSaveResult {
        let generation = durableGeneration
        do {
            try remote.validatedForPersistence()
            let merged = try await store.merge(remote)
            await publishRemoteMerge(merged, startedAt: generation, remoteRevision: remoteRevision)
            requestWidgetTimelineReloadIfNeeded()
            return .success
        } catch {
            errorMessage = "Unable to merge calendar: \(error.localizedDescription)"
            return .failure(errorMessage ?? "Unable to merge calendar.")
        }
    }

    private func requestWidgetTimelineReloadIfNeeded() {
        guard sharedStorageAvailable else { return }
        CalendarWidgetTimelineReloader.reload()
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
                candidate = remote.merged(with: candidate)
                let body = try encodeRemoteSnapshot(candidate)

                do {
                    let accepted = try await push(body, resource.etag, idempotencyKey)
                    if let adopted = try await adoptRemoteResource(accepted) {
                        // A conflict may have added independent remote items;
                        // deliver the reconciled server truth to nearby peers.
                        sendPeer(snapshot: adopted, revision: revision)
                    }
                    clearRemoteSyncWarning()
                    UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "LifeOS.Sync.LastSuccess")
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
                let persisted = try await self.store.merge(authoritative)
                guard !self.isLoaded || persisted != self.snapshot else { return .success }
                self.durableGeneration &+= 1
                self.snapshot = persisted
                self.isLoaded = true
                self.setUndoToken(nil)
                self.pendingFailedUndo = false
                self.revision += 1
                UserDefaults.standard.set(self.revision, forKey: "LifeOS.Calendar.revision")
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

    private func clearRemoteSyncWarning() {
        remoteSyncWarning = nil
        refreshSyncWarning()
    }

    private func refreshSyncWarning() {
        let warnings = [peerSyncWarning, remoteSyncWarning].compactMap { $0 }
        syncWarning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
    }

    /// Publishes a remote merge only if it was based on the current durable
    /// operation generation. If a newer operation won while the merge or its
    /// network round trip was suspended, reload the actor's durable truth and
    /// publish that instead (guarding the reload itself against another race).
    private func publishRemoteMerge(
        _ merged: CalendarSnapshot,
        startedAt generation: UInt64,
        remoteRevision: Int?
    ) async {
        if let remoteRevision {
            revision = max(revision, remoteRevision)
            UserDefaults.standard.set(revision, forKey: "LifeOS.Calendar.revision")
        }

        guard generation == durableGeneration else {
            do {
                let reloadGeneration = durableGeneration
                let latest = try await store.load()
                guard reloadGeneration == durableGeneration else { return }
                snapshot = latest
                isLoaded = true
                UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "LifeOS.Sync.LastSuccess")
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

        durableGeneration &+= 1
        snapshot = merged
        setUndoToken(nil)
        pendingFailedUndo = false
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "LifeOS.Sync.LastSuccess")
        if pendingFailedMutation == nil { errorMessage = nil }
    }
}
