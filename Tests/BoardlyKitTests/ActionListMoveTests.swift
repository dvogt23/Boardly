import Foundation
import Testing
@testable import BoardlyKit

/// `Action.listMove` — the `data.fromList` / `data.toList` pair PLANKA records on a
/// `moveCard` action, used by the card activity feed.
@Suite("Action.listMove")
struct ActionListMoveTests {
    private func action(type: String, data: String) throws -> Action {
        let json = """
        {
          "id": "a1",
          "boardId": "b1",
          "cardId": "c1",
          "userId": "u1",
          "type": "\(type)",
          "data": \(data),
          "createdAt": "2024-01-01T10:00:00.000Z",
          "updatedAt": "2024-01-01T10:00:00.000Z"
        }
        """
        return try JSONDecoder.planka.decode(Action.self, from: Data(json.utf8))
    }

    @Test("reads both lists from a moveCard payload")
    func readsBothLists() throws {
        let moved = try action(type: "moveCard", data: """
        {
          "card": { "name": "Card" },
          "fromList": { "id": "l1", "name": "Inbox", "type": "active" },
          "toList": { "id": "l2", "name": "Done", "type": "closed" }
        }
        """)
        #expect(moved.listMove == Action.ListMove(
            fromId: "l1", fromName: "Inbox", toId: "l2", toName: "Done"))
    }

    @Test("a list with no recorded name still yields its id")
    func namelessList() throws {
        let moved = try action(type: "moveCard", data: """
        { "fromList": { "id": "l1", "type": "active" }, "toList": { "id": "l2", "name": "Done" } }
        """)
        let move = try #require(moved.listMove)
        #expect(move.fromId == "l1")
        #expect(move.fromName == nil)
        #expect(move.toName == "Done")
    }

    @Test("nil for a non-move action, even when the data carries lists")
    func otherActionType() throws {
        let created = try action(type: "createCard", data: """
        { "fromList": { "id": "l1", "name": "Inbox" }, "toList": { "id": "l2", "name": "Done" } }
        """)
        #expect(created.listMove == nil)
    }

    @Test("nil when the move carries neither list")
    func noLists() throws {
        #expect(try action(type: "moveCard", data: #"{ "card": { "name": "Card" } }"#).listMove == nil)
    }

    @Test("nil when data is not an object")
    func dataNotAnObject() throws {
        #expect(try action(type: "moveCard", data: #""moved""#).listMove == nil)
    }
}
