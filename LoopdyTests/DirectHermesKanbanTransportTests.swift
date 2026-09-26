import Foundation
import Testing
@testable import Loopdy

struct DirectHermesKanbanTransportTests {
    @Test func eventBatchRequiresAdvancingOrderedExactCursor() throws {
        let valid = try frame(ids: [11, 15], cursor: 15)
        let batch = try DirectHermesKanbanTransportBoundary.decodeEventBatch(valid, after: 10)
        #expect(batch.cursor == 15)
        #expect(batch.events.map(\.id) == [11, 15])
        for (ids, cursor) in [([10], 10), ([12, 11], 12), ([11, 11], 11), ([11], 12), ([], 11)] {
            let malformed = try frame(ids: ids, cursor: cursor)
            #expect(throws: HermesKanbanError.self) {
                try DirectHermesKanbanTransportBoundary.decodeEventBatch(malformed, after: 10)
            }
        }
        #expect(throws: HermesKanbanError.self) {
            try DirectHermesKanbanTransportBoundary.decodeEventBatch(.data(Data("{}".utf8)), after: 0)
        }
    }

    @Test func fixedMultipartPreservesBytesAndEncodesFilename() throws {
        let payload = Data([0, 1, 2, 13, 10, 255])
        let prepared = try DirectHermesKanbanTransportBoundary.prepare(.upload(
            board: "work", taskID: "t_01234567", filename: "résumé.txt", contentType: "text/plain",
            bytes: payload, uploadedBy: "Fixture", maximumResponseBytes: 256 * 1_024))
        #expect(prepared.route == "/api/plugins/kanban/tasks/t_01234567/attachments")
        #expect(prepared.method == "POST")
        #expect(prepared.query == [URLQueryItem(name: "board", value: "work")])
        let body = try #require(prepared.body)
        #expect(body.range(of: payload) != nil)
        let projection = String(decoding: body, as: UTF8.self)
        #expect(projection.contains("name=\"file\""))
        #expect(projection.contains("name=\"uploaded_by\""))
        #expect(projection.contains("filename*=UTF-8''r%C3%A9sum%C3%A9.txt"))
        #expect(!projection.contains("name=\"path\""))
    }

    @Test func boardAndTaskPathInjectionAreRejectedBeforeConstruction() throws {
        for board in ["../work", "work/other", "work?token=x", "", "Work"] {
            #expect(throws: HermesKanbanError.self) {
                try DirectHermesKanbanTransportBoundary.eventQuery(board: board, since: 0)
            }
        }
        #expect(throws: HermesKanbanError.self) {
            try DirectHermesKanbanTransportBoundary.prepare(.upload(
                board: "work", taskID: "t_01234567/other", filename: "file.txt", contentType: "text/plain",
                bytes: Data([1]), uploadedBy: "Fixture", maximumResponseBytes: 1_024))
        }
        #expect(throws: HermesKanbanError.self) {
            try DirectHermesKanbanTransportBoundary.prepare(.download(board: "work", attachmentID: 0, maximumBytes: 1_024))
        }
    }

    private func frame(ids: [Int], cursor: Int) throws -> URLSessionWebSocketTask.Message {
        let value: LoopdyJSONValue = .object([
            "cursor": .integer(cursor), "events": .array(ids.map { id in
                .object(["id": .integer(id), "task_id": .string("t_01234567"), "run_id": .null,
                    "kind": .string("task.updated"), "payload": .object([:]), "created_at": .integer(1)])
            })
        ])
        return .string(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }
}
