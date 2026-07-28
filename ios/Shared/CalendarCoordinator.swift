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

    public init(bundle: Bundle = .main, fileManager: FileManager = .default) {
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
        peerSync.onStatusChanged = { [weak self] status in
            Task { @MainActor in self?.syncStatus = status }
        }
        peerSync.onSnapshotReceived = { [weak self] envelope, _ in
            Task { @MainActor in await self?.merge(envelope.snapshot, remoteRevision: envelope.revision) }
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
    }
}
