import Foundation
import SwiftData

/// A mutation made while offline (or one that failed on a flaky connection), waiting to
/// be replayed against the server. Entries replay in `createdAt` order per profile, so
/// "create card, then rename it" can't arrive the wrong way round.
@Model
final class PendingMutation {
    @Attribute(.unique) var id: UUID
    var profileId: String
    var boardId: String
    var kindRaw: String
    /// The entity the mutation targets — a card, task or card id. For work queued
    /// against something also created offline this is a local id, rewritten to the real
    /// one once the create replays (see `SyncEngine`).
    var targetId: String
    /// Kind-specific arguments, encoded with `MutationPayload`.
    var payload: Data
    var createdAt: Date
    var attempts: Int
    var lastError: String?

    var kind: MutationKind? { MutationKind(rawValue: kindRaw) }

    init(
        id: UUID = UUID(),
        profileId: String,
        boardId: String,
        kind: MutationKind,
        targetId: String,
        payload: Data,
        createdAt: Date,
        attempts: Int = 0,
        lastError: String? = nil)
    {
        self.id = id
        self.profileId = profileId
        self.boardId = boardId
        kindRaw = kind.rawValue
        self.targetId = targetId
        self.payload = payload
        self.createdAt = createdAt
        self.attempts = attempts
        self.lastError = lastError
    }
}

/// The mutations that may be made offline. Deliberately the core card loop — anything
/// outside it (labels, members, attachments, custom fields, admin) stays online-only,
/// so the queue never holds work whose failure the user can't reason about.
public enum MutationKind: String, Codable, Sendable {
    case createCard
    case updateCard
    case deleteCard
    case createTask
    case updateTask
    case deleteTask
    case createComment
}

/// Arguments for a queued mutation. One case per `MutationKind`, encoded into
/// `PendingMutation.payload`.
///
/// The edits are described with plain fields rather than by storing a `CardPatch` /
/// `TaskPatch`: those are the wire types, `Encodable`-only and shaped by what PLANKA
/// expects on the request. The queue needs to round-trip through disk, so it keeps its
/// own representation and builds the patch at replay time.
public enum MutationPayload: Codable, Sendable, Equatable {
    case createCard(listId: String, name: String, position: Double, type: String)
    /// A move is just an edit of `listId` + `position`, so it needs no case of its own.
    case updateCard(CardEdit)
    case deleteCard
    case createTask(taskListId: String, name: String, position: Double)
    case updateTask(TaskEdit)
    case deleteTask
    case createComment(cardId: String, text: String)

    var kind: MutationKind {
        switch self {
        case .createCard: .createCard
        case .updateCard: .updateCard
        case .deleteCard: .deleteCard
        case .createTask: .createTask
        case .updateTask: .updateTask
        case .deleteTask: .deleteTask
        case .createComment: .createComment
        }
    }
}

/// The fields of a card a queued edit may change.
public struct CardEdit: Codable, Sendable, Equatable {
    public var name: String?
    public var description: String?
    public var listId: String?
    public var position: Double?
    public var dueDate: Date?
    /// Distinguishes "don't touch the due date" (`nil` dueDate) from "remove it".
    public var clearDueDate: Bool

    public init(
        name: String? = nil,
        description: String? = nil,
        listId: String? = nil,
        position: Double? = nil,
        dueDate: Date? = nil,
        clearDueDate: Bool = false)
    {
        self.name = name
        self.description = description
        self.listId = listId
        self.position = position
        self.dueDate = dueDate
        self.clearDueDate = clearDueDate
    }

    public var patch: CardPatch {
        CardPatch(
            name: name,
            description: description,
            listId: listId,
            position: position,
            dueDate: dueDate,
            clearDueDate: clearDueDate)
    }
}

/// The fields of a task a queued edit may change.
public struct TaskEdit: Codable, Sendable, Equatable {
    public var name: String?
    public var isCompleted: Bool?

    public init(name: String? = nil, isCompleted: Bool? = nil) {
        self.name = name
        self.isCompleted = isCompleted
    }

    public var patch: TaskPatch { TaskPatch(name: name, isCompleted: isCompleted) }
}

/// A queued mutation lifted out of SwiftData: `@Model` instances belong to their
/// context, so the store hands back a value type instead.
public struct QueuedMutation: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let profileId: String
    public let boardId: String
    public let kind: MutationKind
    public let targetId: String
    public let payload: MutationPayload
    public let createdAt: Date
    public let attempts: Int
    public let lastError: String?
}

/// Ids minted for entities created offline. The prefix is what tells the sync engine
/// (and the UI) that the server has never seen this row.
public enum LocalID {
    static let prefix = "local:"

    public static func make() -> String { prefix + UUID().uuidString }

    public static func isLocal(_ id: String) -> Bool { id.hasPrefix(prefix) }
}
