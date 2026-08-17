import Foundation
import Testing
@testable import BoardlyKit

/// The local-first cache: snapshot round-trip, pruning, dirty protection and the outbox.
@Suite("OfflineStore")
struct OfflineStoreTests {
    private func makeStore() throws -> OfflineStore {
        OfflineStore(modelContainer: try OfflineStore.makeInMemoryContainer())
    }

    /// Board payloads come from JSON, the way the app receives them — hand-building the
    /// models would pin the test to every field the API adds.
    private func payload(
        cards: [(id: String, listId: String, name: String)] = [("c1", "l1", "Card one")],
        tasks: [(id: String, name: String, done: Bool)] = [("t1", "Task one", false)],
        boardName: String = "Board") throws -> BoardPayload
    {
        let cardsJSON = cards.map {
            """
            { "id": "\($0.id)", "boardId": "b1", "listId": "\($0.listId)", "type": "project",
              "position": 65536, "name": "\($0.name)", "createdAt": "2024-01-01T10:00:00.000Z" }
            """
        }.joined(separator: ",")
        let tasksJSON = tasks.map {
            """
            { "id": "\($0.id)", "taskListId": "tl1", "position": 0, "name": "\($0.name)",
              "isCompleted": \($0.done) }
            """
        }.joined(separator: ",")
        let json = """
        {
          "item": {
            "id": "b1", "projectId": "p1", "position": 0, "name": "\(boardName)",
            "defaultCardType": "project"
          },
          "included": {
            "lists": [
              { "id": "l1", "boardId": "b1", "type": "active", "position": 0, "name": "Inbox" },
              { "id": "l2", "boardId": "b1", "type": "active", "position": 1, "name": "Done" }
            ],
            "cards": [\(cardsJSON)],
            "taskLists": [{ "id": "tl1", "cardId": "c1", "position": 0, "name": "Checklist" }],
            "tasks": [\(tasksJSON)],
            "labels": [
              { "id": "lb1", "boardId": "b1", "position": 0, "name": "Urgent", "color": "berry-red" }
            ],
            "cardLabels": [{ "id": "cl1", "cardId": "c1", "labelId": "lb1" }],
            "cardMemberships": [],
            "users": [{ "id": "u1", "email": "a@b.c", "role": "projectOwner", "name": "Dima",
                        "username": "dima", "isDeactivated": false }]
          }
        }
        """
        return try BoardPayload.decode(from: Data(json.utf8))
    }

    // MARK: - Snapshot

    @Test("a cached board comes back as the same payload")
    func roundTrip() async throws {
        let store = try makeStore()
        try await store.cache(try payload(), profileId: "prof")

        let restored = try #require(try await store.payload(boardId: "b1", profileId: "prof"))
        #expect(restored.board.name == "Board")
        #expect(restored.sortedLists().map(\.id) == ["l1", "l2"])
        #expect(restored.cards.map(\.id) == ["c1"])
        #expect(restored.tasks.map(\.name) == ["Task one"])
        #expect(restored.labels.map(\.name) == ["Urgent"])
        #expect(restored.cardLabels.count == 1)
        #expect(restored.users.map(\.name) == ["Dima"])
    }

    @Test("a board this profile never opened is nil")
    func missingBoard() async throws {
        let store = try makeStore()
        #expect(try await store.payload(boardId: "nope", profileId: "prof") == nil)
    }

    @Test("the same board id on two profiles stays separate")
    func profileScoping() async throws {
        let store = try makeStore()
        try await store.cache(try payload(boardName: "Mine"), profileId: "prof-a")
        try await store.cache(try payload(boardName: "Theirs"), profileId: "prof-b")

        let a = try #require(try await store.payload(boardId: "b1", profileId: "prof-a"))
        let b = try #require(try await store.payload(boardId: "b1", profileId: "prof-b"))
        #expect(a.board.name == "Mine")
        #expect(b.board.name == "Theirs")
    }

    @Test("re-caching prunes rows the server no longer sends")
    func pruning() async throws {
        let store = try makeStore()
        try await store.cache(
            try payload(cards: [("c1", "l1", "One"), ("c2", "l1", "Two")]), profileId: "prof")
        try await store.cache(try payload(cards: [("c1", "l1", "One")]), profileId: "prof")

        let restored = try #require(try await store.payload(boardId: "b1", profileId: "prof"))
        #expect(restored.cards.map(\.id) == ["c1"])
    }

    @Test("a card with unsynced edits survives a server refresh")
    func dirtyRowsSurviveRefresh() async throws {
        let store = try makeStore()
        try await store.cache(try payload(), profileId: "prof")
        try await store.enqueue(
            .updateCard(CardEdit(name: "Renamed offline")),
            targetId: "c1", boardId: "b1", profileId: "prof")

        // The server still reports the old name, and doesn't know about the rename.
        try await store.cache(try payload(cards: [("c1", "l1", "Card one")]), profileId: "prof")

        let restored = try #require(try await store.payload(boardId: "b1", profileId: "prof"))
        #expect(restored.cards.first?.name == "Renamed offline")
    }

    @Test("a card created offline isn't pruned by a refresh that predates it")
    func localCardSurvivesRefresh() async throws {
        let store = try makeStore()
        try await store.cache(try payload(), profileId: "prof")
        let localId = try await store.enqueue(
            .createCard(listId: "l1", name: "Offline card", position: 131_072, type: "project"),
            targetId: "", boardId: "b1", profileId: "prof")

        try await store.cache(try payload(), profileId: "prof")

        let restored = try #require(try await store.payload(boardId: "b1", profileId: "prof"))
        #expect(restored.cards.map(\.id).contains(localId))
        #expect(LocalID.isLocal(localId))
    }

    // MARK: - Optimistic apply

    @Test("queuing an edit applies it to the cache immediately")
    func optimisticEdit() async throws {
        let store = try makeStore()
        try await store.cache(try payload(), profileId: "prof")
        try await store.enqueue(
            .updateCard(CardEdit(name: "New name", listId: "l2")),
            targetId: "c1", boardId: "b1", profileId: "prof")

        let card = try #require(try await store.payload(boardId: "b1", profileId: "prof")?.cards.first)
        #expect(card.name == "New name")
        #expect(card.listId == "l2")
        #expect(try await store.dirtyIds(boardId: "b1", profileId: "prof").contains("c1"))
    }

    @Test("clearing a due date offline removes it, rather than leaving the old one")
    func optimisticClearDueDate() async throws {
        let store = try makeStore()
        try await store.cache(try payload(), profileId: "prof")
        try await store.enqueue(
            .updateCard(CardEdit(dueDate: Date(timeIntervalSince1970: 1000))),
            targetId: "c1", boardId: "b1", profileId: "prof")
        try await store.enqueue(
            .updateCard(CardEdit(clearDueDate: true)),
            targetId: "c1", boardId: "b1", profileId: "prof")

        let card = try #require(try await store.payload(boardId: "b1", profileId: "prof")?.cards.first)
        #expect(card.dueDate == nil)
    }

    @Test("toggling a task offline flips it in the cache")
    func optimisticTaskToggle() async throws {
        let store = try makeStore()
        try await store.cache(try payload(), profileId: "prof")
        try await store.enqueue(
            .updateTask(TaskEdit(isCompleted: true)),
            targetId: "t1", boardId: "b1", profileId: "prof")

        let task = try #require(try await store.payload(boardId: "b1", profileId: "prof")?.tasks.first)
        #expect(task.isCompleted)
    }

    @Test("deleting a card offline removes it from the cache")
    func optimisticDelete() async throws {
        let store = try makeStore()
        try await store.cache(try payload(), profileId: "prof")
        try await store.enqueue(.deleteCard, targetId: "c1", boardId: "b1", profileId: "prof")

        let restored = try #require(try await store.payload(boardId: "b1", profileId: "prof"))
        #expect(restored.cards.isEmpty)
    }

    // MARK: - Outbox

    @Test("the queue replays oldest first")
    func queueOrder() async throws {
        let store = try makeStore()
        try await store.cache(try payload(), profileId: "prof")
        try await store.enqueue(
            .updateCard(CardEdit(name: "first")), targetId: "c1", boardId: "b1",
            profileId: "prof", now: Date(timeIntervalSince1970: 10))
        try await store.enqueue(
            .updateCard(CardEdit(name: "second")), targetId: "c1", boardId: "b1",
            profileId: "prof", now: Date(timeIntervalSince1970: 5))

        let queue = try await store.pending(profileId: "prof")
        #expect(queue.map(\.payload) == [
            .updateCard(CardEdit(name: "second")),
            .updateCard(CardEdit(name: "first")),
        ])
    }

    @Test("the queue is per profile")
    func queueScoping() async throws {
        let store = try makeStore()
        try await store.cache(try payload(), profileId: "prof-a")
        try await store.enqueue(.deleteCard, targetId: "c1", boardId: "b1", profileId: "prof-a")

        #expect(try await store.pendingCount(profileId: "prof-a") == 1)
        #expect(try await store.pendingCount(profileId: "prof-b") == 0)
    }

    @Test("resolving the last mutation clears the dirty mark")
    func resolveClearsDirty() async throws {
        let store = try makeStore()
        try await store.cache(try payload(), profileId: "prof")
        try await store.enqueue(
            .updateCard(CardEdit(name: "One")), targetId: "c1", boardId: "b1", profileId: "prof")
        try await store.enqueue(
            .updateCard(CardEdit(name: "Two")), targetId: "c1", boardId: "b1", profileId: "prof")

        let queue = try await store.pending(profileId: "prof")
        try await store.resolve(queue[0].id)
        // Still one queued edit for that card, so it stays dirty.
        #expect(try await store.dirtyIds(boardId: "b1", profileId: "prof").contains("c1"))

        try await store.resolve(queue[1].id)
        #expect(try await store.dirtyIds(boardId: "b1", profileId: "prof").isEmpty)
    }

    @Test("a deferred mutation keeps its place and counts the attempt")
    func recordFailure() async throws {
        let store = try makeStore()
        try await store.cache(try payload(), profileId: "prof")
        try await store.enqueue(.deleteCard, targetId: "c1", boardId: "b1", profileId: "prof")
        let id = try #require(try await store.pending(profileId: "prof").first?.id)

        try await store.recordFailure(id, error: "offline")
        let entry = try #require(try await store.pending(profileId: "prof").first)
        #expect(entry.attempts == 1)
        #expect(entry.lastError == "offline")
    }

    @Test("remapping a local id rewrites the cache and later queued work")
    func remap() async throws {
        let store = try makeStore()
        try await store.cache(try payload(), profileId: "prof")
        let localId = try await store.enqueue(
            .createCard(listId: "l1", name: "Offline", position: 1, type: "project"),
            targetId: "", boardId: "b1", profileId: "prof")
        try await store.enqueue(
            .updateCard(CardEdit(name: "Renamed")), targetId: localId, boardId: "b1", profileId: "prof")
        try await store.enqueue(
            .createComment(cardId: localId, text: "Note"),
            targetId: localId, boardId: "b1", profileId: "prof")

        try await store.remap(localId: localId, to: "server-1", profileId: "prof")

        let cards = try #require(try await store.payload(boardId: "b1", profileId: "prof")?.cards)
        #expect(cards.contains { $0.id == "server-1" })
        #expect(!cards.contains { LocalID.isLocal($0.id) })

        let queue = try await store.pending(profileId: "prof")
        // The card's local id is gone from the queue; the queued comment keeps its own
        // local id (it is a create in its own right) but now names the real card.
        #expect(!queue.contains { $0.targetId == localId })
        #expect(queue.contains { $0.payload == .createComment(cardId: "server-1", text: "Note") })
        #expect(try await store.comments(cardId: "server-1", profileId: "prof").map(\.text) == ["Note"])
    }

    @Test("clearing a profile leaves other profiles intact")
    func clearProfile() async throws {
        let store = try makeStore()
        try await store.cache(try payload(), profileId: "prof-a")
        try await store.cache(try payload(), profileId: "prof-b")
        try await store.enqueue(.deleteCard, targetId: "c1", boardId: "b1", profileId: "prof-a")

        try await store.clear(profileId: "prof-a")

        #expect(try await store.payload(boardId: "b1", profileId: "prof-a") == nil)
        #expect(try await store.pendingCount(profileId: "prof-a") == 0)
        #expect(try await store.payload(boardId: "b1", profileId: "prof-b") != nil)
    }

    // MARK: - Comments

    @Test("comments round-trip, and one posted offline survives a server refresh")
    func commentCache() async throws {
        let store = try makeStore()
        try await store.cache(try payload(), profileId: "prof")
        let server = Comment(
            id: "cm1", cardId: "c1", userId: "u1", text: "From server",
            createdAt: Date(timeIntervalSince1970: 100), updatedAt: nil)
        try await store.cache(comments: [server], cardId: "c1", boardId: "b1", profileId: "prof")
        try await store.enqueue(
            .createComment(cardId: "c1", text: "Posted offline"),
            targetId: "c1", boardId: "b1", profileId: "prof",
            now: Date(timeIntervalSince1970: 200))

        // A refresh that predates the local post must not delete it.
        try await store.cache(comments: [server], cardId: "c1", boardId: "b1", profileId: "prof")

        let texts = try await store.comments(cardId: "c1", profileId: "prof").map(\.text)
        #expect(texts == ["From server", "Posted offline"])
    }

    // MARK: - Projects list

    /// `getProjects` decodes its payload inline in the client, so the test builds the
    /// value type from decoded entities rather than from a response envelope.
    private func projectsPayload() throws -> ProjectsPayload {
        let decoder = JSONDecoder.planka
        let project = try decoder.decode(
            Project.self,
            from: Data(#"{ "id": "p1", "name": "BOT", "isHidden": false }"#.utf8))
        let boards = try decoder.decode([Board].self, from: Data("""
        [{ "id": "b1", "projectId": "p1", "position": 0, "name": "Backlog" },
         { "id": "b2", "projectId": "p1", "position": 1, "name": "Done" }]
        """.utf8))
        return ProjectsPayload(projects: [project], boards: boards)
    }

    @Test("the projects list round-trips, so boards are listable offline")
    func projectsRoundTrip() async throws {
        let store = try makeStore()
        try await store.cache(projects: try projectsPayload(), profileId: "prof")

        let restored = try #require(try await store.projects(profileId: "prof"))
        #expect(restored.projects.map(\.name) == ["BOT"])
        #expect(restored.boards.map(\.name) == ["Backlog", "Done"])
        #expect(try await store.projectsCachedAt(profileId: "prof") != nil)
    }

    @Test("a cached projects list is scoped per profile")
    func projectsScoping() async throws {
        let store = try makeStore()
        try await store.cache(projects: try projectsPayload(), profileId: "prof-a")
        #expect(try await store.projects(profileId: "prof-b") == nil)
    }

    @Test("a board's card count comes from the cache, and is nil when never cached")
    func cachedCardCount() async throws {
        let store = try makeStore()
        try await store.cache(try payload(cards: [("c1", "l1", "One"), ("c2", "l1", "Two")]),
                              profileId: "prof")

        #expect(try await store.cardCount(boardId: "b1", profileId: "prof") == 2)
        #expect(try await store.cardCount(boardId: "unknown", profileId: "prof") == nil)
    }

    @Test("cached board ids let a prefetch skip what it already has")
    func cachedBoardIds() async throws {
        let store = try makeStore()
        try await store.cache(try payload(), profileId: "prof")
        #expect(try await store.cachedBoardIds(profileId: "prof") == ["b1"])
        #expect(try await store.cachedBoardIds(profileId: "other").isEmpty)
    }
}
