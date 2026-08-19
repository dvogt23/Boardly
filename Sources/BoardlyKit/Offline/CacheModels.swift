import Foundation
import SwiftData

// The local-first cache. Every row stores two things: the columns the cache needs to
// *query* on (which profile, which board, which parent, position, dirty state) and the
// entity itself as the JSON the server sent — decoded straight back into the same
// `Codable` models the rest of the app already uses.
//
// Keeping the body opaque is deliberate: mirroring all ~15 PLANKA entities field by
// field would mean a second schema to migrate every time a model gains a property,
// and PLANKA's payloads grow. A local edit re-encodes the mutated struct into `json`
// and flips `isDirty`, so fidelity never depends on the cache knowing every field.
//
// Rows are keyed `"<profileId>|<entityId>"`, because the same board id can exist on
// two different PLANKA instances.

/// Builds the row key shared by every cached entity.
func cacheKey(profileId: String, id: String) -> String { "\(profileId)|\(id)" }

@Model
final class CachedBoard {
    @Attribute(.unique) var key: String
    var profileId: String
    var boardId: String
    var json: Data
    /// Read-only entities the offline write set never touches (attachments, board
    /// memberships, custom fields) kept as one blob, so a cached board still restores
    /// a complete `BoardPayload` without a model class each.
    var extrasJSON: Data
    var cachedAt: Date

    init(profileId: String, boardId: String, json: Data, extrasJSON: Data, cachedAt: Date) {
        key = cacheKey(profileId: profileId, id: boardId)
        self.profileId = profileId
        self.boardId = boardId
        self.json = json
        self.extrasJSON = extrasJSON
        self.cachedAt = cachedAt
    }
}

@Model
final class CachedList {
    @Attribute(.unique) var key: String
    var profileId: String
    var boardId: String
    var listId: String
    var json: Data

    init(profileId: String, boardId: String, listId: String, json: Data) {
        key = cacheKey(profileId: profileId, id: listId)
        self.profileId = profileId
        self.boardId = boardId
        self.listId = listId
        self.json = json
    }
}

@Model
final class CachedCard {
    @Attribute(.unique) var key: String
    var profileId: String
    var boardId: String
    var listId: String
    var cardId: String
    var json: Data
    /// Edited locally and not yet accepted by the server.
    var isDirty: Bool
    /// Created offline — its id is local until the queued create replays.
    var isLocalOnly: Bool

    init(
        profileId: String,
        boardId: String,
        listId: String,
        cardId: String,
        json: Data,
        isDirty: Bool = false,
        isLocalOnly: Bool = false)
    {
        key = cacheKey(profileId: profileId, id: cardId)
        self.profileId = profileId
        self.boardId = boardId
        self.listId = listId
        self.cardId = cardId
        self.json = json
        self.isDirty = isDirty
        self.isLocalOnly = isLocalOnly
    }
}

@Model
final class CachedTaskList {
    @Attribute(.unique) var key: String
    var profileId: String
    var boardId: String
    var cardId: String
    var taskListId: String
    var json: Data

    init(profileId: String, boardId: String, cardId: String, taskListId: String, json: Data) {
        key = cacheKey(profileId: profileId, id: taskListId)
        self.profileId = profileId
        self.boardId = boardId
        self.cardId = cardId
        self.taskListId = taskListId
        self.json = json
    }
}

@Model
final class CachedTask {
    @Attribute(.unique) var key: String
    var profileId: String
    var boardId: String
    var taskListId: String
    var taskId: String
    var json: Data
    var isDirty: Bool
    var isLocalOnly: Bool

    init(
        profileId: String,
        boardId: String,
        taskListId: String,
        taskId: String,
        json: Data,
        isDirty: Bool = false,
        isLocalOnly: Bool = false)
    {
        key = cacheKey(profileId: profileId, id: taskId)
        self.profileId = profileId
        self.boardId = boardId
        self.taskListId = taskListId
        self.taskId = taskId
        self.json = json
        self.isDirty = isDirty
        self.isLocalOnly = isLocalOnly
    }
}

@Model
final class CachedLabel {
    @Attribute(.unique) var key: String
    var profileId: String
    var boardId: String
    var labelId: String
    var json: Data

    init(profileId: String, boardId: String, labelId: String, json: Data) {
        key = cacheKey(profileId: profileId, id: labelId)
        self.profileId = profileId
        self.boardId = boardId
        self.labelId = labelId
        self.json = json
    }
}

/// Card↔label join rows. Keyed on the pair, since neither side is unique alone.
@Model
final class CachedCardLabel {
    @Attribute(.unique) var key: String
    var profileId: String
    var boardId: String
    var json: Data

    init(profileId: String, boardId: String, id: String, json: Data) {
        key = cacheKey(profileId: profileId, id: id)
        self.profileId = profileId
        self.boardId = boardId
        self.json = json
    }
}

@Model
final class CachedCardMembership {
    @Attribute(.unique) var key: String
    var profileId: String
    var boardId: String
    var json: Data

    init(profileId: String, boardId: String, id: String, json: Data) {
        key = cacheKey(profileId: profileId, id: id)
        self.profileId = profileId
        self.boardId = boardId
        self.json = json
    }
}

/// The projects → boards list, one row per profile. Kept as a single blob rather than
/// project and board rows: the screen always renders the whole list at once, and nothing
/// queries across it. Board *contents* live in the row-based tables above.
@Model
final class CachedProjects {
    @Attribute(.unique) var profileId: String
    var json: Data
    var cachedAt: Date

    init(profileId: String, json: Data, cachedAt: Date) {
        self.profileId = profileId
        self.json = json
        self.cachedAt = cachedAt
    }
}

/// Users are cached per profile rather than per board — the same person appears on
/// every board of an instance.
@Model
final class CachedUser {
    @Attribute(.unique) var key: String
    var profileId: String
    var userId: String
    var json: Data

    init(profileId: String, userId: String, json: Data) {
        key = cacheKey(profileId: profileId, id: userId)
        self.profileId = profileId
        self.userId = userId
        self.json = json
    }
}

/// Comments are fetched per card rather than with the board payload, so they get their
/// own rows and their own dirty state.
@Model
final class CachedComment {
    @Attribute(.unique) var key: String
    var profileId: String
    var boardId: String
    var cardId: String
    var commentId: String
    var json: Data
    var isLocalOnly: Bool

    init(
        profileId: String,
        boardId: String,
        cardId: String,
        commentId: String,
        json: Data,
        isLocalOnly: Bool = false)
    {
        key = cacheKey(profileId: profileId, id: commentId)
        self.profileId = profileId
        self.boardId = boardId
        self.cardId = cardId
        self.commentId = commentId
        self.json = json
        self.isLocalOnly = isLocalOnly
    }
}

/// The entities the cache stores as rows. `OfflineStore.makeContainer` needs the list,
/// and so do tests building an in-memory container.
let cachedModels: [any PersistentModel.Type] = [
    CachedBoard.self,
    CachedList.self,
    CachedCard.self,
    CachedTaskList.self,
    CachedTask.self,
    CachedLabel.self,
    CachedCardLabel.self,
    CachedCardMembership.self,
    CachedProjects.self,
    CachedUser.self,
    CachedComment.self,
    PendingMutation.self,
]
