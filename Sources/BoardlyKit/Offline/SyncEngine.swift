import Foundation

/// Replays the outbox against the server, oldest mutation first.
///
/// Outcome policy (one decision, applied everywhere):
/// - **accepted** → the entry is removed and its dirty marks cleared.
/// - **refused** (`409` conflict, `422` invalid params, `404`, `403`) → the entry is
///   dropped, the board is flagged for a refetch, and a notice names what was lost. The
///   server is the authority on its own state; retrying a refusal would just loop.
/// - **deferred** (network error, `5xx`) → the entry stays with its attempt count
///   incremented, and the run stops so later mutations can't overtake it.
///
/// A `401` stops the run without dropping anything: the token needs refreshing, and the
/// queued work is still valid once the user logs back in.
public actor SyncEngine {
    public enum Notice: Sendable, Equatable {
        /// The server refused this mutation; the local change was rolled back by refetch.
        case dropped(kind: MutationKind, boardId: String, reason: PlankaAPIError)
        /// The cached board diverged from the server and should be refetched.
        case boardNeedsRefresh(boardId: String)
        /// Every queued mutation for the profile has been accepted.
        case drained
        /// The session expired mid-replay; the queue is intact.
        case authenticationRequired
    }

    /// Summary of one replay run, for logging and tests.
    public struct Result: Sendable, Equatable {
        public var accepted = 0
        public var dropped = 0
        public var deferred = 0
    }

    private let store: OfflineStore
    private let notices: AsyncStream<Notice>.Continuation
    /// Notices for the app to surface — one stream per engine. `nonisolated`, so a
    /// consumer can start iterating without awaiting the actor.
    public nonisolated let noticeStream: AsyncStream<Notice>
    private var running = false

    public init(store: OfflineStore) {
        self.store = store
        (noticeStream, notices) = AsyncStream.makeStream()
    }

    /// Replays everything queued for a profile. Re-entrant calls are ignored, so a
    /// connectivity change arriving mid-run can't start a second replay of the same queue.
    @discardableResult
    public func sync(profileId: String, using client: PlankaClient) async -> Result {
        guard !running else { return Result() }
        running = true
        defer { running = false }

        var result = Result()
        var boardsToRefresh: Set<String> = []

        let queue: [QueuedMutation]
        do {
            queue = try await store.pending(profileId: profileId)
        } catch {
            BoardlyLog.tag(.sync).icon("⚠️").error("Couldn't read the outbox", error: error)
            return result
        }
        guard !queue.isEmpty else { return result }

        BoardlyLog.tag(.sync).icon("🔁").info("Replaying outbox", metadata: ["count": queue.count])

        // The queue is read once, but a create replayed inside this run gives its entity a
        // real id. Later entries were snapshotted with the local one, so they are
        // translated here — the store is updated too, for the next run.
        var remapped: [String: String] = [:]

        for mutation in queue {
            let targetId = remapped[mutation.targetId] ?? mutation.targetId

            // Still addressed to a local id means the create it depends on never landed:
            // wait for a later run rather than sending "local:…" to the server.
            if isUnresolved(mutation, targetId: targetId, remapped: remapped) {
                result.deferred += 1
                break
            }

            do {
                if let mapping = try await apply(
                    mutation, targetId: targetId, remapped: remapped, using: client)
                {
                    remapped[mapping.local] = mapping.server
                }
                try? await store.resolve(mutation.id)
                result.accepted += 1
            } catch let error as PlankaAPIError {
                switch error {
                case .unauthorized:
                    notices.yield(.authenticationRequired)
                    result.deferred += 1
                    return result

                case .conflict, .invalidParams, .notFound, .forbidden:
                    try? await store.drop(mutation.id)
                    boardsToRefresh.insert(mutation.boardId)
                    notices.yield(.dropped(
                        kind: mutation.kind, boardId: mutation.boardId, reason: error))
                    result.dropped += 1
                    BoardlyLog.tag(.sync).icon("🚫").warning(
                        "Server refused a queued mutation",
                        metadata: ["kind": mutation.kind.rawValue, "board": mutation.boardId])

                default:
                    try? await store.recordFailure(mutation.id, error: error.localizedDescription)
                    result.deferred += 1
                    // Stop the run: later entries may depend on this one.
                    for boardId in boardsToRefresh { notices.yield(.boardNeedsRefresh(boardId: boardId)) }
                    return result
                }
            } catch {
                try? await store.recordFailure(mutation.id, error: error.localizedDescription)
                result.deferred += 1
                for boardId in boardsToRefresh { notices.yield(.boardNeedsRefresh(boardId: boardId)) }
                return result
            }
        }

        for boardId in boardsToRefresh { notices.yield(.boardNeedsRefresh(boardId: boardId)) }
        if result.deferred == 0, (try? await store.pendingCount(profileId: profileId)) == 0 {
            notices.yield(.drained)
        }
        BoardlyLog.tag(.sync).icon("✅").info("Outbox run finished", metadata: [
            "accepted": result.accepted, "dropped": result.dropped, "deferred": result.deferred,
        ])
        return result
    }

    /// Whether the mutation still points at something the server has never seen.
    private func isUnresolved(
        _ mutation: QueuedMutation,
        targetId: String,
        remapped: [String: String]) -> Bool
    {
        switch mutation.payload {
        // A create mints its own id, so its local `targetId` is expected.
        case .createCard, .createTask:
            false
        // A comment's own id is local; what matters is the card it belongs to.
        case let .createComment(cardId, _):
            LocalID.isLocal(remapped[cardId] ?? cardId)
        default:
            LocalID.isLocal(targetId)
        }
    }

    /// Sends one queued mutation. For a create, returns the local→server id mapping so
    /// the rest of the run (and the store) can follow the entity to its real id.
    private func apply(
        _ mutation: QueuedMutation,
        targetId: String,
        remapped: [String: String],
        using client: PlankaClient) async throws -> (local: String, server: String)?
    {
        switch mutation.payload {
        case let .createCard(listId, name, position, type):
            let card = try await client.createCard(
                listId: listId, name: name, position: position, type: type)
            try await store.remap(localId: targetId, to: card.id, profileId: mutation.profileId)
            return (targetId, card.id)

        case let .updateCard(edit):
            _ = try await client.updateCard(id: targetId, patch: edit.patch)
            return nil

        case .deleteCard:
            _ = try await client.deleteCard(id: targetId)
            return nil

        case let .createTask(taskListId, name, position):
            let task = try await client.createTask(
                taskListId: taskListId, name: name, position: position)
            try await store.remap(localId: targetId, to: task.id, profileId: mutation.profileId)
            return (targetId, task.id)

        case let .updateTask(edit):
            _ = try await client.updateTask(id: targetId, patch: edit.patch)
            return nil

        case .deleteTask:
            _ = try await client.deleteTask(id: targetId)
            return nil

        case let .createComment(cardId, text):
            let comment = try await client.createComment(
                cardId: remapped[cardId] ?? cardId, text: text)
            try await store.remap(localId: targetId, to: comment.id, profileId: mutation.profileId)
            return (targetId, comment.id)
        }
    }
}
