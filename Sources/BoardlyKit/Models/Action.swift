import Foundation

public struct Action: Codable, Identifiable, Sendable {
    public let id: String
    public let boardId: String?
    public let cardId: String
    public let userId: String?
    public let type: String
    public let data: AnyCodable
    public let createdAt: Date?
    public let updatedAt: Date?
}

public extension Action {
    /// The lists a card moved between, as PLANKA recorded them at the time of the move
    /// (`data.fromList` / `data.toList`). Names are kept alongside the ids because the
    /// recorded name survives a later rename — and a list may since have been deleted.
    struct ListMove: Sendable, Equatable {
        public let fromId: String?
        public let fromName: String?
        public let toId: String?
        public let toName: String?
    }

    /// `nil` unless this is a `moveCard` action carrying at least one of the two lists.
    var listMove: ListMove? {
        guard type == "moveCard", let data = data.value as? [String: AnyCodable] else { return nil }

        func list(_ key: String) -> (id: String?, name: String?) {
            guard let entry = data[key]?.value as? [String: AnyCodable] else { return (nil, nil) }
            return (entry["id"]?.value as? String, entry["name"]?.value as? String)
        }

        let from = list("fromList")
        let to = list("toList")
        guard from.id != nil || from.name != nil || to.id != nil || to.name != nil else { return nil }
        return ListMove(fromId: from.id, fromName: from.name, toId: to.id, toName: to.name)
    }
}
