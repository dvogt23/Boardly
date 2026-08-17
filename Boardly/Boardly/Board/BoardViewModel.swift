import BoardlyKit
import Foundation

@Observable
@MainActor
final class BoardViewModel {
    var payload: BoardPayload?
    var isLoading = false
    var error: String?

    /// The project's base custom-field groups (loaded on demand for the board's
    /// custom-fields management sheet).
    var baseGroups: [BaseCustomFieldGroup] = []
    private var baseFields: [CustomField] = []

    /// Rendering a cached board while offline, and the ids whose changes are still queued
    /// (so the UI can mark them). Empty when local-first is unavailable.
    var isShowingCachedCopy = false
    var cachedAt: Date?
    var pendingIds: Set<String> = []

    private let client: PlankaClient
    let boardId: String
    private var connection: ProfileRealtimeConnection?
    private var realtimeTask: Task<Void, Never>?
    /// Stable identity for this session's stream on the shared connection, so a
    /// stale teardown can't close a newer session's board stream.
    private let realtimeOwner = UUID()

    /// Local-first support. `nil` in previews and in the mock harnesses, where the view
    /// model talks to a stubbed client and no cache exists — every path below falls back
    /// to the online-only behaviour when these are absent.
    private let offline: OfflineCoordinator?
    private let profileId: String?

    private var store: OfflineStore? { offline?.store }
    /// Treat "offline" as the monitor's answer; a request may still fail either way.
    private var isOnline: Bool { offline?.isOnline ?? true }

    init(
        client: PlankaClient,
        boardId: String,
        offline: OfflineCoordinator? = nil,
        profileId: String? = nil)
    {
        self.client = client
        self.boardId = boardId
        self.offline = offline
        self.profileId = profileId
    }

    // MARK: - Real-time sync

    /// Subscribe this board to live events over the profile's *shared* connection
    /// and apply them to `payload`. Non-blocking: the event loop runs in a stored
    /// Task tied to the view model's lifetime (not the view's), so pushing the card
    /// detail doesn't tear it down. Realtime is owned per profile, not per board —
    /// see `BoardSessionStore`.
    func startRealtime(using connection: ProfileRealtimeConnection) {
        guard realtimeTask == nil else { return }
        self.connection = connection
        let boardId = boardId
        let owner = realtimeOwner
        realtimeTask = Task { [weak self] in
            let stream = await connection.openBoard(boardId, owner: owner)
            // Torn down before the open landed → close the stream we just opened so
            // it doesn't leak (its owner match still holds).
            if Task.isCancelled {
                await connection.closeBoard(boardId, owner: owner)
                return
            }
            for await event in stream {
                guard let self else { break }
                // A resync is server truth for the whole board, so it must go through
                // `adopt` — assigning it directly would drop rows the user changed
                // offline (their queued mutations haven't replayed yet).
                if case let .resynced(fresh) = event {
                    await adopt(fresh)
                } else if let current = payload {
                    let updated = current.applying(event)
                    payload = updated
                    // Keep the cache tracking live edits, so leaving and returning
                    // offline shows what realtime last delivered.
                    await writeThrough(updated)
                }
            }
        }
    }

    /// Leave the board's room on the shared connection. Must be called only when
    /// actually leaving the board (the connection disconnects when its last board
    /// leaves).
    func stopRealtime() async {
        realtimeTask?.cancel()
        realtimeTask = nil
        await connection?.closeBoard(boardId, owner: realtimeOwner)
        connection = nil
    }

    /// Cache first, then the server. The cached copy renders immediately (and is all there
    /// is when offline); a successful fetch replaces it and is written back.
    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        if payload == nil, let cached = await cachedPayload() {
            payload = cached
            isShowingCachedCopy = true
        }

        // Send before receiving: otherwise the refetch below returns a board that
        // doesn't know about the local changes, and adopting it looks like data loss.
        await flushOutbox()

        do {
            let fresh = try await client.getBoard(id: boardId)
            await adopt(fresh)
            isShowingCachedCopy = false
            error = nil
            // A completed round trip is the authoritative "we're online" signal, and it
            // kicks the outbox if a missed connectivity transition stranded it.
            offline?.noteSuccess()
        } catch {
            offline?.noteFailure(error)
            // A cached board is better than an error screen: keep showing it and say so.
            if payload != nil {
                isShowingCachedCopy = true
                BoardlyLog.tag(.sync).icon("📥").info(
                    "Serving the cached board", metadata: ["board": boardId])
            } else {
                self.error = localizedErrorMessage(error)
            }
        }
        await refreshPendingIds()
    }

    private func cachedPayload() async -> BoardPayload? {
        guard let store, let profileId else { return nil }
        cachedAt = try? await store.cachedAt(boardId: boardId, profileId: profileId)
        return try? await store.payload(boardId: boardId, profileId: profileId)
    }

    private func writeThrough(_ payload: BoardPayload) async {
        guard let store, let profileId else { return }
        try? await store.cache(payload, profileId: profileId)
        cachedAt = Date()
    }

    /// Takes server truth for the whole board *and keeps unsynced local work visible*.
    ///
    /// Caching prunes what the server no longer has but protects dirty and local-only
    /// rows, so re-reading the cache afterwards gives the server's board plus the
    /// changes still sitting in the outbox. Assigning the server payload straight to
    /// `payload` would make a card created offline vanish from the screen while its
    /// queued create was still waiting.
    private func adopt(_ fresh: BoardPayload) async {
        guard store != nil, profileId != nil else {
            payload = fresh
            return
        }
        await writeThrough(fresh)
        if let merged = await cachedPayload() {
            payload = merged
        } else {
            payload = fresh
        }
        await refreshPendingIds()
    }

    /// Pushes queued changes to the server and waits for the run. Called before every
    /// (re)load, so a pull-to-refresh means "send my changes, then show me the truth"
    /// rather than just refetching over the top of them.
    func flushOutbox() async {
        guard let offline, let profileId else { return }
        await offline.syncNow(profileId: profileId, client: client)
        await refreshPendingIds()
    }

    /// Refreshes the set of ids whose local changes haven't reached the server.
    func refreshPendingIds() async {
        guard let store, let profileId else { return }
        pendingIds = (try? await store.dirtyIds(boardId: boardId, profileId: profileId)) ?? []
    }

    /// Queues a mutation locally, applies it to the cache, and mirrors it into `payload`
    /// so the screen updates at once. Used for every write while offline.
    private func queue(_ mutation: MutationPayload, targetId: String) async -> Bool {
        guard let store, let profileId else { return false }
        do {
            _ = try await store.enqueue(
                mutation, targetId: targetId, boardId: boardId, profileId: profileId)
            // Re-read rather than patching `payload` by hand: the store just applied the
            // same change, so this keeps one implementation of "what does this mutation do".
            if let updated = try await store.payload(boardId: boardId, profileId: profileId) {
                payload = updated
            }
            await refreshPendingIds()
            await offline?.refreshPendingCount(profileId: profileId)
            return true
        } catch {
            self.error = localizedErrorMessage(error)
            return false
        }
    }

    // MARK: - Card CRUD

    func createCard(in list: PlankaList, name: String) async {
        guard let payload else { return }
        let position = payload.nextCardPosition(in: list)
        let type = payload.board.defaultCardType ?? "project"

        guard isOnline else {
            await queue(
                .createCard(listId: list.id, name: name, position: position, type: type),
                targetId: "")
            return
        }
        do {
            let card = try await client.createCard(
                listId: list.id, name: name, position: position, type: type)
            var updated = payload
            updated.cards.append(card)
            self.payload = updated
            await writeThrough(updated)
        } catch {
            // Reachability said online but the request didn't land — queue it rather than
            // making the user retype the card.
            offline?.noteFailure(error)
            if isRetryable(error), await queue(
                .createCard(listId: list.id, name: name, position: position, type: type),
                targetId: "")
            {
                return
            }
            self.error = localizedErrorMessage(error)
        }
    }

    func moveCard(_ card: Card, to list: PlankaList) async {
        guard let payload else { return }
        let position = payload.nextCardPosition(in: list)
        await updateCard(card, edit: CardEdit(listId: list.id, position: position))
    }

    func deleteCard(_ card: Card) async {
        guard let payload else { return }
        guard isOnline else {
            await queue(.deleteCard, targetId: card.id)
            return
        }
        do {
            try await client.deleteCard(id: card.id)
            var updated = payload
            updated.cards.removeAll { $0.id == card.id }
            self.payload = updated
            await writeThrough(updated)
        } catch {
            offline?.noteFailure(error)
            offline?.noteFailure(error)
            if isRetryable(error), await queue(.deleteCard, targetId: card.id) { return }
            self.error = localizedErrorMessage(error)
        }
    }

    /// The single path every card edit takes, online or queued — `CardEdit` is also what
    /// the outbox stores, so there is one description of "what changed".
    func updateCard(_ card: Card, edit: CardEdit) async {
        guard isOnline else {
            await queue(.updateCard(edit), targetId: card.id)
            return
        }
        do {
            let updated = try await client.updateCard(id: card.id, patch: edit.patch)
            replaceCard(updated)
            if let payload { await writeThrough(payload) }
        } catch {
            offline?.noteFailure(error)
            offline?.noteFailure(error)
            if isRetryable(error), await queue(.updateCard(edit), targetId: card.id) { return }
            self.error = localizedErrorMessage(error)
        }
    }

    /// Whether a failed request is worth queueing rather than surfacing: transport and
    /// server-side faults are, a refusal (401/403/404/409/422) is not.
    private func isRetryable(_ error: Error) -> Bool {
        guard store != nil else { return false }
        return switch error as? PlankaAPIError {
        case .networkError, .instanceUnreachable, .serverError: true
        default: false
        }
    }

    // MARK: - Task list CRUD

    func createTaskList(in card: Card, name: String) async {
        guard let payload else { return }
        let position = (payload.taskLists(for: card).last?.position ?? 0) + 65536
        do {
            let taskList = try await client.createTaskList(
                cardId: card.id,
                name: name,
                position: position)
            var updated = payload
            updated.taskLists.append(taskList)
            self.payload = updated
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    // MARK: - Task CRUD

    func toggleTask(_ task: PlankaTask) async {
        let edit = TaskEdit(isCompleted: !task.isCompleted)
        guard isOnline else {
            await queue(.updateTask(edit), targetId: task.id)
            return
        }
        do {
            let updated = try await client.updateTask(id: task.id, patch: edit.patch)
            replaceTask(updated)
            if let payload { await writeThrough(payload) }
        } catch {
            offline?.noteFailure(error)
            offline?.noteFailure(error)
            if isRetryable(error), await queue(.updateTask(edit), targetId: task.id) { return }
            self.error = localizedErrorMessage(error)
        }
    }

    func createTask(in taskList: TaskList, name: String) async {
        guard let payload else { return }
        let position = (payload.tasks(for: taskList).last?.position ?? 0) + 65536
        guard isOnline else {
            await queue(
                .createTask(taskListId: taskList.id, name: name, position: position), targetId: "")
            return
        }
        do {
            let task = try await client.createTask(
                taskListId: taskList.id, name: name, position: position)
            var updated = payload
            updated.tasks.append(task)
            self.payload = updated
            await writeThrough(updated)
        } catch {
            offline?.noteFailure(error)
            if isRetryable(error), await queue(
                .createTask(taskListId: taskList.id, name: name, position: position), targetId: "")
            {
                return
            }
            self.error = localizedErrorMessage(error)
        }
    }

    func deleteTask(_ task: PlankaTask) async {
        guard let payload else { return }
        guard isOnline else {
            await queue(.deleteTask, targetId: task.id)
            return
        }
        do {
            try await client.deleteTask(id: task.id)
            var updated = payload
            updated.tasks.removeAll { $0.id == task.id }
            self.payload = updated
            await writeThrough(updated)
        } catch {
            offline?.noteFailure(error)
            offline?.noteFailure(error)
            if isRetryable(error), await queue(.deleteTask, targetId: task.id) { return }
            self.error = localizedErrorMessage(error)
        }
    }

    func updateCard(_ card: Card, patch: CardPatch) async {
        do {
            let updated = try await client.updateCard(id: card.id, patch: patch)
            replaceCard(updated)
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    /// Set or clear a card's due date. Passing `nil` clears it (sends `dueDate: null`).
    func updateDueDate(_ card: Card, to dueDate: Date?) async {
        let patch = dueDate.map { CardPatch(dueDate: $0) } ?? CardPatch(clearDueDate: true)
        await updateCard(card, patch: patch)
    }

    // MARK: - Labels

    func addLabel(_ label: Label, to card: Card) async {
        do {
            let cardLabel = try await client.addCardLabel(cardId: card.id, labelId: label.id)
            guard var copy = payload else { return }
            if !copy.cardLabels.contains(where: { $0.id == cardLabel.id }) {
                copy.cardLabels.append(cardLabel)
            }
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    func removeLabel(_ label: Label, from card: Card) async {
        do {
            try await client.removeCardLabel(cardId: card.id, labelId: label.id)
            guard var copy = payload else { return }
            copy.cardLabels.removeAll { $0.cardId == card.id && $0.labelId == label.id }
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    func createLabel(name: String, color: String) async {
        guard var copy = payload else { return }
        let position = (copy.labels.map { $0.position ?? 0 }.max() ?? 0) + 65536
        do {
            let label = try await client.createLabel(boardId: boardId, name: name, color: color, position: position)
            copy.labels.append(label)
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    // MARK: - Custom field values (Phase 7)

    func setCustomFieldValue(_ content: String, groupId: String, fieldId: String, card: Card) async {
        do {
            let value = try await client.setCustomFieldValue(
                cardId: card.id, groupId: groupId, fieldId: fieldId, content: content)
            guard var copy = payload else { return }
            if let idx = copy.customFieldValues.firstIndex(where: { $0.id == value.id }) {
                copy.customFieldValues[idx] = value
            } else {
                copy.customFieldValues.append(value)
            }
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    func clearCustomFieldValue(groupId: String, fieldId: String, card: Card) async {
        do {
            try await client.clearCustomFieldValue(cardId: card.id, groupId: groupId, fieldId: fieldId)
            guard var copy = payload else { return }
            copy.customFieldValues.removeAll {
                $0.cardId == card.id && $0.customFieldGroupId == groupId && $0.customFieldId == fieldId
            }
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    // MARK: - Custom field groups (Phase 7 · board management)

    /// Load the project's base custom-field groups (the "inherited" candidates).
    func loadBaseGroups() async {
        guard let projectId = payload?.board.projectId else { return }
        do {
            let projects = try await client.getProjects()
            guard let project = projects.projects.first(where: { $0.id == projectId }) else { return }
            baseGroups = projects.baseGroups(for: project)
            baseFields = projects.customFields
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    func fields(inBaseGroup group: BaseCustomFieldGroup) -> [CustomField] {
        baseFields.filter { $0.baseCustomFieldGroupId == group.id }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
    }

    /// The board's instance of a base group, if it has been enabled.
    func instance(ofBase base: BaseCustomFieldGroup) -> CustomFieldGroup? {
        payload?.customFieldGroups.first { $0.baseCustomFieldGroupId == base.id }
    }

    /// Enable a base group on this board (the server copies its fields), then refresh.
    func enableBaseGroup(_ base: BaseCustomFieldGroup) async {
        guard let payload else { return }
        let position = (payload.boardCustomFieldGroups().map { $0.position ?? 0 }.max() ?? 0) + 65536
        do {
            _ = try await client.createBoardCustomFieldGroup(
                boardId: boardId, position: position, baseCustomFieldGroupId: base.id)
            await refreshCustomFields()
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    func disableBaseGroup(_ base: BaseCustomFieldGroup) async {
        guard let group = instance(ofBase: base) else { return }
        await deleteCustomFieldGroup(group)
    }

    func addBoardGroup(name: String) async {
        guard let payload else { return }
        let position = (payload.boardCustomFieldGroups().map { $0.position ?? 0 }.max() ?? 0) + 65536
        do {
            let group = try await client.createBoardCustomFieldGroup(boardId: boardId, position: position, name: name)
            guard var copy = self.payload else { return }
            copy.customFieldGroups.append(group)
            self.payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    func deleteCustomFieldGroup(_ group: CustomFieldGroup) async {
        do {
            try await client.deleteCustomFieldGroup(id: group.id)
            guard var copy = payload else { return }
            copy.customFieldGroups.removeAll { $0.id == group.id }
            copy.customFields.removeAll { $0.customFieldGroupId == group.id }
            copy.customFieldValues.removeAll { $0.customFieldGroupId == group.id }
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    func addCustomField(to group: CustomFieldGroup, name: String) async {
        guard let payload else { return }
        let position = (payload.fields(in: group).map { $0.position ?? 0 }.max() ?? 0) + 65536
        do {
            let field = try await client.createCustomFieldInGroup(groupId: group.id, name: name, position: position)
            guard var copy = self.payload else { return }
            copy.customFields.append(field)
            self.payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    func deleteCustomField(_ field: CustomField) async {
        do {
            try await client.deleteCustomField(id: field.id)
            guard var copy = payload else { return }
            copy.customFields.removeAll { $0.id == field.id }
            copy.customFieldValues.removeAll { $0.customFieldId == field.id }
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    /// Re-fetch only the custom-field collections from the board (used after
    /// enabling a base group, whose fields are copied server-side).
    private func refreshCustomFields() async {
        do {
            let fresh = try await client.getBoard(id: boardId)
            guard var copy = payload else { return }
            copy.customFieldGroups = fresh.customFieldGroups
            copy.customFields = fresh.customFields
            copy.customFieldValues = fresh.customFieldValues
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    // MARK: - Board actions

    /// Flips to true once the board is deleted server-side; the view pops on it.
    var boardDeleted = false

    func renameBoard(to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let board = try await client.renameBoard(id: boardId, name: trimmed)
            guard var copy = payload else { return }
            copy.board = board
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    func deleteBoard() async {
        do {
            try await client.deleteBoard(id: boardId)
            boardDeleted = true
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    /// Candidate users for board membership — the board's project team (managers +
    /// members of any board in the project). Loaded on demand for the members sheet.
    var projectUsers: [User] = []

    func loadBoardMemberCandidates() async {
        guard let projectId = payload?.board.projectId else { return }
        do {
            let projects = try await client.getProjects()
            let ids = Set(projects.projectManagers.filter { $0.projectId == projectId }.map(\.userId))
                .union(projects.boardMemberships.filter { $0.projectId == projectId }.map(\.userId))
            projectUsers = projects.users.filter { ids.contains($0.id) }.sorted { $0.name < $1.name }
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    func addBoardMember(_ user: User) async {
        do {
            let membership = try await client.addBoardMember(boardId: boardId, userId: user.id)
            guard var copy = payload else { return }
            if !copy.boardMemberships.contains(where: { $0.id == membership.id }) {
                copy.boardMemberships.append(membership)
            }
            if !copy.users.contains(where: { $0.id == user.id }) {
                copy.users.append(user)
            }
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    func removeBoardMember(userId: String) async {
        guard let membership = payload?.boardMemberships.first(where: { $0.userId == userId }) else { return }
        do {
            try await client.removeBoardMember(membershipId: membership.id)
            guard var copy = payload else { return }
            copy.boardMemberships.removeAll { $0.id == membership.id }
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    /// CSV of the board's cards (list · card · labels · members · due · completed).
    func exportCSV() -> String {
        guard let payload else { return "" }
        func field(_ s: String) -> String {
            (s.contains(",") || s.contains("\"") || s.contains("\n"))
                ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
                : s
        }
        let iso = ISO8601DateFormatter()
        var rows = ["List,Card,Labels,Members,Due,Completed"]
        for list in payload.sortedLists() {
            for card in payload.cards(for: list) {
                let labels = payload.labels(for: card).compactMap(\.name).joined(separator: " ")
                let members = payload.members(for: card).map(\.name).joined(separator: " ")
                let due = card.dueDate.map { iso.string(from: $0) } ?? ""
                let done = card.isDueCompleted == true ? "yes" : ""
                rows.append([list.name ?? "", card.name, labels, members, due, done].map(field).joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n")
    }

    // MARK: - Members

    func addMember(_ user: User, to card: Card) async {
        do {
            let membership = try await client.addCardMember(cardId: card.id, userId: user.id)
            guard var copy = payload else { return }
            if !copy.cardMemberships.contains(where: { $0.id == membership.id }) {
                copy.cardMemberships.append(membership)
            }
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    func removeMember(_ user: User, from card: Card) async {
        do {
            try await client.removeCardMember(cardId: card.id, userId: user.id)
            guard var copy = payload else { return }
            copy.cardMemberships.removeAll { $0.cardId == card.id && $0.userId == user.id }
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    // MARK: - Comments

    /// The logged-in user, resolved from the token + board users (for authoring UI).
    var currentUser: User? {
        guard let uid = client.currentUserId() else { return nil }
        return payload?.users.first { $0.id == uid }
    }

    /// Returns nil on failure (so the UI can distinguish "empty" from "couldn't load").
    /// Cache first, like the board itself: cached comments show while offline, and a
    /// successful fetch is written back.
    func loadComments(cardId: String) async -> [Comment]? {
        do {
            let comments = try await client.getComments(cardId: cardId)
                .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            if let store, let profileId {
                try? await store.cache(
                    comments: comments, cardId: cardId, boardId: boardId, profileId: profileId)
                // Merge back so a comment posted offline stays visible alongside them.
                return try? await store.comments(cardId: cardId, profileId: profileId)
            }
            return comments
        } catch {
            if let cached = await cachedComments(cardId: cardId), !cached.isEmpty {
                return cached
            }
            self.error = localizedErrorMessage(error)
            return nil
        }
    }

    private func cachedComments(cardId: String) async -> [Comment]? {
        guard let store, let profileId else { return nil }
        return try? await store.comments(cardId: cardId, profileId: profileId)
    }

    func postComment(cardId: String, text: String) async -> Comment? {
        guard isOnline else {
            guard await queue(.createComment(cardId: cardId, text: text), targetId: cardId)
            else { return nil }
            adjustCommentsTotal(cardId: cardId, by: 1)
            return await cachedComments(cardId: cardId)?.last
        }
        do {
            let comment = try await client.createComment(cardId: cardId, text: text)
            adjustCommentsTotal(cardId: cardId, by: 1)
            return comment
        } catch {
            if isRetryable(error),
               await queue(.createComment(cardId: cardId, text: text), targetId: cardId)
            {
                adjustCommentsTotal(cardId: cardId, by: 1)
                return await cachedComments(cardId: cardId)?.last
            }
            self.error = localizedErrorMessage(error)
            return nil
        }
    }

    /// Deletes a comment; returns true on success so the caller only removes it
    /// from local state when the server confirms.
    func deleteComment(id: String, cardId: String) async -> Bool {
        do {
            try await client.deleteComment(id: id)
            adjustCommentsTotal(cardId: cardId, by: -1)
            return true
        } catch {
            self.error = localizedErrorMessage(error)
            return false
        }
    }

    private func adjustCommentsTotal(cardId: String, by delta: Int) {
        guard var copy = payload, let card = copy.card(id: cardId) else { return }
        copy.setCommentsTotal(cardId: cardId, max(0, (card.commentsTotal ?? 0) + delta))
        payload = copy
    }

    // MARK: - Images

    func loadImage(url: URL) async -> Data? {
        await client.imageData(url: url)
    }

    // MARK: - Attachments

    func uploadAttachment(cardId: String, fileName: String, mimeType: String, data: Data) async {
        do {
            let attachment = try await client.uploadFileAttachment(
                cardId: cardId, fileName: fileName, mimeType: mimeType, data: data)
            guard var copy = payload else { return }
            copy.attachments.append(attachment)
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    func addLinkAttachment(cardId: String, url: String, name: String) async {
        do {
            let attachment = try await client.addLinkAttachment(cardId: cardId, url: url, name: name)
            guard var copy = payload else { return }
            copy.attachments.append(attachment)
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    func removeAttachment(_ attachment: Attachment) async {
        do {
            try await client.deleteAttachment(id: attachment.id)
            guard var copy = payload else { return }
            copy.attachments.removeAll { $0.id == attachment.id }
            payload = copy
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    // MARK: - Activity

    func loadActions(cardId: String) async -> [Action] {
        do {
            return try await client.getCardActions(cardId: cardId)
                .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        } catch {
            self.error = localizedErrorMessage(error)
            return []
        }
    }

    // MARK: - Stopwatch

    func toggleStopwatch(_ card: Card) async {
        let sw = card.stopwatchValue
        do {
            let updated: Card = if let sw, sw.isRunning {
                try await client.updateStopwatch(cardId: card.id, total: sw.elapsed(), startedAt: nil)
            } else {
                try await client.updateStopwatch(cardId: card.id, total: sw?.total ?? 0, startedAt: Date())
            }
            replaceCard(updated)
        } catch {
            self.error = localizedErrorMessage(error)
        }
    }

    // MARK: - Local state helpers

    private func replaceCard(_ updatedCard: Card) {
        guard var copy = payload else { return }
        copy.cards = copy.cards.map { $0.id == updatedCard.id ? updatedCard : $0 }
        payload = copy
    }

    private func replaceTask(_ updatedTask: PlankaTask) {
        guard var copy = payload else { return }
        copy.tasks = copy.tasks.map { $0.id == updatedTask.id ? updatedTask : $0 }
        payload = copy
    }
}
