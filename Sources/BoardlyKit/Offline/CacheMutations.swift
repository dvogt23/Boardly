import Foundation

// Applying a queued edit to a cached entity. The models are immutable value types, so
// each helper rebuilds one with the edited fields replaced — which also keeps the "what
// can an offline edit touch" list in one readable place.

extension Card {
    /// A card created offline: server-assigned fields stay empty until the create replays.
    static func local(
        id: String,
        boardId: String,
        listId: String,
        name: String,
        position: Double,
        type: String,
        createdAt: Date) -> Card
    {
        Card(
            id: id,
            boardId: boardId,
            listId: listId,
            creatorUserId: nil,
            prevListId: nil,
            coverAttachmentId: nil,
            type: type,
            position: position,
            name: name,
            description: nil,
            dueDate: nil,
            isDueCompleted: nil,
            stopwatch: nil,
            commentsTotal: 0,
            isClosed: false,
            listChangedAt: nil,
            createdAt: createdAt,
            updatedAt: nil)
    }

    func applying(_ edit: CardEdit) -> Card {
        Card(
            id: id,
            boardId: boardId,
            listId: edit.listId ?? listId,
            creatorUserId: creatorUserId,
            prevListId: edit.listId == nil ? prevListId : listId,
            coverAttachmentId: coverAttachmentId,
            type: type,
            position: edit.position ?? position,
            name: edit.name ?? name,
            description: edit.description ?? description,
            dueDate: edit.clearDueDate ? nil : (edit.dueDate ?? dueDate),
            isDueCompleted: isDueCompleted,
            stopwatch: stopwatch,
            commentsTotal: commentsTotal,
            isClosed: isClosed,
            listChangedAt: listChangedAt,
            createdAt: createdAt,
            updatedAt: updatedAt)
    }

    func withId(_ newId: String) -> Card {
        Card(
            id: newId,
            boardId: boardId,
            listId: listId,
            creatorUserId: creatorUserId,
            prevListId: prevListId,
            coverAttachmentId: coverAttachmentId,
            type: type,
            position: position,
            name: name,
            description: description,
            dueDate: dueDate,
            isDueCompleted: isDueCompleted,
            stopwatch: stopwatch,
            commentsTotal: commentsTotal,
            isClosed: isClosed,
            listChangedAt: listChangedAt,
            createdAt: createdAt,
            updatedAt: updatedAt)
    }
}

extension PlankaTask {
    func applying(_ edit: TaskEdit) -> PlankaTask {
        PlankaTask(
            id: id,
            taskListId: taskListId,
            linkedCardId: linkedCardId,
            assigneeUserId: assigneeUserId,
            position: position,
            name: edit.name ?? name,
            isCompleted: edit.isCompleted ?? isCompleted,
            createdAt: createdAt,
            updatedAt: updatedAt)
    }

    func withId(_ newId: String) -> PlankaTask {
        PlankaTask(
            id: newId,
            taskListId: taskListId,
            linkedCardId: linkedCardId,
            assigneeUserId: assigneeUserId,
            position: position,
            name: name,
            isCompleted: isCompleted,
            createdAt: createdAt,
            updatedAt: updatedAt)
    }
}
