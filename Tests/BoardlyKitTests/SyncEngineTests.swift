import Foundation
import Testing
@testable import BoardlyKit

/// Replay policy: accepted entries clear, refused entries are dropped and the board is
/// flagged, deferred entries stay put and stop the run so order is preserved.
@Suite("SyncEngine")
struct SyncEngineTests {
    private let profile: ServerProfile
    private var profileId: String { profile.id.uuidString }
    private let mockHTTP: MockHTTPClient
    private let client: PlankaClient

    init() {
        profile = makeProfile(baseURL: URL(string: "https://planka.example.com")!)
        mockHTTP = MockHTTPClient()
        client = PlankaClient(
            profile: profile,
            tokenStore: TokenStore(profileID: profile.id, keychainStore: MockKeychainStore()),
            httpClient: mockHTTP)
    }

    private func makeStore() throws -> OfflineStore {
        OfflineStore(modelContainer: try OfflineStore.makeInMemoryContainer())
    }

    private func cardJSON(id: String, name: String = "Card") -> String {
        """
        { "item": { "id": "\(id)", "boardId": "b1", "listId": "l1", "type": "project",
          "position": 65536, "name": "\(name)" } }
        """
    }

    private func taskJSON(id: String) -> String {
        """
        { "item": { "id": "\(id)", "taskListId": "tl1", "position": 0, "name": "Task",
          "isCompleted": false } }
        """
    }

    private func errorResponse(_ code: String) -> String { #"{"code":"\#(code)"}"# }

    /// Reads the next `count` notices already buffered on the stream.
    private func notices(_ engine: SyncEngine, count: Int) async -> [SyncEngine.Notice] {
        var iterator = engine.noticeStream.makeAsyncIterator()
        var collected: [SyncEngine.Notice] = []
        for _ in 0 ..< count {
            guard let notice = await iterator.next() else { break }
            collected.append(notice)
        }
        return collected
    }

    // MARK: - Accepted

    @Test("an accepted queue drains and the local id becomes the server's")
    func drainsQueue() async throws {
        let store = try makeStore()
        let engine = SyncEngine(store: store)
        let localId = try await store.enqueue(
            .createCard(listId: "l1", name: "Offline", position: 65536, type: "project"),
            targetId: "", boardId: "b1", profileId: profileId)
        try await store.enqueue(
            .updateCard(CardEdit(name: "Renamed")),
            targetId: localId, boardId: "b1", profileId: profileId)

        mockHTTP.handler = { [self] _, index in
            index == 0 ? mockHTTP.response(json: cardJSON(id: "srv-1"))
                : mockHTTP.response(json: cardJSON(id: "srv-1", name: "Renamed"))
        }

        let result = await engine.sync(profileId: profileId, using: client)

        #expect(result == SyncEngine.Result(accepted: 2, dropped: 0, deferred: 0))
        #expect(try await store.pendingCount(profileId: profileId) == 0)
        // The rename went to the real id, not "local:…".
        #expect(mockHTTP.requests[1].url?.path.hasSuffix("/api/cards/srv-1") == true)
        #expect(await notices(engine, count: 1) == [.drained])
    }

    @Test("mutations replay oldest first")
    func replayOrder() async throws {
        let store = try makeStore()
        let engine = SyncEngine(store: store)
        try await store.enqueue(
            .createComment(cardId: "c1", text: "second"), targetId: "c1", boardId: "b1",
            profileId: profileId, now: Date(timeIntervalSince1970: 200))
        try await store.enqueue(
            .createComment(cardId: "c1", text: "first"), targetId: "c1", boardId: "b1",
            profileId: profileId, now: Date(timeIntervalSince1970: 100))

        mockHTTP.handler = { [self] _, index in
            mockHTTP.response(json: """
            { "item": { "id": "cm\(index)", "cardId": "c1", "text": "x" } }
            """)
        }

        _ = await engine.sync(profileId: profileId, using: client)

        let bodies = mockHTTP.requests.compactMap { $0.httpBody }.map { String(decoding: $0, as: UTF8.self) }
        #expect(bodies.count == 2)
        #expect(bodies[0].contains("first"))
        #expect(bodies[1].contains("second"))
    }

    // MARK: - Refused

    @Test("a conflict drops the entry and asks for a board refresh")
    func conflictDropsEntry() async throws {
        let store = try makeStore()
        let engine = SyncEngine(store: store)
        try await store.enqueue(
            .updateCard(CardEdit(name: "Renamed")),
            targetId: "c1", boardId: "b1", profileId: profileId)

        mockHTTP.handler = { [self] _, _ in
            mockHTTP.response(json: errorResponse("E_CONFLICT"), statusCode: 409)
        }

        let result = await engine.sync(profileId: profileId, using: client)

        #expect(result == SyncEngine.Result(accepted: 0, dropped: 1, deferred: 0))
        #expect(try await store.pendingCount(profileId: profileId) == 0)
        #expect(await notices(engine, count: 2) == [
            .dropped(kind: .updateCard, boardId: "b1", reason: .conflict),
            .boardNeedsRefresh(boardId: "b1"),
        ])
    }

    @Test("invalid params are refused too, rather than retried forever")
    func invalidParamsDropEntry() async throws {
        let store = try makeStore()
        let engine = SyncEngine(store: store)
        try await store.enqueue(.deleteCard, targetId: "c1", boardId: "b1", profileId: profileId)

        mockHTTP.handler = { [self] _, _ in
            mockHTTP.response(json: errorResponse("E_MISSING_OR_INVALID_PARAMS"), statusCode: 422)
        }

        let result = await engine.sync(profileId: profileId, using: client)
        #expect(result.dropped == 1)
        #expect(try await store.pendingCount(profileId: profileId) == 0)
    }

    // MARK: - Deferred

    @Test("a network failure keeps the entry and stops the run")
    func networkFailureStopsRun() async throws {
        let store = try makeStore()
        let engine = SyncEngine(store: store)
        try await store.enqueue(
            .updateCard(CardEdit(name: "One")), targetId: "c1", boardId: "b1",
            profileId: profileId, now: Date(timeIntervalSince1970: 100))
        try await store.enqueue(
            .updateCard(CardEdit(name: "Two")), targetId: "c2", boardId: "b1",
            profileId: profileId, now: Date(timeIntervalSince1970: 200))

        mockHTTP.stubbedError = URLError(.notConnectedToInternet)

        let result = await engine.sync(profileId: profileId, using: client)

        #expect(result == SyncEngine.Result(accepted: 0, dropped: 0, deferred: 1))
        // Both entries still queued, and the second was never attempted.
        #expect(try await store.pendingCount(profileId: profileId) == 2)
        #expect(mockHTTP.requests.count == 1)
        let first = try #require(try await store.pending(profileId: profileId).first)
        #expect(first.attempts == 1)
        #expect(first.lastError != nil)
    }

    @Test("a 5xx is deferred, not dropped — the mutation is still valid")
    func serverErrorDefers() async throws {
        let store = try makeStore()
        let engine = SyncEngine(store: store)
        try await store.enqueue(.deleteCard, targetId: "c1", boardId: "b1", profileId: profileId)

        mockHTTP.handler = { [self] _, _ in mockHTTP.response(json: "{}", statusCode: 503) }

        let result = await engine.sync(profileId: profileId, using: client)
        #expect(result.deferred == 1)
        #expect(try await store.pendingCount(profileId: profileId) == 1)
    }

    @Test("an expired session stops the run with the queue intact")
    func unauthorizedKeepsQueue() async throws {
        let store = try makeStore()
        let engine = SyncEngine(store: store)
        try await store.enqueue(.deleteCard, targetId: "c1", boardId: "b1", profileId: profileId)

        mockHTTP.handler = { [self] _, _ in
            mockHTTP.response(json: errorResponse("E_UNAUTHORIZED"), statusCode: 401)
        }

        let result = await engine.sync(profileId: profileId, using: client)

        #expect(result.deferred == 1)
        #expect(try await store.pendingCount(profileId: profileId) == 1)
        #expect(await notices(engine, count: 1) == [.authenticationRequired])
    }

    @Test("work queued against a create that hasn't landed waits for the next run")
    func waitsForUnresolvedLocalId() async throws {
        let store = try makeStore()
        let engine = SyncEngine(store: store)
        // An edit whose target is still a local id, with no create ahead of it — the
        // create failed on an earlier run. Sending "local:…" to the server must not happen.
        try await store.enqueue(
            .updateCard(CardEdit(name: "Renamed")),
            targetId: LocalID.make(), boardId: "b1", profileId: profileId)

        let result = await engine.sync(profileId: profileId, using: client)

        #expect(result == SyncEngine.Result(accepted: 0, dropped: 0, deferred: 1))
        #expect(mockHTTP.requests.isEmpty)
        #expect(try await store.pendingCount(profileId: profileId) == 1)
    }

    @Test("an empty queue is a no-op")
    func emptyQueue() async throws {
        let store = try makeStore()
        let engine = SyncEngine(store: store)
        let result = await engine.sync(profileId: profileId, using: client)
        #expect(result == SyncEngine.Result())
        #expect(mockHTTP.requests.isEmpty)
    }

    @Test("a queued task create is replayed and remapped")
    func taskCreateRemapped() async throws {
        let store = try makeStore()
        let engine = SyncEngine(store: store)
        let localId = try await store.enqueue(
            .createTask(taskListId: "tl1", name: "Task", position: 0),
            targetId: "", boardId: "b1", profileId: profileId)
        try await store.enqueue(
            .updateTask(TaskEdit(isCompleted: true)),
            targetId: localId, boardId: "b1", profileId: profileId)

        mockHTTP.handler = { [self] _, index in
            index == 0 ? mockHTTP.response(json: taskJSON(id: "srv-t1"))
                : mockHTTP.response(json: taskJSON(id: "srv-t1"))
        }

        let result = await engine.sync(profileId: profileId, using: client)
        #expect(result.accepted == 2)
        #expect(mockHTTP.requests[1].url?.path.hasSuffix("/api/tasks/srv-t1") == true)
    }
}
