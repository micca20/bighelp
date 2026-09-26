import SwiftUI
import WidgetKit

// MARK: - Timeline

struct LoopdyWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: LoopdyWidgetSnapshot
}

struct LoopdyWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> LoopdyWidgetEntry {
        LoopdyWidgetEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (LoopdyWidgetEntry) -> Void) {
        let snapshot = LoopdyWidgetSnapshot.load()
        completion(LoopdyWidgetEntry(date: .now,
            snapshot: context.isPreview && snapshot.sessions.isEmpty ? .preview : snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LoopdyWidgetEntry>) -> Void) {
        let snapshot = LoopdyWidgetSnapshot.load()
        // The app reloads timelines on every change; this is only a safety net.
        let refresh = Date.now.addingTimeInterval(snapshot.runningSessions.isEmpty ? 30 * 60 : 5 * 60)
        completion(Timeline(entries: [LoopdyWidgetEntry(date: .now, snapshot: snapshot)], policy: .after(refresh)))
    }
}

extension LoopdyWidgetSnapshot {
    static let preview = LoopdyWidgetSnapshot(
        defaultAgentID: "default", defaultAgentName: "Juno",
        sessions: [
            .init(id: "a", title: "Fix the build", agentName: "Juno", status: "Running tests",
                  preview: "Build succeeded, running the unit suite.", isRunning: true, updatedAt: .now,
                  agentID: "default", activity: LoopdyActivityPose.coding.rawValue),
            .init(id: "b", title: "Weekend plans", agentName: "Juno", status: "Replied",
                  preview: "Saturday looks clear after 2 PM.", isRunning: false, updatedAt: .now.addingTimeInterval(-900),
                  agentID: "default"),
        ],
        tasks: [.init(id: "t", name: "Morning brief", agentName: "Juno", schedule: "Every day at 7:00 AM",
                      nextRun: .now.addingTimeInterval(3600), lastResult: nil)],
        generatedAt: .now,
        feed: [
            .init(id: "f1", title: "Three flights under $300 for your May trip", icon: "✈️", date: .now.addingTimeInterval(-1800)),
            .init(id: "f2", title: "Your weekly spending recap is ready", icon: "📊", date: .now.addingTimeInterval(-7200)),
            .init(id: "f3", title: "New from the Swift blog: macros in practice", icon: "📰", date: .now.addingTimeInterval(-86_400)),
        ],
        goals: [
            .init(id: "g1", title: "Run a 10K", icon: "🏃", note: "4 of 8 weeks", date: .now),
            .init(id: "g2", title: "Read 12 books", icon: "📚", note: "7 so far", date: .now),
            .init(id: "g3", title: "Launch the app", icon: "🚀", isDone: true, date: .now),
        ])
}

// MARK: - Shared pieces

private struct RunningDot: View {
    let running: Bool
    @Environment(\.loopdyWidgetColors) private var colors
    var body: some View {
        Circle().fill(running ? colors.accent : colors.secondary.opacity(0.4))
            .frame(width: 7, height: 7).widgetAccentable().accessibilityHidden(true)
    }
}

private struct EmptyState: View {
    let symbol: String
    let text: String
    @Environment(\.loopdyWidgetColors) private var colors
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title3).foregroundStyle(colors.accent.opacity(0.7)).widgetAccentable()
            Text(text).font(.caption).foregroundStyle(colors.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WidgetHeader: View {
    let title: String
    let symbol: String
    var count: Int? = nil
    @Environment(\.loopdyWidgetColors) private var colors
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(colors.accent).widgetAccentable()
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(count > 0 ? colors.accentForeground : colors.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(count > 0 ? colors.accent : colors.secondary.opacity(0.15)))
                    .widgetAccentable()
                    .contentTransition(.numericText())
            }
        }
    }
}

/// One chat: what the agent is doing while it runs, else its last reply.
private struct WidgetSessionRow: View {
    let session: LoopdyWidgetSnapshot.Session
    var avatar: CGFloat = 0
    var detailLines = 1
    @Environment(\.loopdyWidgetColors) private var colors

    var body: some View {
        HStack(alignment: avatar > 0 ? .top : .center, spacing: 8) {
            if avatar > 0 {
                LoopdyWidgetAvatar(agentID: session.agentID, name: session.agentName, diameter: avatar,
                                   pose: session.isRunning ? pose : nil)
            } else if session.isRunning {
                Image(systemName: pose.symbolName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(colors.accentForeground)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(colors.accent))
                    .widgetAccentable()
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.title).font(.caption.weight(.semibold)).foregroundStyle(colors.primary).lineLimit(1)
                    if avatar > 0 {
                        Spacer(minLength: 4)
                        if session.isRunning {
                            RunningDot(running: true)
                        } else {
                            Text(session.updatedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                                .font(.caption2).foregroundStyle(colors.secondary).lineLimit(1).fixedSize()
                        }
                    }
                }
                Text(session.isRunning ? session.status : (session.preview ?? session.status))
                    .font(.caption2).foregroundStyle(colors.secondary).lineLimit(detailLines)
            }
            if avatar == 0 { Spacer(minLength: 0) }
        }
    }

    private var pose: LoopdyActivityPose {
        session.activity.flatMap(LoopdyActivityPose.init(rawValue:)) ?? .thinking
    }
}

// MARK: - Active sessions (small / accessory)

struct LoopdyActiveSessionsView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: LoopdyWidgetSnapshot

    var body: some View {
        let running = snapshot.runningSessions
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text("\(running.count)").font(.title2.weight(.semibold).monospacedDigit())
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.caption2)
                }
            }
            .accessibilityLabel("\(running.count) active bighelp chats")
            .widgetURL(LoopdyWidgetSnapshot.sessionsURL)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(running.isEmpty ? "No active chats" : "\(running.count) active")
                    .font(.headline).widgetAccentable()
                if let first = running.first {
                    Text(first.title).font(.caption).lineLimit(1)
                    Text(first.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(running.first.map { LoopdyWidgetSnapshot.chatURL($0.id) } ?? LoopdyWidgetSnapshot.sessionsURL)
        default:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "Working on", symbol: "bolt.fill", count: running.count)
                if running.isEmpty {
                    EmptyState(symbol: "checkmark.circle", text: "All caught up")
                } else {
                    ForEach(running.prefix(family == .systemMedium ? 3 : 2)) { session in
                        Link(destination: LoopdyWidgetSnapshot.chatURL(session.id)) {
                            WidgetSessionRow(session: session)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .widgetURL(LoopdyWidgetSnapshot.sessionsURL)
        }
    }
}

struct LoopdyActiveSessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LoopdyActiveSessionsWidget", provider: LoopdyWidgetProvider()) { entry in
            LoopdyWidgetScaffold(snapshot: entry.snapshot) {
                LoopdyActiveSessionsView(snapshot: entry.snapshot)
            }
        }
        .configurationDisplayName("Active Chats")
        .description("See which chats your agents are working on, and what they're doing.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Scheduled tasks

struct LoopdyScheduledTasksView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.loopdyWidgetColors) private var colors
    let snapshot: LoopdyWidgetSnapshot

    var body: some View {
        let tasks = snapshot.tasks.sorted { ($0.nextRun ?? .distantFuture) < ($1.nextRun ?? .distantFuture) }
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(tasks.first?.name ?? "No scheduled tasks").font(.headline).lineLimit(1).widgetAccentable()
                if let next = tasks.first?.nextRun {
                    Text(next, format: .relative(presentation: .named, unitsStyle: .abbreviated)).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(tasks.first.map { LoopdyWidgetSnapshot.taskURL($0.id) } ?? LoopdyWidgetSnapshot.tasksURL)
        default:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "Scheduled", symbol: "clock.arrow.circlepath", count: tasks.count)
                if tasks.isEmpty {
                    EmptyState(symbol: "calendar.badge.clock", text: "No active tasks")
                } else {
                    ForEach(Array(tasks.prefix(family == .systemSmall ? 2 : 3).enumerated()), id: \.element.id) { index, task in
                        Link(destination: LoopdyWidgetSnapshot.taskURL(task.id)) {
                            HStack(spacing: 8) {
                                // The next task leads, in the bubble color.
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(index == 0 ? colors.accent : colors.secondary.opacity(0.3))
                                    .frame(width: 3)
                                    .widgetAccentable()
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(task.name).font(.caption.weight(.semibold)).foregroundStyle(colors.primary).lineLimit(1)
                                    if let next = task.nextRun {
                                        Text(next, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                                            .font(.caption2).foregroundStyle(index == 0 ? colors.accent : colors.secondary).lineLimit(1)
                                    } else {
                                        Text(task.schedule).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .widgetURL(LoopdyWidgetSnapshot.tasksURL)
        }
    }
}

struct LoopdyScheduledTasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LoopdyScheduledTasksWidget", provider: LoopdyWidgetProvider()) { entry in
            LoopdyWidgetScaffold(snapshot: entry.snapshot) {
                LoopdyScheduledTasksView(snapshot: entry.snapshot)
            }
        }
        .configurationDisplayName("Scheduled Tasks")
        .description("Your active scheduled tasks and when they run next.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

// MARK: - New chat with the default agent

struct LoopdyNewChatView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.loopdyWidgetColors) private var colors
    let snapshot: LoopdyWidgetSnapshot

    var body: some View {
        let name = snapshot.agentDisplayName
        let url = LoopdyWidgetSnapshot.newChatURL(agentID: snapshot.defaultAgentID)
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "square.and.pencil").font(.title3.weight(.semibold))
                }
                .accessibilityLabel("New chat with \(name)")
            default:
                VStack(alignment: .leading, spacing: 0) {
                    LoopdyWidgetAvatar(agentID: snapshot.defaultAgentID, name: name, diameter: 56)
                    Spacer(minLength: 0)
                    Text("New chat").font(.headline)
                    Text("with \(name)").font(.caption).foregroundStyle(colors.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colors.accentForeground)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(colors.accent))
                        .widgetAccentable()
                }
            }
        }
        .widgetURL(url)
    }
}

struct LoopdyNewChatWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LoopdyNewChatWidget", provider: LoopdyWidgetProvider()) { entry in
            LoopdyWidgetScaffold(snapshot: entry.snapshot) {
                LoopdyNewChatView(snapshot: entry.snapshot)
            }
        }
        .configurationDisplayName("New Chat")
        .description("Start a new chat with your default agent in one tap.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

// MARK: - Activity feed (large)

struct LoopdyActivityFeedView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.loopdyWidgetColors) private var colors
    let snapshot: LoopdyWidgetSnapshot
    /// Set by render tests; WidgetKit supplies the family otherwise.
    var familyOverride: WidgetFamily? = nil

    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    var body: some View {
        let sessions = snapshot.feedSessions
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                WidgetHeader(title: "Recent chats", symbol: "bubble.left.and.bubble.right.fill",
                             count: snapshot.runningSessions.count)
                Link(destination: LoopdyWidgetSnapshot.newChatURL(agentID: snapshot.defaultAgentID)) {
                    Image(systemName: "square.and.pencil")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(colors.accentForeground)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(colors.accent))
                        .widgetAccentable()
                }
            }
            if sessions.isEmpty {
                EmptyState(symbol: "bubble.left.and.bubble.right", text: "No recent chats")
            } else {
                ForEach(sessions.prefix(family == .systemLarge ? 5 : 2)) { session in
                    Link(destination: LoopdyWidgetSnapshot.chatURL(session.id)) {
                        WidgetSessionRow(session: session, avatar: 30, detailLines: family == .systemLarge ? 2 : 1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct LoopdyActivityFeedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LoopdyActivityFeedWidget", provider: LoopdyWidgetProvider()) { entry in
            LoopdyWidgetScaffold(snapshot: entry.snapshot) {
                LoopdyActivityFeedView(snapshot: entry.snapshot)
                    .widgetURL(LoopdyWidgetSnapshot.sessionsURL)
            }
        }
        .configurationDisplayName("Recent Chats")
        .description("Your latest chats, newest first, with what each agent is doing.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
