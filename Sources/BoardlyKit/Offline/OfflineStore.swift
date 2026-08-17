import Foundation
import SwiftData

/// The local-first store: a SwiftData cache of the boards the user has opened, plus the
/// outbox of mutations waiting to reach the server.
///
/// A `@ModelActor`, so reads and writes happen off the main actor and `@Model` instances
/// never escape their context — the API hands back the same `Codable` value types the
/// rest of the app already uses (`BoardPayload`, `Comment`, `QueuedMutation`).
@ModelActor
public actor OfflineStore {
    /// On-disk container. One store serves every profile; rows carry their `profileId`.
    public static func makeContainer(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(cachedModels)
        let configuration = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// In-memory container for tests and previews.
    public static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(cachedModels)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    /// Paired with `JSONDecoder.planka` — see the encoder's own note on why.
    private var encoder: JSONEncoder { .planka }
    private var decoder: JSONDecoder { .planka }

    // MARK: - Board snapshot

    /// Replaces the cached copy of a board with what the server returned. Rows the
    /// payload no longer contains are pruned, so a card deleted on another device stops
    /// appearing offline — except rows still carrying unsynced work, which are the
    /// user's and are left alone until their queued mutation resolves.
    public func cache(_ payload: BoardPayload, profileId: String) throws {
        let boardId = payload.board.id

        let extras = BoardExtras(
            attachments: payload.attachments,
            boardMemberships: payload.boardMemberships,
            customFieldGroups: payload.customFieldGroups,
            customFields: payload.customFields,
            customFieldValues: payload.customFieldValues)
        let boardJSON = try encoder.encode(payload.board)
        let extrasJSON = try encoder.encode(extras)

        if let existing = try boardRow(boardId, profileId) {
            existing.json = boardJSON
            existing.extrasJSON = extrasJSON
            existing.cachedAt = Date()
        } else {
            modelContext.insert(CachedBoard(
                profileId: profileId, boardId: boardId,
                json: boardJSON, extrasJSON: extrasJSON, cachedAt: Date()))
        }

        // Lists
        var listRows = Dictionary(uniqueKeysWithValues: try listRows(boardId, profileId).map { ($0.listId, $0) })
        for list in payload.lists {
            let json = try encoder.encode(list)
            if let row = listRows.removeValue(forKey: list.id) {
                row.json = json
            } else {
                modelContext.insert(CachedList(
                    profileId: profileId, boardId: boardId, listId: list.id, json: json))
            }
        }
        listRows.values.forEach(modelContext.delete)

        // Cards — dirty / local-only rows survive both update and prune.
        var cardRows = Dictionary(uniqueKeysWithValues: try cardRows(boardId, profileId).map { ($0.cardId, $0) })
        for card in payload.cards {
            let json = try encoder.encode(card)
            if let row = cardRows.removeValue(forKey: card.id) {
                guard !row.isDirty, !row.isLocalOnly else { continue }
                row.json = json
                row.listId = card.listId
            } else {
                modelContext.insert(CachedCard(
                    profileId: profileId, boardId: boardId, listId: card.listId,
                    cardId: card.id, json: json))
            }
        }
        for row in cardRows.values where !row.isDirty && !row.isLocalOnly {
            modelContext.delete(row)
        }

        // Task lists
        var taskListRows = Dictionary(
            uniqueKeysWithValues: try taskListRows(boardId, profileId).map { ($0.taskListId, $0) })
        for taskList in payload.taskLists {
            let json = try encoder.encode(taskList)
            if let row = taskListRows.removeValue(forKey: taskList.id) {
                row.json = json
                row.cardId = taskList.cardId
            } else {
                modelContext.insert(CachedTaskList(
                    profileId: profileId, boardId: boardId, cardId: taskList.cardId,
                    taskListId: taskList.id, json: json))
            }
        }
        taskListRows.values.forEach(modelContext.delete)

        // Tasks — same protection as cards.
        var taskRows = Dictionary(uniqueKeysWithValues: try taskRows(boardId, profileId).map { ($0.taskId, $0) })
        for task in payload.tasks {
            let json = try encoder.encode(task)
            if let row = taskRows.removeValue(forKey: task.id) {
                guard !row.isDirty, !row.isLocalOnly else { continue }
                row.json = json
                row.taskListId = task.taskListId
            } else {
                modelContext.insert(CachedTask(
                    profileId: profileId, boardId: boardId, taskListId: task.taskListId,
                    taskId: task.id, json: json))
            }
        }
        for row in taskRows.values where !row.isDirty && !row.isLocalOnly {
            modelContext.delete(row)
        }

        // Labels
        var labelRows = Dictionary(
            uniqueKeysWithValues: try labelRows(boardId, profileId).map { ($0.labelId, $0) })
        for label in payload.labels {
            let json = try encoder.encode(label)
            if let row = labelRows.removeValue(forKey: label.id) {
                row.json = json
            } else {
                modelContext.insert(CachedLabel(
                    profileId: profileId, boardId: boardId, labelId: label.id, json: json))
            }
        }
        labelRows.values.forEach(modelContext.delete)

        // Card↔label and card↔member joins
        var cardLabelRows = Dictionary(
            uniqueKeysWithValues: try cardLabelRows(boardId, profileId).map { ($0.key, $0) })
        for join in payload.cardLabels {
            let json = try encoder.encode(join)
            let key = cacheKey(profileId: profileId, id: join.id)
            if let row = cardLabelRows.removeValue(forKey: key) {
                row.json = json
            } else {
                modelContext.insert(CachedCardLabel(
                    profileId: profileId, boardId: boardId, id: join.id, json: json))
            }
        }
        cardLabelRows.values.forEach(modelContext.delete)

        var membershipRows = Dictionary(
            uniqueKeysWithValues: try membershipRows(boardId, profileId).map { ($0.key, $0) })
        for membership in payload.cardMemberships {
            let json = try encoder.encode(membership)
            let key = cacheKey(profileId: profileId, id: membership.id)
            if let row = membershipRows.removeValue(forKey: key) {
                row.json = json
            } else {
                modelContext.insert(CachedCardMembership(
                    profileId: profileId, boardId: boardId, id: membership.id, json: json))
            }
        }
        membershipRows.values.forEach(modelContext.delete)

        // Users belong to the profile, not the board, so they are upserted, never pruned.
        var userRows = Dictionary(uniqueKeysWithValues: try userRows(profileId).map { ($0.userId, $0) })
        for user in payload.users {
            let json = try encoder.encode(user)
            if let row = userRows.removeValue(forKey: user.id) {
                row.json = json
            } else {
                modelContext.insert(CachedUser(profileId: profileId, userId: user.id, json: json))
            }
        }

        try modelContext.save()
    }

    /// The cached board, or `nil` if this profile has never opened it.
    public func payload(boardId: String, profileId: String) throws -> BoardPayload? {
        guard let cached = try boardRow(boardId, profileId) else { return nil }
        let extras = (try? decoder.decode(BoardExtras.self, from: cached.extrasJSON)) ?? BoardExtras()

        return BoardPayload(
            board: try decoder.decode(Board.self, from: cached.json),
            lists: try decodeAll(PlankaList.self, try listRows(boardId, profileId).map(\.json)),
            cards: try decodeAll(Card.self, try cardRows(boardId, profileId).map(\.json)),
            taskLists: try decodeAll(TaskList.self, try taskListRows(boardId, profileId).map(\.json)),
            tasks: try decodeAll(PlankaTask.self, try taskRows(boardId, profileId).map(\.json)),
            labels: try decodeAll(Label.self, try labelRows(boardId, profileId).map(\.json)),
            cardMemberships: try decodeAll(
                CardMembership.self, try membershipRows(boardId, profileId).map(\.json)),
            cardLabels: try decodeAll(CardLabel.self, try cardLabelRows(boardId, profileId).map(\.json)),
            users: try decodeAll(User.self, try userRows(profileId).map(\.json)),
            attachments: extras.attachments,
            boardMemberships: extras.boardMemberships,
            customFieldGroups: extras.customFieldGroups,
            customFields: extras.customFields,
            customFieldValues: extras.customFieldValues)
    }

    /// When the board was last written from the server — for an "offline copy from …" note.
    public func cachedAt(boardId: String, profileId: String) throws -> Date? {
        try boardRow(boardId, profileId)?.cachedAt
    }

    // MARK: - Projects list

    public func cache(projects payload: ProjectsPayload, profileId: String) throws {
        let json = try encoder.encode(ProjectsSnapshot(payload))
        if let row = try projectsRow(profileId) {
            row.json = json
            row.cachedAt = Date()
        } else {
            modelContext.insert(CachedProjects(profileId: profileId, json: json, cachedAt: Date()))
        }
        try modelContext.save()
    }

    public func projects(profileId: String) throws -> ProjectsPayload? {
        guard let row = try projectsRow(profileId) else { return nil }
        return try decoder.decode(ProjectsSnapshot.self, from: row.json).payload
    }

    public func projectsCachedAt(profileId: String) throws -> Date? {
        try projectsRow(profileId)?.cachedAt
    }

    /// Cards cached for a board — the "N cards" count without a network call. `nil` when
    /// the board has never been cached, so the row can stay blank rather than claim zero.
    public func cardCount(boardId: String, profileId: String) throws -> Int? {
        guard try boardRow(boardId, profileId) != nil else { return nil }
        return try modelContext.fetchCount(FetchDescriptor<CachedCard>(
            predicate: #Predicate { $0.profileId == profileId && $0.boardId == boardId }))
    }

    /// Boards this profile has cached — lets a prefetch skip what it already has.
    public func cachedBoardIds(profileId: String) throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<CachedBoard>(
            predicate: #Predicate { $0.profileId == profileId })).map(\.boardId))
    }

    // MARK: - Comments

    public func cache(comments: [Comment], cardId: String, boardId: String, profileId: String) throws {
        var rows = Dictionary(uniqueKeysWithValues: try commentRows(cardId, profileId).map { ($0.commentId, $0) })
        for comment in comments {
            let json = try encoder.encode(comment)
            if let row = rows.removeValue(forKey: comment.id) {
                row.json = json
            } else {
                modelContext.insert(CachedComment(
                    profileId: profileId, boardId: boardId, cardId: cardId,
                    commentId: comment.id, json: json))
            }
        }
        // A comment posted offline isn't on the server yet — keep it.
        for row in rows.values where !row.isLocalOnly {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    public func comments(cardId: String, profileId: String) throws -> [Comment] {
        try decodeAll(Comment.self, try commentRows(cardId, profileId).map(\.json))
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    // MARK: - Outbox

    /// Queues a mutation and applies it to the cache, so the UI reflects it immediately.
    /// Returns the id the entity has locally — for a create, a fresh local id.
    @discardableResult
    public func enqueue(
        _ payload: MutationPayload,
        targetId: String,
        boardId: String,
        profileId: String,
        now: Date = Date()) throws -> String
    {
        let localId = try applyLocally(
            payload, targetId: targetId, boardId: boardId, profileId: profileId, now: now)
        modelContext.insert(PendingMutation(
            profileId: profileId,
            boardId: boardId,
            kind: payload.kind,
            targetId: localId,
            payload: try encoder.encode(payload),
            createdAt: now))
        try modelContext.save()
        return localId
    }

    /// Everything waiting for this profile, oldest first — the order it must replay in.
    public func pending(profileId: String) throws -> [QueuedMutation] {
        try modelContext.fetch(FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.profileId == profileId },
            sortBy: [SortDescriptor(\.createdAt)]))
            .compactMap(queued)
    }

    /// How many mutations are still queued — drives a "N pending" badge.
    public func pendingCount(profileId: String) throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.profileId == profileId }))
    }

    /// Cards and tasks with unsynced work, so their rows can be marked in the UI.
    public func dirtyIds(boardId: String, profileId: String) throws -> Set<String> {
        let cards = try cardRows(boardId, profileId).filter { $0.isDirty || $0.isLocalOnly }.map(\.cardId)
        let tasks = try taskRows(boardId, profileId).filter { $0.isDirty || $0.isLocalOnly }.map(\.taskId)
        return Set(cards).union(tasks)
    }

    /// Accepted by the server: drop the entry and clear the marks it explained.
    public func resolve(_ id: UUID) throws {
        guard let row = try mutationRow(id) else { return }
        let targetId = row.targetId
        let profileId = row.profileId
        modelContext.delete(row)
        // Clear the flag only once nothing else is queued against that entity.
        let stillQueued = try modelContext.fetchCount(FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.targetId == targetId })) > 0
        if !stillQueued {
            if let card = try cardRow(targetId, profileId) {
                card.isDirty = false
                card.isLocalOnly = false
            }
            if let task = try taskRow(targetId, profileId) {
                task.isDirty = false
                task.isLocalOnly = false
            }
            if let comment = try commentRow(targetId, profileId) {
                comment.isLocalOnly = false
            }
        }
        try modelContext.save()
    }

    /// Kept for a later attempt (network or 5xx): record why, leave the entry in place.
    public func recordFailure(_ id: UUID, error: String) throws {
        guard let row = try mutationRow(id) else { return }
        row.attempts += 1
        row.lastError = error
        try modelContext.save()
    }

    /// The server refused the mutation outright (409/422/404/403): the entry goes, and the
    /// caller refetches the board so the cache stops showing a change that never happened.
    public func drop(_ id: UUID) throws {
        guard let row = try mutationRow(id) else { return }
        modelContext.delete(row)
        try modelContext.save()
    }

    /// Rewrites a local id to the one the server assigned, across the cache and any
    /// queued mutations that referenced it (e.g. a rename of a card created offline).
    public func remap(localId: String, to serverId: String, profileId: String) throws {
        if let row = try cardRow(localId, profileId) {
            let card = try decoder.decode(Card.self, from: row.json).withId(serverId)
            row.cardId = serverId
            row.key = cacheKey(profileId: profileId, id: serverId)
            row.isLocalOnly = false
            row.json = try encoder.encode(card)
        }
        if let row = try taskRow(localId, profileId) {
            let task = try decoder.decode(PlankaTask.self, from: row.json).withId(serverId)
            row.taskId = serverId
            row.key = cacheKey(profileId: profileId, id: serverId)
            row.isLocalOnly = false
            row.json = try encoder.encode(task)
        }
        for row in try modelContext.fetch(FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.targetId == localId }))
        {
            row.targetId = serverId
        }
        // A queued comment names its card in the payload as well as in `targetId`.
        let commentKind = MutationKind.createComment.rawValue
        for row in try modelContext.fetch(FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.kindRaw == commentKind }))
        {
            guard case let .createComment(cardId, text) = try? decoder
                .decode(MutationPayload.self, from: row.payload), cardId == localId else { continue }
            row.payload = try encoder.encode(MutationPayload.createComment(cardId: serverId, text: text))
        }
        // Cached comments on a card that has just been given its real id.
        for row in try modelContext.fetch(FetchDescriptor<CachedComment>(
            predicate: #Predicate { $0.profileId == profileId && $0.cardId == localId }))
        {
            row.cardId = serverId
        }
        try modelContext.save()
    }

    /// Drops everything cached for a profile — used when its server is removed.
    public func clear(profileId: String) throws {
        try modelContext.delete(model: CachedBoard.self, where: #Predicate { $0.profileId == profileId })
        try modelContext.delete(model: CachedList.self, where: #Predicate { $0.profileId == profileId })
        try modelContext.delete(model: CachedCard.self, where: #Predicate { $0.profileId == profileId })
        try modelContext.delete(model: CachedTaskList.self, where: #Predicate { $0.profileId == profileId })
        try modelContext.delete(model: CachedTask.self, where: #Predicate { $0.profileId == profileId })
        try modelContext.delete(model: CachedLabel.self, where: #Predicate { $0.profileId == profileId })
        try modelContext.delete(model: CachedCardLabel.self, where: #Predicate { $0.profileId == profileId })
        try modelContext.delete(
            model: CachedCardMembership.self, where: #Predicate { $0.profileId == profileId })
        try modelContext.delete(model: CachedProjects.self, where: #Predicate { $0.profileId == profileId })
        try modelContext.delete(model: CachedUser.self, where: #Predicate { $0.profileId == profileId })
        try modelContext.delete(model: CachedComment.self, where: #Predicate { $0.profileId == profileId })
        try modelContext.delete(model: PendingMutation.self, where: #Predicate { $0.profileId == profileId })
        try modelContext.save()
    }

    // MARK: - Optimistic local apply

    /// Applies a mutation to the cache. Returns the id the entity is known by locally.
    private func applyLocally(
        _ payload: MutationPayload,
        targetId: String,
        boardId: String,
        profileId: String,
        now: Date) throws -> String
    {
        switch payload {
        case let .createCard(listId, name, position, type):
            let localId = LocalID.make()
            let card = Card.local(
                id: localId, boardId: boardId, listId: listId, name: name,
                position: position, type: type, createdAt: now)
            modelContext.insert(CachedCard(
                profileId: profileId, boardId: boardId, listId: listId, cardId: localId,
                json: try encoder.encode(card), isDirty: true, isLocalOnly: true))
            return localId

        case let .updateCard(edit):
            guard let row = try cardRow(targetId, profileId) else { return targetId }
            let updated = try decoder.decode(Card.self, from: row.json).applying(edit)
            row.json = try encoder.encode(updated)
            row.listId = updated.listId
            row.isDirty = true
            return targetId

        case .deleteCard:
            if let row = try cardRow(targetId, profileId) { modelContext.delete(row) }
            return targetId

        case let .createTask(taskListId, name, position):
            let localId = LocalID.make()
            let task = PlankaTask(
                id: localId, taskListId: taskListId, linkedCardId: nil, assigneeUserId: nil,
                position: position, name: name, isCompleted: false, createdAt: now, updatedAt: nil)
            modelContext.insert(CachedTask(
                profileId: profileId, boardId: boardId, taskListId: taskListId, taskId: localId,
                json: try encoder.encode(task), isDirty: true, isLocalOnly: true))
            return localId

        case let .updateTask(edit):
            guard let row = try taskRow(targetId, profileId) else { return targetId }
            let updated = try decoder.decode(PlankaTask.self, from: row.json).applying(edit)
            row.json = try encoder.encode(updated)
            row.isDirty = true
            return targetId

        case .deleteTask:
            if let row = try taskRow(targetId, profileId) { modelContext.delete(row) }
            return targetId

        case let .createComment(cardId, text):
            let localId = LocalID.make()
            let comment = Comment(
                id: localId, cardId: cardId, userId: nil, text: text, createdAt: now, updatedAt: nil)
            modelContext.insert(CachedComment(
                profileId: profileId, boardId: boardId, cardId: cardId, commentId: localId,
                json: try encoder.encode(comment), isLocalOnly: true))
            return localId
        }
    }

    // MARK: - Row lookups

    private func boardRow(_ boardId: String, _ profileId: String) throws -> CachedBoard? {
        try modelContext.fetch(FetchDescriptor<CachedBoard>(
            predicate: #Predicate { $0.profileId == profileId && $0.boardId == boardId })).first
    }

    private func listRows(_ boardId: String, _ profileId: String) throws -> [CachedList] {
        try modelContext.fetch(FetchDescriptor<CachedList>(
            predicate: #Predicate { $0.profileId == profileId && $0.boardId == boardId }))
    }

    private func cardRows(_ boardId: String, _ profileId: String) throws -> [CachedCard] {
        try modelContext.fetch(FetchDescriptor<CachedCard>(
            predicate: #Predicate { $0.profileId == profileId && $0.boardId == boardId }))
    }

    private func cardRow(_ cardId: String, _ profileId: String) throws -> CachedCard? {
        try modelContext.fetch(FetchDescriptor<CachedCard>(
            predicate: #Predicate { $0.profileId == profileId && $0.cardId == cardId })).first
    }

    private func taskListRows(_ boardId: String, _ profileId: String) throws -> [CachedTaskList] {
        try modelContext.fetch(FetchDescriptor<CachedTaskList>(
            predicate: #Predicate { $0.profileId == profileId && $0.boardId == boardId }))
    }

    private func taskRows(_ boardId: String, _ profileId: String) throws -> [CachedTask] {
        try modelContext.fetch(FetchDescriptor<CachedTask>(
            predicate: #Predicate { $0.profileId == profileId && $0.boardId == boardId }))
    }

    private func taskRow(_ taskId: String, _ profileId: String) throws -> CachedTask? {
        try modelContext.fetch(FetchDescriptor<CachedTask>(
            predicate: #Predicate { $0.profileId == profileId && $0.taskId == taskId })).first
    }

    private func labelRows(_ boardId: String, _ profileId: String) throws -> [CachedLabel] {
        try modelContext.fetch(FetchDescriptor<CachedLabel>(
            predicate: #Predicate { $0.profileId == profileId && $0.boardId == boardId }))
    }

    private func cardLabelRows(_ boardId: String, _ profileId: String) throws -> [CachedCardLabel] {
        try modelContext.fetch(FetchDescriptor<CachedCardLabel>(
            predicate: #Predicate { $0.profileId == profileId && $0.boardId == boardId }))
    }

    private func membershipRows(_ boardId: String, _ profileId: String) throws -> [CachedCardMembership] {
        try modelContext.fetch(FetchDescriptor<CachedCardMembership>(
            predicate: #Predicate { $0.profileId == profileId && $0.boardId == boardId }))
    }

    private func userRows(_ profileId: String) throws -> [CachedUser] {
        try modelContext.fetch(FetchDescriptor<CachedUser>(
            predicate: #Predicate { $0.profileId == profileId }))
    }

    private func commentRows(_ cardId: String, _ profileId: String) throws -> [CachedComment] {
        try modelContext.fetch(FetchDescriptor<CachedComment>(
            predicate: #Predicate { $0.profileId == profileId && $0.cardId == cardId }))
    }

    private func commentRow(_ commentId: String, _ profileId: String) throws -> CachedComment? {
        try modelContext.fetch(FetchDescriptor<CachedComment>(
            predicate: #Predicate { $0.profileId == profileId && $0.commentId == commentId })).first
    }

    private func projectsRow(_ profileId: String) throws -> CachedProjects? {
        try modelContext.fetch(FetchDescriptor<CachedProjects>(
            predicate: #Predicate { $0.profileId == profileId })).first
    }

    private func mutationRow(_ id: UUID) throws -> PendingMutation? {
        try modelContext.fetch(FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.id == id })).first
    }

    private func queued(_ row: PendingMutation) -> QueuedMutation? {
        guard let kind = row.kind,
              let payload = try? decoder.decode(MutationPayload.self, from: row.payload)
        else { return nil }
        return QueuedMutation(
            id: row.id, profileId: row.profileId, boardId: row.boardId, kind: kind,
            targetId: row.targetId, payload: payload, createdAt: row.createdAt,
            attempts: row.attempts, lastError: row.lastError)
    }

    private func decodeAll<T: Decodable>(_: T.Type, _ blobs: [Data]) throws -> [T] {
        try blobs.map { try decoder.decode(T.self, from: $0) }
    }
}

/// `ProjectsPayload` is a plain value type, not `Codable`, so the cache keeps its own
/// mirror. One place to update when the payload gains an array.
struct ProjectsSnapshot: Codable {
    var projects: [Project] = []
    var boards: [Board] = []
    var users: [User] = []
    var boardMemberships: [BoardMembership] = []
    var backgroundImages: [BackgroundImage] = []
    var projectManagers: [ProjectManager] = []
    var baseCustomFieldGroups: [BaseCustomFieldGroup] = []
    var customFields: [CustomField] = []

    init(_ payload: ProjectsPayload) {
        projects = payload.projects
        boards = payload.boards
        users = payload.users
        boardMemberships = payload.boardMemberships
        backgroundImages = payload.backgroundImages
        projectManagers = payload.projectManagers
        baseCustomFieldGroups = payload.baseCustomFieldGroups
        customFields = payload.customFields
    }

    var payload: ProjectsPayload {
        ProjectsPayload(
            projects: projects,
            boards: boards,
            users: users,
            boardMemberships: boardMemberships,
            backgroundImages: backgroundImages,
            projectManagers: projectManagers,
            baseCustomFieldGroups: baseCustomFieldGroups,
            customFields: customFields)
    }
}

/// The read-only slice of a board payload kept as one blob (see `CachedBoard.extrasJSON`).
struct BoardExtras: Codable {
    var attachments: [Attachment] = []
    var boardMemberships: [BoardMembership] = []
    var customFieldGroups: [CustomFieldGroup] = []
    var customFields: [CustomField] = []
    var customFieldValues: [CustomFieldValue] = []
}
