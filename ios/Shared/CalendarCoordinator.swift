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

    public let store: CalendarStore
    public let senderID: String
    private var revision: Int
    private let peerSync: CalendarPeerSync
    private let tailscaleClient: TailscaleSyncClient
    private let peerSend: ((CalendarSnapshot, String, Int) throws -> Void)?
    private struct FailedMutation: Sendable {
        let id: UUID
        let mutation: CalendarMutation
    }

    private enum SyncStateError: LocalizedError {
        case durableStateChangedDuringRead

        var errorDescription: String? {
            "Calendar changed repeatedly while preparing a sync payload."
        }
    }

    private var pendingFailedMutation: FailedMutation?
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
        storeURL: URL? = nil,
        /// Test-only seam for proving local durability is independent of
        /// peer delivery. Production callers leave this nil.
        peerSend: ((CalendarSnapshot, String, Int) throws -> Void)? = nil,
        /// Test-only seam for forcing overlapping local store awaits.
        storeMutationHook: (@Sendable () async throws -> Void)? = nil
    ) {
        snapshot = initialSnapshot
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
        guard let pendingFailedMutation else {
            return .failure("There is no failed calendar save to retry.")
        }
        return await persist(pendingFailedMutation.mutation, clearingFailureID: pendingFailedMutation.id)
    }

    private func merge(_ remote: CalendarSnapshot, remoteRevision: Int) async {
        let generation = durableGeneration
        do {
            let merged = try await store.merge(remote)
            await publishRemoteMerge(merged, startedAt: generation, remoteRevision: remoteRevision)
        }
        catch { errorMessage = "Unable to merge calendar: \(error.localizedDescription)" }
    }

    @discardableResult
    private func persist(_ mutation: CalendarMutation, clearingFailureID: UUID? = nil) async -> CalendarLocalSaveResult {
        let previous = mutationTail
        let task: Task<CalendarLocalSaveResult, Never> = Task { @MainActor [weak self] in
            if let previous { _ = await previous.value }
            guard let self else { return .failure("Calendar coordinator is unavailable.") }
            return await self.performPersist(mutation, clearingFailureID: clearingFailureID)
        }
        mutationTail = task
        return await task.value
    }

    private func performPersist(_ mutation: CalendarMutation, clearingFailureID: UUID?) async -> CalendarLocalSaveResult {
        do {
            let committedSnapshot = try await store.mutate { current in
                mutation.applying(to: current)
            }
            durableGeneration &+= 1
            snapshot = committedSnapshot
            if let clearingFailureID, pendingFailedMutation?.id == clearingFailureID {
                pendingFailedMutation = nil
            }
            revision += 1
            UserDefaults.standard.set(revision, forKey: "LifeOS.Calendar.revision")
            if pendingFailedMutation == nil { errorMessage = nil }

            // Keep the exact durable value associated with this queued
            // commit. A later MainActor task cannot alter what is delivered.
            let committedRevision = revision
            syncWarning = nil
            do {
                if let peerSend {
                    try peerSend(committedSnapshot, senderID, committedRevision)
                } else {
                    try peerSync.send(snapshot: committedSnapshot, senderID: senderID, revision: committedRevision)
                }
            } catch {
                syncWarning = "Calendar saved locally; peer sync warning: \(error.localizedDescription)"
            }
        } catch {
            let message = "Unable to save calendar: \(error.localizedDescription)"
            errorMessage = message
            pendingFailedMutation = FailedMutation(id: UUID(), mutation: mutation)
            return .failure(message)
        }

        // Fire-and-forget Tailscale push: never blocks or fails the local save above,
        // which has already succeeded by this point.
        let client = tailscaleClient
        Task { [weak self] in
            guard await client.isConfigured else { return }
            do {
                let remoteData = try await client.fetchCalendar()
                let remote = try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: remoteData)
                guard let self else { return }
                _ = try await self.store.merge(remote)
                let pushState = try await self.latestDurableSnapshotForPush()
                let data = try JSONEncoder.calendar.encode(pushState.snapshot)
                try await client.pushCalendar(data)
                await self.publishRemoteMerge(pushState.snapshot, startedAt: pushState.generation, remoteRevision: nil)
            } catch {
                // Local save already succeeded; a Tailscale hiccup here is non-fatal and silent by design.
            }
        }
        return .success
    }

    /// Pull-merge only, used when a remote change notification arrives over the WebSocket.
    private func pullMerge() async {
        let generation = durableGeneration
        do {
            let remoteData = try await tailscaleClient.fetchCalendar()
            let remote = try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: remoteData)
            let merged = try await store.merge(remote)
            await publishRemoteMerge(merged, startedAt: generation, remoteRevision: nil)
        } catch {
            // Tailscale sync is opt-in/best-effort; do not surface transient network errors as blocking UI state.
        }
    }

    /// Pull-merge-push cycle on demand (pull-to-refresh, Cmd+R).
    public func manualRefresh() async {
        guard await tailscaleClient.isConfigured else { return }
        do {
            let remoteData = try await tailscaleClient.fetchCalendar()
            let remote = try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: remoteData)
            _ = try await store.merge(remote)
            let pushState = try await latestDurableSnapshotForPush()
            let data = try JSONEncoder.calendar.encode(pushState.snapshot)
            try await tailscaleClient.pushCalendar(data)
            await publishRemoteMerge(pushState.snapshot, startedAt: pushState.generation, remoteRevision: nil)
        } catch {
            errorMessage = "Unable to sync with Tailscale: \(error.localizedDescription)"
        }
    }

    /// Re-reads after the remote merge, immediately before its PUT, so a
    /// local commit that completed while the network fetch was suspended is
    /// included in the payload and its generation is the one being tracked.
    private func latestDurableSnapshotForPush() async throws -> (snapshot: CalendarSnapshot, generation: UInt64) {
        for _ in 0..<8 {
            let generation = durableGeneration
            let latest = try await store.load()
            guard generation == durableGeneration else { continue }
            return (latest, generation)
        }
        throw SyncStateError.durableStateChangedDuringRead
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
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "LifeOS.Sync.LastSuccess")
        if pendingFailedMutation == nil { errorMessage = nil }
    }
}
