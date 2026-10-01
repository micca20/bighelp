import Foundation
import Testing
@testable import Bighelp

@MainActor
struct KanbanBoardModelTests {
    /// The demo board, except moves can be made to fail like a host refusal.
    final class RefusingService: KanbanService {
        let demo = DemoKanbanService()
        var refusesMoves = false
        var autoPlan = false
        private(set) var movedTo: [HermesKanbanTaskStatus] = []

        func isAvailable() async throws -> Bool { true }
        func boards() async throws -> [HermesKanbanBoard] { try await demo.boards() }
        func board(_ slug: String) async throws -> HermesKanbanBoardSnapshot { try await demo.board(slug) }
        func task(_ id: String, board: String) async throws -> HermesKanbanTaskDetail { try await demo.task(id, board: board) }
        func activeWorkers(board: String) async throws -> [HermesKanbanActiveWorker] { [] }
        func orchestration() async throws -> HermesKanbanOrchestration {
            let value = try await demo.setAutoPlan(autoPlan)
            return value
        }
        func move(_ taskID: String, to status: HermesKanbanTaskStatus, board: String) async throws -> HermesKanbanTaskDetail {
            if refusesMoves { throw HermesKanbanError.operationRefused }
            movedTo.append(status)
            return try await demo.move(taskID, to: status, board: board)
        }
        func edit(_ taskID: String, board: String, patch: HermesKanbanTaskPatch) async throws -> HermesKanbanTaskDetail {
            try await demo.edit(taskID, board: board, patch: patch)
        }
        func reassign(_ taskID: String, to profile: String?, board: String) async throws -> HermesKanbanTaskDetail {
            try await demo.reassign(taskID, to: profile, board: board)
        }
        func comment(_ body: String, on taskID: String, board: String) async throws -> HermesKanbanTaskDetail {
            try await demo.comment(body, on: taskID, board: board)
        }
        func create(_ draft: HermesKanbanTaskDraft, board: String) async throws -> HermesKanbanTaskDetail {
            try await demo.create(draft, board: board)
        }
        func createBoard(named name: String) async throws -> [HermesKanbanBoard] { try await demo.createBoard(named: name) }
        func startReadyWork(board: String) async throws -> HermesKanbanBoardSnapshot { try await demo.startReadyWork(board: board) }
        func setAutoPlan(_ isOn: Bool) async throws -> HermesKanbanOrchestration {
            autoPlan = isOn
            return try await demo.setAutoPlan(isOn)
        }
        func liveBoards(_ slug: String, since cursor: Int) throws -> AsyncThrowingStream<HermesKanbanBoardSnapshot, any Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private func model(_ service: KanbanService = DemoKanbanService()) async -> KanbanBoardModel {
        let defaults = UserDefaults(suiteName: "kanban-tests-\(UUID().uuidString)")!
        let model = KanbanBoardModel(service: service, agents: [
            KanbanAgent(id: "finance", name: "Avery Park", imageURL: nil),
            KanbanAgent(id: "travel", name: "Mina Shah", imageURL: nil),
            KanbanAgent(id: "home", name: "Jordan Lee", imageURL: nil),
        ], defaults: defaults, publishWidget: { _ in })
        await model.start()
        return model
    }

    @Test func everyHermesStatusHasOneLane() {
        #expect(KanbanLane(status: .triage) == .later)
        #expect(KanbanLane(status: .todo) == .later)
        #expect(KanbanLane(status: .scheduled) == .later)
        #expect(KanbanLane(status: .ready) == .ready)
        #expect(KanbanLane(status: .running) == .working)
        #expect(KanbanLane(status: .blocked) == .needsYou)
        #expect(KanbanLane(status: .review) == .needsYou)
        #expect(KanbanLane(status: .done) == .done)
        #expect(KanbanLane(status: .archived) == nil)
        // Only Hermes' dispatcher starts work.
        #expect(KanbanLane.working.dropStatus == nil)
        #expect(KanbanLane.allCases.compactMap(\.dropStatus).allSatisfy { $0.canBeSetDirectly })
    }

    @Test func startsOnTheRememberedOrCurrentBoard() async {
        let model = await model()
        #expect(model.phase == .ready)
        #expect(model.board?.slug == "launch")
        #expect(model.count(in: .needsYou) == 3)
        #expect(model.count(in: .working) == 2)
    }

    @Test func aMoveShowsAtOnceAndSticks() async {
        let model = await model()
        let quotes = model.task("t_quotes")!
        await model.move(quotes, to: .done)
        #expect(model.task("t_quotes")?.lane == .done)
        #expect(model.notice == nil)
    }

    @Test func aRefusedMoveSnapsBackWithAPlainReason() async {
        let service = RefusingService()
        let model = await model(service)
        service.refusesMoves = true
        await model.move(model.task("t_quotes")!, to: .done)
        #expect(model.task("t_quotes")?.lane == .ready)
        #expect(model.notice?.text.contains("waiting on another task") == true)
    }

    @Test func nothingIsDroppedIntoWorking() async {
        let service = RefusingService()
        let model = await model(service)
        await model.move(model.task("t_quotes")!, to: .working)
        #expect(service.movedTo.isEmpty)
        #expect(model.task("t_quotes")?.lane == .ready)
    }

    /// Hermes makes a new task ready at once; a card for Later must not be
    /// picked up, so it goes through planning and is filed as to-do.
    @Test(arguments: [false, true])
    func laterCardsWaitUnlessAutoPlanIsOn(autoPlan: Bool) async {
        let service = RefusingService()
        service.autoPlan = autoPlan
        let model = await model(service)
        #expect(await model.create(title: "Order stickers", lane: .later, assignee: "home"))
        let created = model.snapshot?.tasks.first { $0.title == "Order stickers" }
        #expect(created?.status == (autoPlan ? .triage : .todo))
        #expect(created?.assignee == "home")
        #expect(service.movedTo == (autoPlan ? [] : [.todo]))
    }

    @Test func readyCardsGoStraightToAnAgent() async {
        let model = await model()
        #expect(await model.create(title: "Write the tweet", lane: .ready, assignee: "travel", priority: .high))
        let created = model.snapshot?.tasks.first { $0.title == "Write the tweet" }
        #expect(created?.status == .ready)
        #expect(created?.urgency == .high)
    }

    @Test func anAnswerGoesBackToTheAgent() async {
        let model = await model()
        let question = model.task("t_date")!
        #expect(question.statusNote == "Has a question")
        #expect(await model.reply("Saturday works.", to: question))
        #expect(model.task("t_date")?.status == .ready)
        let detail = await model.detail(model.task("t_date")!)
        #expect(detail?.comments.last?.body == "Saturday works.")
    }

    @Test func approvingAReviewFinishesIt() async {
        let model = await model()
        await model.approve(model.task("t_budget")!)
        #expect(model.task("t_budget")?.lane == .done)
    }

    @Test func filtersByAgentAndSearch() async {
        let model = await model()
        model.agentFilter = .agent("travel")
        #expect(model.visibleTasks.allSatisfy { $0.assignee == "travel" })
        #expect(!model.visibleTasks.isEmpty)
        model.agentFilter = .unassigned
        #expect(model.visibleTasks.map(\.id) == ["t_store"])
        model.agentFilter = .everyone
        model.searchText = "budget"
        #expect(Set(model.visibleTasks.map(\.id)) == ["t_budget"])
    }

    @Test func saysWhenNobodyIsPickingUpWork() async {
        let model = await model(RefusingService())
        // Ready, assigned and over two minutes old, with no worker running.
        #expect(model.nobodyIsPickingUpWork)
    }

    @Test func switchingBoardsIsRemembered() async {
        let defaults = UserDefaults(suiteName: "kanban-tests-\(UUID().uuidString)")!
        let first = KanbanBoardModel(service: DemoKanbanService(), agents: [], defaults: defaults, publishWidget: { _ in })
        await first.start()
        await first.select(board: "japan")
        let second = KanbanBoardModel(service: DemoKanbanService(), agents: [], defaults: defaults, publishWidget: { _ in })
        await second.start()
        #expect(second.board?.slug == "japan")
    }

    @Test func boardSlugsFollowHermesRules() {
        #expect(LiveKanbanService.slug(for: "Café & Launch!") == "caf-launch")
        #expect(LiveKanbanService.slug(for: "  ") == "board")
        #expect(LiveKanbanService.slug(for: "Home", avoiding: ["home", "home-2"]) == "home-3")
        #expect(LiveKanbanService.slug(for: String(repeating: "a", count: 90)).count <= 64)
    }

    @Test func widgetKeepsOtherBoardsAndDropsGoneOnes() async throws {
        let demo = DemoKanbanService()
        let boards = try await demo.boards()
        var snapshot = BighelpKanbanSnapshot()
        snapshot.cards = [
            .init(id: "old", board: "home", title: "Kept", lane: .ready, assignee: nil, priority: 0, updatedAt: .now),
            .init(id: "gone", board: "deleted", title: "Gone", lane: .ready, assignee: nil, priority: 0, updatedAt: .now),
        ]
        let launch = try await demo.board("launch")
        let merged = KanbanWidgetPublisher.merged(snapshot, boards: boards, board: launch,
                                                  agents: [KanbanAgent(id: "finance", name: "Avery Park", imageURL: nil)])
        #expect(merged.cards.contains { $0.id == "old" })
        #expect(!merged.cards.contains { $0.id == "gone" })
        #expect(merged.cards.filter { $0.board == "launch" }.count == launch.tasks.count)
        #expect(merged.cards.first { $0.id == "t_date" }?.note == "Has a question")
        #expect(merged.agents.contains { $0.id == "finance" && $0.name == "Avery Park" })
        #expect(Set(merged.boards.map(\.id)) == ["launch", "home", "japan"])
    }

    @Test func kanbanLinksOpenABoardOrACard() {
        let url = BighelpKanbanSnapshot.url(board: "launch", task: "t_date")
        #expect(BighelpIncomingURLRoute.parse(url) == .kanban(board: "launch", task: "t_date"))
        #expect(BighelpIncomingURLRoute.parse(URL(string: "loopdy://kanban")!) == .kanban(board: nil, task: nil))
    }
}
