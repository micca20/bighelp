import Foundation
import Testing
@testable import Bighelp

/// The ☰ menu's Kanban row: it vanished after returning to the app when the
/// check made while reconnecting failed, and stayed gone until the next reconnect.
@MainActor
struct KanbanAvailabilityTests {
    struct Offline: Error {}

    private func availability() -> KanbanAvailability {
        KanbanAvailability(defaults: UserDefaults(suiteName: "kanban-availability-\(UUID().uuidString)")!,
                           retryDelays: [.milliseconds(1), .milliseconds(1)])
    }

    @Test func aCheckThatFailsWhileReconnectingKeepsKanban() async {
        let kanban = availability()
        kanban.use(host: "home")
        await kanban.check { true }
        #expect(kanban.isAvailable == true)

        // Back in the app: same computer, new connection, and the host doesn't answer yet.
        #expect(kanban.use(host: "home") == false, "Reconnecting isn't a different computer")
        await kanban.check { throw Offline() }
        #expect(kanban.isAvailable == true, "A failed question isn't a no")
    }

    @Test func aFailedCheckIsTriedAgain() async {
        let kanban = availability()
        kanban.use(host: "home")
        var calls = 0
        await kanban.check {
            calls += 1
            if calls < 3 { throw Offline() }
            return true
        }
        #expect(calls == 3)
        #expect(kanban.isAvailable == true)
    }

    @Test func onlyTheHostSayingNoHidesKanban() async {
        let kanban = availability()
        kanban.use(host: "home")
        await kanban.check { true }
        await kanban.check { false }
        #expect(kanban.isAvailable == false)
    }

    @Test func eachComputerKeepsItsOwnAnswer() async {
        let defaults = UserDefaults(suiteName: "kanban-availability-\(UUID().uuidString)")!
        let kanban = KanbanAvailability(defaults: defaults, retryDelays: [])
        kanban.use(host: "home")
        await kanban.check { true }
        #expect(kanban.use(host: "office"), "Another computer starts fresh")
        #expect(kanban.isAvailable == nil)
        await kanban.check { false }

        // Coming back to a computer, or relaunching, shows its last answer at once.
        kanban.use(host: "home")
        #expect(kanban.isAvailable == true)
        let relaunched = KanbanAvailability(defaults: defaults, retryDelays: [])
        relaunched.use(host: "office")
        #expect(relaunched.isAvailable == false)
        relaunched.use(host: nil)
        #expect(relaunched.isAvailable == nil, "No computer, no Kanban")
    }

    @Test func anAnswerForAnotherComputerIsDropped() async {
        let kanban = availability()
        kanban.use(host: "home")
        await kanban.check {
            kanban.use(host: "office")
            return true
        }
        #expect(kanban.host == "office" && kanban.isAvailable == nil)
    }
}
