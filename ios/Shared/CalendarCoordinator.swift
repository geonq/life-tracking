import Foundation
import Combine

public enum CalendarLocalSaveResult: Equatable, Sendable {
    case success
    case failure(String)
}

public typealias CalendarUpdateCompletion = (CalendarLocalSaveResult) -> Void
// The gesture layer may retain completion while the coordinator performs its
// asynchronous local save, so the handler contract must permit that escape.
public typealias CalendarUpdateHandler = (CalendarItem, Date, Date, @escaping CalendarUpdateCompletion) -> Void

@available(iOS 17.0, macOS 14.0, *)
@MainActor
public final class CalendarCoordinator: ObservableObject {
    @Published public private(set) var snapshot = CalendarSnapshot()
    @Published public private(set) var storageDescription = ""
    @Published public private(set) var syncStatus: CalendarPeerConnectionStatus = .stopped
    @Published public private(set) var syncWarning: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isLoaded = false
    @Published public private(set) var canUndo = false

    public let store: CalendarStore
    public let senderID: String
    private var revision: Int
    private let peerSync: CalendarPeerSync
    private let tailscaleClient: TailscaleSyncClient
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
        storeMutationHook: (@Sendable () async throws -> Void)? = nil
    ) {
        snapshot = initialSnapshot
        self.usesVisualFixtures = usesVisualFixtures
        let group = bundle.object(forInfoDictionaryKey: "APP_GROUP_IDENTIFIER") as? String
        let selected: (URL, String) = {
            if let storeURL {
                return (storeURL, "Injected local store")
            }
            if let group, let url = try? CalendarStoreURL.appGroupURL(identifier: group, fileManager: fileManager) {
                return (url, "App Group")
            }
            let url = storeURL ?? CalendarStoreURL.localURL(fileManager: fileManager)
            return (url, "Local Application Support (this app only)")
        }()
        store = CalendarStore(url: selected.0, fileManager: fileManager, beforeMutation: storeMutationHook)
        storageDescription = selected.1
        let defaults = UserDefaults.standard
        let key = "LifeOS.Calendar.senderID"
        if let existing = defaults.string(forKey: key), !existing.isEmpty { senderID = existing }
        else { let value = UUID().uuidString; defaults.set(value, forKey: key); senderID = value }
        revision = defaults.integer(forKey: "LifeOS.Calendar.revision")
        peerSync = CalendarPeerSync(displayName: senderID)
        tailscaleClient = TailscaleSyncClient()
        self.peerSend = peerSend
        peerSync.onStatusChanged = { [weak self] status in
            Task { @MainActor in self?.syncStatus = status }
        }
        peerSync.onSnapshotReceived = { [weak self] envelope, _ in
            Task { @MainActor in await self?.merge(envelope.snapshot, remoteRevision: envelope.revision) }
        }

        let client = tailscaleClient
        Task { [weak self] in
            guard await client.isConfigured else { return }
            await client.connectChangeStream { type in
                guard type == "calendar_changed" else { return }
                Task { @MainActor in await self?.pullMerge() }
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
            let merged = try await store.merge(remote)
            await publishRemoteMerge(merged, startedAt: generation, remoteRevision: remoteRevision)
            return .success
        } catch {
            errorMessage = "Unable to merge calendar: \(error.localizedDescription)"
            return .failure(errorMessage ?? "Unable to merge calendar.")
        }
    }

    private func sendPeer(snapshot: CalendarSnapshot, revision: Int) {
        syncWarning = nil
        do {
            if let peerSend {
                try peerSend(snapshot, senderID, revision)
            } else {
                try peerSync.send(snapshot: snapshot, senderID: senderID, revision: revision)
            }
        } catch {
            syncWarning = "Calendar saved locally; peer sync warning: \(error.localizedDescription)"
        }
    }

    private func setUndoToken(_ token: UndoToken?) {
        undoToken = token
        canUndo = token != nil
    }

    /// Pull-merge only, used when a remote change notification arrives over the WebSocket.
    private func pullMerge() async {
        do {
            let remoteData = try await tailscaleClient.fetchCalendar()
            let remote = try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: remoteData)
            await merge(remote)
        } catch {
            // Tailscale sync is opt-in/best-effort; do not surface transient network errors as blocking UI state.
        }
    }

    /// Pull-merge only on demand (pull-to-refresh, Cmd+R). Calendar PUT stays
    /// behind the unimplemented conditional remote-mutation boundary; local
    /// recovery must never turn refresh into a blind Tailscale write.
    public func manualRefresh() async {
        guard await tailscaleClient.isConfigured else { return }
        do {
            let remoteData = try await tailscaleClient.fetchCalendar()
            let remote = try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: remoteData)
            await merge(remote)
        } catch {
            errorMessage = "Unable to sync with Tailscale: \(error.localizedDescription)"
        }
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
                setUndoToken(nil)
                pendingFailedUndo = false
                UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "LifeOS.Sync.LastSuccess")
                if pendingFailedMutation == nil { errorMessage = nil }
            } catch {
                // The newer local operation already owns publication/error
                // state; do not replace it with a stale sync failure.
            }
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
