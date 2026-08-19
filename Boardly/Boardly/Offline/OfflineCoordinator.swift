import BoardlyKit
import SwiftUI

/// App-wide owner of the local-first machinery: the cache, the outbox and the sync loop.
///
/// One instance for the whole app (injected at the root, like `ProfileStore`), because the
/// SwiftData container and the connectivity monitor are process-level resources. Rows are
/// scoped per profile inside the store, so switching servers needs no new coordinator.
@Observable
@MainActor
final class OfflineCoordinator {
    /// `nil` only if SwiftData itself failed to open the store — the app then behaves
    /// exactly as it did before local-first: online-only, no queue.
    let store: OfflineStore?
    private let engine: SyncEngine?
    private let monitor = NetworkMonitor()

    /// Last known connectivity. Optimistic until the monitor reports otherwise, so the
    /// first request isn't queued just because the monitor hasn't started.
    var isOnline = true
    /// How many mutations are waiting for the server, for the "N pending" badge.
    var pendingCount = 0
    /// Set when the server refused queued work; the UI shows it once and clears it.
    var droppedNotice: SyncEngine.Notice?

    private var watching = false
    private var syncTask: Task<Void, Never>?
    /// How to build a client for the active profile, captured by `start` so an outcome
    /// reported from anywhere can kick a replay without threading a client through.
    private var clientFactory: (@Sendable () -> PlankaClient?)?
    private var activeProfileId: String?

    init() {
        do {
            let store = try OfflineStore(modelContainer: OfflineStore.makeContainer())
            self.store = store
            engine = SyncEngine(store: store)
        } catch {
            BoardlyLog.tag(.sync).icon("⚠️").error("Local store unavailable", error: error)
            store = nil
            engine = nil
        }
    }

    /// Starts watching connectivity for a profile and replays anything already queued.
    /// Safe to call repeatedly (on launch, on profile switch); it only wires up once.
    func start(profileId: String, client: @escaping @Sendable () -> PlankaClient?) {
        guard let engine, store != nil else { return }
        clientFactory = client
        activeProfileId = profileId
        Task { await refreshPendingCount(profileId: profileId) }

        guard !watching else { return }
        watching = true

        Task { [weak self] in
            for await notice in engine.noticeStream {
                guard let self else { return }
                switch notice {
                case .dropped:
                    droppedNotice = notice
                case let .boardNeedsRefresh(boardId):
                    NotificationCenter.default.post(
                        name: .boardNeedsRefresh, object: nil, userInfo: ["boardId": boardId])
                case .drained:
                    // Local ids have become real ones: open boards must refetch so they
                    // stop showing the placeholder rows.
                    NotificationCenter.default.post(name: .outboxDrained, object: nil)
                case .authenticationRequired:
                    break
                }
                await refreshPendingCount(profileId: profileId)
            }
        }

        Task { [weak self] in
            for await online in await monitor.changes {
                guard let self else { return }
                isOnline = online
                // Coming back online is the moment the queue can drain.
                if online { sync(profileId: profileId, client: client) }
            }
        }
    }

    /// A request just succeeded, so the network works whatever the path monitor thinks.
    /// `NWPathMonitor` is advisory — notably unreliable in the simulator, where the host's
    /// Wi-Fi can be off while the path still reads as satisfied — so an actual round trip
    /// is the better signal, and it also unblocks a queue that a missed transition stranded.
    func noteSuccess() {
        let wasOffline = !isOnline
        isOnline = true
        guard wasOffline || pendingCount > 0,
              let profileId = activeProfileId, let clientFactory else { return }
        sync(profileId: profileId, client: clientFactory)
    }

    /// A request failed in a way that means the server is unreachable — treat as offline so
    /// the next write is queued instead of thrown away.
    func noteFailure(_ error: Error) {
        switch error as? PlankaAPIError {
        case .networkError, .instanceUnreachable:
            isOnline = false
        default:
            break
        }
    }

    /// Replays the outbox and *waits* for the run to finish — what a pull-to-refresh
    /// needs, so the refetch that follows already reflects whatever the server accepted.
    /// Attempted even when the monitor says offline: reachability can be wrong, and the
    /// cost of being right is one failed request.
    func syncNow(profileId: String, client: PlankaClient) async {
        guard let engine else { return }
        await engine.sync(profileId: profileId, using: client)
        await refreshPendingCount(profileId: profileId)
    }

    /// Fire-and-forget replay — on reconnect and on foreground.
    func sync(profileId: String, client: @escaping @Sendable () -> PlankaClient?) {
        guard let engine, let plankaClient = client() else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await engine.sync(profileId: profileId, using: plankaClient)
            await self?.refreshPendingCount(profileId: profileId)
        }
    }

    func refreshPendingCount(profileId: String) async {
        guard let store else { return }
        pendingCount = (try? await store.pendingCount(profileId: profileId)) ?? 0
    }

    /// Forgets everything cached for a profile — call when its server is removed.
    func clear(profileId: String) async {
        try? await store?.clear(profileId: profileId)
        await refreshPendingCount(profileId: profileId)
    }
}

extension Notification.Name {
    /// Posted when the sync engine has dropped a refused mutation and the cached board
    /// needs to be refetched. `userInfo["boardId"]` names the board.
    static let boardNeedsRefresh = Notification.Name("dev.boardly.boardNeedsRefresh")

    /// Posted once every queued mutation for the profile has been accepted.
    static let outboxDrained = Notification.Name("dev.boardly.outboxDrained")
}
