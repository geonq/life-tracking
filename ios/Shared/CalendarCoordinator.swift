import Foundation
import Combine

@available(iOS 17.0, macOS 14.0, *)
@MainActor
public final class CalendarCoordinator: ObservableObject {
    @Published public private(set) var snapshot = CalendarSnapshot()
    @Published public private(set) var storageDescription = ""
    @Published public private(set) var syncStatus: CalendarPeerConnectionStatus = .stopped
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isLoaded = false

    public let store: CalendarStore
    public let senderID: String
    private var revision: Int
    private let peerSync: CalendarPeerSync
    private let tailscaleClient: TailscaleSyncClient

    public init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        initialSnapshot: CalendarSnapshot = CalendarSnapshot()
    ) {
        snapshot = initialSnapshot
        let group = bundle.object(forInfoDictionaryKey: "APP_GROUP_IDENTIFIER") as? String
        let selected: (URL, String) = {
            if let group, let url = try? CalendarStoreURL.appGroupURL(identifier: group, fileManager: fileManager) {
                return (url, "App Group")
            }
            let url = CalendarStoreURL.localURL(fileManager: fileManager)
            return (url, "Local Application Support (this app only)")
        }()
        store = CalendarStore(url: selected.0, fileManager: fileManager)
        storageDescription = selected.1
        let defaults = UserDefaults.standard
        let key = "LifeOS.Calendar.senderID"
        if let existing = defaults.string(forKey: key), !existing.isEmpty { senderID = existing }
        else { let value = UUID().uuidString; defaults.set(value, forKey: key); senderID = value }
        revision = defaults.integer(forKey: "LifeOS.Calendar.revision")
        peerSync = CalendarPeerSync(displayName: senderID)
        tailscaleClient = TailscaleSyncClient()
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
        do { snapshot = try await store.load(); isLoaded = true; errorMessage = nil }
        catch { errorMessage = "Unable to load calendar: \(error.localizedDescription)"; isLoaded = true }
    }

    public func startSync() { peerSync.start() }
    public func stopSync() { peerSync.stop() }

    public func save(_ item: CalendarItem) async {
        var next = snapshot
        if let index = next.items.firstIndex(where: { $0.id == item.id }) { next.items[index] = item } else { next.items.append(item) }
        await persist(next)
    }

    public func delete(_ item: CalendarItem) async {
        await save(item.deleting(at: .now))
    }

    private func merge(_ remote: CalendarSnapshot, remoteRevision: Int) async {
        do { snapshot = try await store.merge(remote); revision = max(revision, remoteRevision); UserDefaults.standard.set(revision, forKey: "LifeOS.Calendar.revision"); errorMessage = nil }
        catch { errorMessage = "Unable to merge calendar: \(error.localizedDescription)" }
    }

    private func persist(_ next: CalendarSnapshot) async {
        do {
            snapshot = try await store.save(next)
            revision += 1
            UserDefaults.standard.set(revision, forKey: "LifeOS.Calendar.revision")
            try peerSync.send(snapshot: snapshot, senderID: senderID, revision: revision)
            errorMessage = nil
        } catch { errorMessage = "Unable to save calendar: \(error.localizedDescription)" }

        // Fire-and-forget Tailscale push: never blocks or fails the local save above,
        // which has already succeeded by this point.
        let client = tailscaleClient
        Task { [weak self] in
            guard await client.isConfigured else { return }
            do {
                let remoteData = try await client.fetchCalendar()
                let remote = try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: remoteData)
                let merged = try await self?.store.merge(remote)
                if let merged {
                    let data = try JSONEncoder.calendar.encode(merged)
                    try await client.pushCalendar(data)
                    await MainActor.run { self?.snapshot = merged; UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "LifeOS.Sync.LastSuccess") }
                }
            } catch {
                // Local save already succeeded; a Tailscale hiccup here is non-fatal and silent by design.
            }
        }
    }

    /// Pull-merge only, used when a remote change notification arrives over the WebSocket.
    private func pullMerge() async {
        do {
            let remoteData = try await tailscaleClient.fetchCalendar()
            let remote = try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: remoteData)
            snapshot = try await store.merge(remote)
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "LifeOS.Sync.LastSuccess")
            errorMessage = nil
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
            let merged = try await store.merge(remote)
            let data = try JSONEncoder.calendar.encode(merged)
            try await tailscaleClient.pushCalendar(data)
            snapshot = merged
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "LifeOS.Sync.LastSuccess")
            errorMessage = nil
        } catch {
            errorMessage = "Unable to sync with Tailscale: \(error.localizedDescription)"
        }
    }
}
