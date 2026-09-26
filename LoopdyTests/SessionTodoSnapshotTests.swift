import Foundation
import Testing
@testable import Loopdy

struct SessionTodoSnapshotTests {
    @Test func explicitEmptySnapshotSurvivesPersistenceAndRejectsOlderState() throws {
        let active = snapshot(revision: 1, todos: [item])
        let empty = snapshot(revision: 2, todos: [])
        #expect(empty.supersedes(active))
        let restored = try JSONDecoder().decode(SessionTodoSnapshot.self, from: JSONEncoder().encode(empty))
        #expect(restored == empty)
        #expect(restored.todos.isEmpty)
        #expect(!active.supersedes(restored))
        #expect(!snapshot(revision: 2, todos: [item]).supersedes(restored))
    }

    @Test func malformedFullSnapshotCannotBecomeAnEmptyOrPartialList() {
        let valid: LoopdyJSONValue = .object([
            "id": .string("one"), "content": .string("Keep visible"), "status": .string("in_progress"),
        ])
        for rows in [[valid, .null], [valid, valid], [.object(["id": .string("bad")])]] {
            #expect(SessionTodoSnapshot.canonical(sessionID: "chat", revision: 2, values: rows, updatedAt: 1) == nil)
        }
        #expect(SessionTodoSnapshot.canonical(sessionID: "chat", revision: 2, values: [], updatedAt: 1)?.todos == [])
    }

    @Test func snapshotCannotCrossItsExactSessionIdentity() {
        let prior = SessionTodoSnapshot(sessionID: "chat:\u{00e9}", revision: 1, todos: [item], updatedAt: 1)
        let other = SessionTodoSnapshot(sessionID: "chat:e\u{0301}", revision: 2, todos: [], updatedAt: 2)
        #expect(!other.supersedes(prior))
    }

    @Test(arguments: ["", " ", "\t\n", " padded", "padded "])
    func malformedOuterWhitespaceIDsAreRejected(id: String) {
        #expect(!snapshot(revision: 1, todos: [.init(id: id, content: "Task", status: .pending)]).isValid)
    }

    @Test func producerLongAndInternalWhitespaceIDsRemainLiteral() throws {
        for id in [String(repeating: "x", count: 256), "task  with   spaces"] {
            let value = snapshot(revision: 1, todos: [.init(id: id, content: "Task", status: .pending)])
            #expect(value.isValid)
            let restored = try JSONDecoder().decode(SessionTodoSnapshot.self, from: JSONEncoder().encode(value))
            #expect(Data(restored.todos[0].id.utf8) == Data(id.utf8))
        }
    }

    private var item: ChatTaskItem { .init(id: "one", content: "Keep visible", status: .inProgress) }
    private func snapshot(revision: Int, todos: [ChatTaskItem]) -> SessionTodoSnapshot {
        .init(sessionID: "chat", revision: revision, todos: todos, updatedAt: 1)
    }
}
