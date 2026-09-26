#if DEBUG
import Foundation

/// Curated, realistic content for App Store screenshots
/// (`-use-demo-fixtures -app-store-screenshots`). Test fixtures, regression
/// sessions and placeholder copy stay out of frame. Times sit just before the
/// 9:41 status-bar time so the story reads like one morning.
@MainActor
enum AppStoreScreenshotFixture {
    static let launchArgument = "-app-store-screenshots"
    static let kyotoID = "store-kyoto"
    static let groupRoomID = "dinner-party"

    static func time(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: .now)) ?? .now
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    private static let agentNames = ["finance": "Avery Park", "travel": "Mina Shah", "home": "Jordan Lee"]

    private static func message(_ id: String, agent: String?, _ text: String, at date: Date, order: Int) -> TimelineItem {
        TimelineItem(
            id: id,
            role: agent == nil ? .human : .assistant,
            sender: agent.map { .agent(id: $0, snapshot: .init(name: agentNames[$0] ?? $0)) }
                ?? .user(snapshot: .init(name: "You")),
            content: .message(text),
            metadata: .init(delivery: "Saved", timestamp: date, sourceOrder: order)
        )
    }

    private static func chat(_ id: String, agent: String, title: String,
                             _ turns: [(fromAgent: Bool, text: String, at: Date)]) -> SessionRecord {
        let items = turns.enumerated().map { index, turn in
            message("\(id)-\(index)", agent: turn.fromAgent ? agent : nil, turn.text, at: turn.at, order: index + 1)
        }
        let updated = turns.last?.at ?? .now
        return SessionRecord(id: id, kind: .direct, agentIDs: [agent], title: title, items: items,
                             createdAt: turns.first?.at ?? updated, updatedAt: updated, hasAcceptedMessage: true)
    }

    static var sessions: [SessionRecord] {
        [
            chat(kyotoID, agent: "travel", title: "Kyoto weekend", [
                (false, "Can you plan a long weekend in Kyoto? We love food and quiet temples.", time(9, 31)),
                (true, """
                    I’d love to! Here’s a relaxed plan:

                    **Friday** · Temples in Higashiyama
                    **Saturday** · Arashiyama bamboo grove
                    **Sunday** · Nishiki Market food crawl

                    Want a cozy dinner spot too?
                    """, time(9, 32)),
                (false, "Yes please! Somewhere quiet on Saturday.", time(9, 36)),
                (true, "Done. Table for two in Gion, Saturday at 7:00 PM. Details are in your email. 🍵", time(9, 38)),
            ]),
            chat("store-budget", agent: "finance", title: "September budget", [
                (false, "How are we doing on the budget this month?", time(8, 52)),
                (true, "You’re $120 under budget with a week to go. Groceries are the only category running a little high.", time(8, 55)),
            ]),
            chat("store-faucet", agent: "home", title: "Leaky kitchen faucet", [
                (false, "The kitchen faucet is dripping again. Can you find someone?", time(16, 10, daysAgo: 1)),
                (true, "Two well-reviewed plumbers can come Thursday morning. Want me to book the 9 AM slot?", time(16, 14, daysAgo: 1)),
            ]),
            chat("store-brief", agent: "finance", title: "Morning brief", [
                (false, "Morning brief, please.", time(8, 0, daysAgo: 1)),
                (true, "Three bills are due this week and all of them are on autopay. Nothing needs you today.", time(8, 1, daysAgo: 1)),
            ]),
            chat("store-lisbon", agent: "travel", title: "Lisbon flights", [
                (false, "Keep an eye on flights to Lisbon for October.", time(19, 5, daysAgo: 2)),
                (true, "Fares just dropped 18% for October 9–16. Want me to hold two seats?", time(19, 20, daysAgo: 2)),
            ]),
            chat("store-gifts", agent: "home", title: "Birthday gift ideas", [
                (false, "Ideas for Sam’s birthday? She loves gardening.", time(12, 30, daysAgo: 3)),
                (true, "Here are five ideas under $50, sorted by what can arrive before Saturday.", time(12, 34, daysAgo: 3)),
            ]),
        ]
    }

    static var tasks: [ScheduledTask] {
        let zone = TimeZone.current.identifier
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        func next(_ hour: Int, _ minute: Int = 0, inDays days: Int = 1) -> Date {
            let day = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: .now)) ?? tomorrow
            return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        return [
            .fixture(id: "store-task-brief", agentID: "finance", name: "Morning brief",
                     instructions: "Bills due, spending so far and anything that needs me today.",
                     schedule: .daily(time: DateComponents(hour: 8, minute: 0), timeZoneID: zone),
                     nextRun: next(8), lastResult: "Completed today at 8:01 AM"),
            .fixture(id: "store-task-flights", agentID: "travel", name: "Lisbon flight watch",
                     instructions: "Check fares to Lisbon for October and tell me when they drop.",
                     schedule: .daily(time: DateComponents(hour: 19, minute: 0), timeZoneID: zone),
                     nextRun: next(19, inDays: 0)),
            .fixture(id: "store-task-budget", agentID: "finance", name: "Weekly budget check-in",
                     instructions: "Compare this week’s spending with the plan.",
                     schedule: .weekly(day: .monday, time: DateComponents(hour: 9, minute: 0), timeZoneID: zone),
                     nextRun: next(9, inDays: 3)),
            .fixture(id: "store-task-plants", agentID: "home", name: "Water the plants",
                     instructions: "Remind me to water the balcony plants.",
                     schedule: .repeating(days: [.tuesday, .friday], time: DateComponents(hour: 18, minute: 30),
                                          timeZoneID: zone),
                     nextRun: next(18, 30, inDays: 2)),
            .fixture(id: "store-task-trip", agentID: "travel", name: "Trip countdown",
                     instructions: "A week before a trip, check the weather and what to pack.",
                     schedule: .weekly(day: .friday, time: DateComponents(hour: 15, minute: 0), timeZoneID: zone),
                     isPaused: true, nextRun: next(15, inDays: 5)),
        ]
    }

    static var groupRoom: HermesBotModeRoomState {
        .init(
            roomID: groupRoomID, name: "Dinner party crew",
            members: [("finance", "avery"), ("home", "jordan"), ("travel", "mina")].map { profile, handle in
                .init(memberID: "member-\(profile)", profile: profile, handle: handle,
                      displayName: agentNames[profile] ?? profile,
                      target: ["kind": .string("local"), "profile": .string(profile)])
            },
            authorityGatewayID: "fixture-gateway", authorityEpoch: 1, revision: 1,
            createdAt: time(21, 10, daysAgo: 1).timeIntervalSince1970,
            updatedAt: time(21, 20, daysAgo: 1).timeIntervalSince1970,
            latestSequence: groupEvents.count, disbandedAt: nil, driverStatus: nil
        )
    }

    static var groupEvents: [HermesBotModeEvent] {
        let lines: [(member: String?, text: String, at: Date)] = [
            (nil, "Hosting eight friends for dinner on Saturday. Can you three split up the planning?", time(21, 12, daysAgo: 1)),
            ("finance", "On it. Let’s keep it to $240, about $30 a person. I’ll track receipts as they come in.",
             time(21, 13, daysAgo: 1)),
            ("home", "I’ll make the grocery list and a prep timeline so everything is hot by 7.", time(21, 15, daysAgo: 1)),
            ("travel", "Wine is covered: a shop near you delivers Saturday at 11. Two reds and a white.",
             time(21, 17, daysAgo: 1)),
            (nil, "You’re the best. Thank you!", time(21, 20, daysAgo: 1)),
        ]
        return lines.enumerated().map { index, line in
            var payload: [String: BighelpJSONValue] = ["text": .string(line.text), "thread_id": .string("store-thread")]
            if let member = line.member { payload["member_id"] = .string("member-\(member)") }
            return HermesBotModeEvent(
                roomID: groupRoomID, sequence: index + 1, eventID: "store-group-\(index + 1)",
                kind: line.member == nil ? "message.user" : "message.member",
                actor: line.member.map { ["member_id": .string("member-\($0)")] } ?? ["kind": .string("user")],
                authorityEpoch: 1, payload: payload, createdAt: line.at.timeIntervalSince1970
            )
        }
    }
}
#endif
