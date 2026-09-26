import SwiftUI
import UIKit

/// Everything a board screen needs about the selected agent and the shell.
@MainActor
struct AgentBoardContext {
    let agentID: String
    let agentName: String
    let imageURL: URL?
    let activity: AgentActivityKind
    let store: AgentBoardStore
    let onProfile: () -> Void
    let onSwitchAgent: () -> Void
    /// Opens a chat with this agent with the text ready to send.
    let onAsk: (String) -> Void
}

// MARK: - Shared pieces

private struct BoardScroll<Content: View>: View {
    let context: AgentBoardContext
    let title: String?
    let identifier: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
                AgentHeroHeader(agentID: context.agentID, displayName: context.agentName,
                                imageURL: context.imageURL, activity: context.activity,
                                onAvatarTap: context.onProfile, onNameTap: context.onSwitchAgent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, LoopdyTokens.space8)
                if let title {
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                }
                content()
            }
            .padding(.horizontal, LoopdyTokens.space20)
            .padding(.bottom, 120)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .refreshable { await context.store.load(agentID: context.agentID) }
        .task(id: context.agentID) {
            if context.store.agentID != context.agentID || context.store.state == .idle {
                await context.store.load(agentID: context.agentID)
            }
        }
        .background(LoopdyThemeCanvas(theme: theme).ignoresSafeArea())
        .accessibilityIdentifier(identifier)
    }

    @LoopdyThemeReader private var theme
}

/// "Tell your agent what you want here": the only way content starts.
private struct BoardEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    let example: String
    let agentName: String
    let onAsk: (String) -> Void
    let identifier: String

    var body: some View {
        VStack(spacing: LoopdyTokens.space12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(theme.action)
                .padding(.top, LoopdyTokens.space24)
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
            Text("“\(example)”")
                .font(.subheadline.italic())
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
                .padding(LoopdyTokens.space12)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.incomingMessageBackground))
            Button {
                onAsk(example)
            } label: {
                Label("Ask \(agentName)", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
            }
            .loopdyProminentButtonStyle()
            .buttonBorderShape(.capsule)
            .tint(theme.action)
            .foregroundStyle(theme.actionForeground)
            .accessibilityIdentifier(identifier + ".ask")
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    @LoopdyThemeReader private var theme
}

private struct BoardIcon: View {
    let icon: String
    let fallback: String
    var size: CGFloat = 40

    var body: some View {
        Group {
            if icon.isEmpty {
                Image(systemName: fallback)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(theme.action)
            } else {
                Text(icon).font(.system(size: size * 0.8))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @LoopdyThemeReader private var theme
}

private struct BoardStateBanner: View {
    let state: AgentBoardStore.LoadState
    let context: AgentBoardContext
    @State private var copied = false

    static let updateCommand = "hermes loopdy update --restart"

    var body: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, LoopdyTokens.space24)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
        case .unavailable where context.store.isDisconnected:
            Label("Connect to your Hermes host to see this.", systemImage: "bolt.horizontal.circle")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
        case .unavailable:
            pluginUpdate
        case .idle, .loaded:
            EmptyView()
        }
    }

    /// The host (a Mac, a server or a cloud sandbox) runs an older plugin.
    private var pluginUpdate: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space12) {
            Label("Your Hermes host is running an older bighelp plugin", systemImage: "puzzlepiece.extension")
                .font(.headline)
                .foregroundStyle(theme.primaryText)
            Text("Run this where Hermes runs, or ask \(context.agentName) to do it. Already updated? "
                 + "Restart every Hermes dashboard this phone connects to, so it loads the new copy.")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
            Text(Self.updateCommand)
                .font(.callout.monospaced())
                .foregroundStyle(theme.primaryText)
                .textSelection(.enabled)
                .padding(LoopdyTokens.space12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.incomingMessageBackground))
            HStack(spacing: LoopdyTokens.space12) {
                Button {
                    UIPasteboard.general.string = Self.updateCommand
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minHeight: LoopdyTokens.hitTarget)
                }
                .accessibilityIdentifier("board.plugin-required.copy")
                Button {
                    context.onAsk("Please update the bighelp plugin on this host: run `\(Self.updateCommand)`, "
                        + "then restart every Hermes dashboard process (including launchd or systemd services) "
                        + "so they load it, and tell me when it's back.")
                } label: {
                    Label("Ask \(context.agentName)", systemImage: "bubble.left.and.text.bubble.right")
                        .frame(minHeight: LoopdyTokens.hitTarget)
                }
                .accessibilityIdentifier("board.plugin-required.ask")
            }
            .font(.subheadline.weight(.semibold))
            .tint(theme.action)
        }
        .padding(LoopdyTokens.space16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.border))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.plugin-required")
    }

    @LoopdyThemeReader private var theme
}

/// Friendly buckets: "This evening", "Yesterday afternoon", "Friday morning".
enum BoardTimeBucket {
    static func title(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let part = switch hour {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<22: "evening"
        default: "night"
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return part == "night" ? "Tonight" : "This \(part)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(part)"
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.wide))) \(part)"
        }
        return date.formatted(.dateTime.month(.wide).day())
    }

    static func grouped(_ items: [AgentBoardItem], now: Date = .now) -> [(title: String, items: [AgentBoardItem])] {
        var groups: [(title: String, items: [AgentBoardItem])] = []
        for item in items.sorted(by: { $0.createdAt > $1.createdAt }) {
            let title = self.title(for: item.createdAt, now: now)
            if groups.last?.title == title {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append((title, [item]))
            }
        }
        return groups
    }
}

// MARK: - Feed

struct AgentFeedView: View {
    let context: AgentBoardContext

    var body: some View {
        let store = context.store
        BoardScroll(context: context, title: nil, identifier: "board.feed") {
            BoardStateBanner(state: store.state, context: context)
            if store.feed.isEmpty, store.state == .loaded {
                BoardEmptyState(
                    symbol: "newspaper",
                    title: "Your feed is quiet",
                    message: "Tell \(context.agentName) what you'd like to hear about. Posts show up here when they're ready.",
                    example: "Every evening, post the top three AI stories to my feed.",
                    agentName: context.agentName, onAsk: context.onAsk, identifier: "board.feed.empty")
            }
            ForEach(BoardTimeBucket.grouped(store.feed), id: \.title) { group in
                Text(group.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(theme.primaryText)
                    .padding(.top, LoopdyTokens.space8)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.items) { item in
                    FeedPostView(item: item, context: context)
                    Divider().overlay(theme.border)
                }
            }
        }
    }

    @LoopdyThemeReader private var theme
}

private struct FeedPostView: View {
    let item: AgentBoardItem
    let context: AgentBoardContext
    @State private var isShowingInfo = false

    var body: some View {
        HStack(alignment: .top, spacing: LoopdyTokens.space12) {
            BoardIcon(icon: item.icon, fallback: "newspaper", size: 44)
            VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.body.isEmpty {
                    Text(markdown(item.body))
                        .font(.body)
                        .foregroundStyle(theme.primaryText.opacity(0.9))
                        .tint(theme.action)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !item.pictures.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: LoopdyTokens.space8) {
                            ForEach(Array(item.pictures.enumerated()), id: \.offset) { _, picture in
                                BoardPictureView(item: item, picture: picture, store: context.store)
                                    .frame(width: 220, height: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                        }
                    }
                    .scrollClipDisabled()
                }
                ForEach(item.links, id: \.url) { link in
                    Link(destination: link.url) {
                        Label(link.title.isEmpty ? (link.url.host() ?? "Open link") : link.title, systemImage: "link")
                            .font(.subheadline.weight(.medium))
                    }
                    .tint(theme.action)
                }
                actions
            }
        }
        .padding(.vertical, LoopdyTokens.space8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.feed.post.\(item.id)")
    }

    private var actions: some View {
        HStack(spacing: LoopdyTokens.space20) {
            Button {
                Task { await context.store.setLiked(item, !item.liked) }
            } label: {
                Image(systemName: item.liked ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(item.liked ? Color.pink : theme.primaryText)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: LoopdyTokens.hitTarget, minHeight: LoopdyTokens.hitTarget, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.liked ? "Unlike" : "Like")
            .accessibilityIdentifier("board.feed.like")
            Button {
                context.onAsk("About “\(item.title)”: ")
            } label: {
                Label("Discuss", systemImage: "bubble.left")
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.primaryText)
                    .frame(minHeight: LoopdyTokens.hitTarget)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("board.feed.discuss")
            Spacer()
            Button {
                isShowingInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(theme.secondaryText)
                    .frame(minWidth: LoopdyTokens.hitTarget, minHeight: LoopdyTokens.hitTarget, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About this post")
            .popover(isPresented: $isShowingInfo) {
                VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                    Text(item.source.isEmpty ? "Posted by \(context.agentName)" : item.source)
                        .font(.subheadline.weight(.semibold))
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Hide this post", role: .destructive) {
                        isShowingInfo = false
                        Task { await context.store.dismiss(item) }
                    }
                    .padding(.top, LoopdyTokens.space4)
                }
                .padding()
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    @LoopdyThemeReader private var theme
}

private func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}

struct BoardPictureView: View {
    let item: AgentBoardItem
    let picture: AgentBoardItem.Picture
    let store: AgentBoardStore
    @State private var image: UIImage?

    var body: some View {
        Group {
            switch picture {
            case .remote(let url):
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { placeholder }
                }
            case .stored(let index):
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    placeholder.task(id: "\(item.id)#\(index)") {
                        if let data = await store.picture(for: item, index: index) { image = UIImage(data: data) }
                    }
                }
            }
        }
        .accessibilityLabel("Picture for \(item.title)")
    }

    private var placeholder: some View {
        Rectangle().fill(theme.incomingMessageBackground).overlay(ProgressView())
    }

    @LoopdyThemeReader private var theme
}

// MARK: - Ideas

struct AgentIdeasView: View {
    let context: AgentBoardContext
    @State private var selected: AgentBoardItem?

    var body: some View {
        let store = context.store
        BoardScroll(context: context, title: "Ideas", identifier: "board.ideas") {
            BoardStateBanner(state: store.state, context: context)
            if store.ideas.isEmpty, store.state == .loaded {
                BoardEmptyState(
                    symbol: "lightbulb",
                    title: "No ideas yet",
                    message: "Ask \(context.agentName) to suggest things it could do for you. Ideas it proposes land here.",
                    example: "Look through my week and suggest a few things you could take off my plate.",
                    agentName: context.agentName, onAsk: context.onAsk, identifier: "board.ideas.empty")
            }
            ForEach(sections(store.ideas), id: \.title) { section in
                if !section.title.isEmpty {
                    Text(section.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(theme.primaryText)
                        .padding(.top, LoopdyTokens.space8)
                }
                ForEach(section.items) { idea in
                    Button { selected = idea } label: { ideaRow(idea) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("board.idea.\(idea.id)")
                    Divider().overlay(theme.border)
                }
            }
        }
        .sheet(item: $selected) { idea in
            IdeaDetailSheet(idea: idea, context: context)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func sections(_ ideas: [AgentBoardItem]) -> [(title: String, items: [AgentBoardItem])] {
        var order: [String] = []
        var groups: [String: [AgentBoardItem]] = [:]
        for idea in ideas.sorted(by: { $0.createdAt > $1.createdAt }) {
            let key = idea.section.trimmingCharacters(in: .whitespaces)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(idea)
        }
        // Unsectioned ideas lead, under the page title.
        return order.sorted { $0.isEmpty && !$1.isEmpty }.map { ($0, groups[$0] ?? []) }
    }

    private func ideaRow(_ idea: AgentBoardItem) -> some View {
        HStack(alignment: .top, spacing: LoopdyTokens.space12) {
            BoardIcon(icon: idea.icon, fallback: "lightbulb", size: 48)
            VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                Text(idea.title)
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.leading)
                Text(idea.body)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, LoopdyTokens.space8)
        .contentShape(.rect)
    }

    @LoopdyThemeReader private var theme
}

private struct IdeaDetailSheet: View {
    let idea: AgentBoardItem
    let context: AgentBoardContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
                BoardIcon(icon: idea.icon, fallback: "lightbulb", size: 64)
                Text(idea.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(theme.primaryText)
                Text(markdown(idea.body))
                    .font(.body)
                    .foregroundStyle(theme.primaryText)
                    .tint(theme.action)
                VStack(spacing: LoopdyTokens.space8) {
                    Button {
                        dismiss()
                        context.onAsk("Yes, go ahead with this idea: “\(idea.title)”.")
                    } label: {
                        Text("Let's do it")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
                    }
                    .loopdyProminentButtonStyle()
                    .buttonBorderShape(.capsule)
                    .tint(theme.action)
                    .foregroundStyle(theme.actionForeground)
                    .accessibilityIdentifier("board.idea.accept")
                    Button {
                        dismiss()
                        Task { await context.store.dismiss(idea) }
                    } label: {
                        Text("Not now")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("board.idea.dismiss")
                }
                .padding(.top, LoopdyTokens.space8)
            }
            .padding(LoopdyTokens.space24)
        }
        .background(theme.canvas.ignoresSafeArea())
    }

    @LoopdyThemeReader private var theme
}

// MARK: - Goals

struct AgentGoalsView: View {
    let context: AgentBoardContext
    @State private var expanded: Set<String> = []

    var body: some View {
        let goals = context.store.goals
        BoardScroll(context: context, title: "Goals", identifier: "board.goals") {
            BoardStateBanner(state: context.store.state, context: context)
            if goals.isEmpty, context.store.state == .loaded {
                BoardEmptyState(
                    symbol: "checkmark.circle",
                    title: "Nothing tracked yet",
                    message: "Tell \(context.agentName) about a goal, or something to keep an eye on. It keeps a short status here.",
                    example: "Help me get 8 hours of sleep on weeknights, and keep an eye on it.",
                    agentName: context.agentName, onAsk: context.onAsk, identifier: "board.goals.empty")
            }
            section("Tracking", color: .green, key: "tracking",
                    items: goals.filter { $0.isTracking && !$0.isDone })
            section("Goals", color: .blue, key: "goal",
                    items: goals.filter { !$0.isTracking && !$0.isDone })
            section("Done", color: .gray, key: "done", items: goals.filter(\.isDone), collapsedLimit: 0)
            if context.store.state == .loaded {
                Button {
                    context.onAsk("I'd like to set a goal: ")
                } label: {
                    Label("Create a goal", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .frame(minHeight: LoopdyTokens.hitTarget)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("board.goals.create")
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, color: Color, key: String, items: [AgentBoardItem],
                         collapsedLimit: Int = 4) -> some View {
        if !items.isEmpty {
            let showsAll = expanded.contains(key)
            let visible = showsAll ? items : Array(items.prefix(collapsedLimit))
            HStack(spacing: LoopdyTokens.space8) {
                Circle().fill(color).frame(width: 8, height: 8)
                    .padding(6)
                    .background(Circle().fill(color.opacity(0.18)))
                Text(title)
                    .font(.headline)
                    .foregroundStyle(color)
            }
            .padding(.top, LoopdyTokens.space8)
            .accessibilityAddTraits(.isHeader)
            ForEach(visible) { goal in goalRow(goal) }
            if items.count > visible.count {
                Button {
                    withAnimation(.snappy) { _ = expanded.insert(key) }
                } label: {
                    Label(visible.isEmpty ? "Show \(items.count) done" : "Show \(items.count - visible.count) more",
                          systemImage: "ellipsis")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.secondaryText)
                        .frame(minHeight: LoopdyTokens.hitTarget)
                }
                .buttonStyle(.plain)
            }
            Divider().overlay(theme.border)
        }
    }

    private func goalRow(_ goal: AgentBoardItem) -> some View {
        HStack(alignment: .top, spacing: LoopdyTokens.space12) {
            Button {
                Task { await context.store.setDone(goal, !goal.isDone) }
            } label: {
                Image(systemName: goal.isDone ? "checkmark.square.fill" : "square")
                    .font(.title2)
                    .foregroundStyle(goal.isDone ? theme.action : theme.secondaryText)
                    .frame(width: 30, height: LoopdyTokens.hitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(goal.isDone ? "Mark \(goal.title) not done" : "Mark \(goal.title) done")
            .accessibilityIdentifier("board.goal.toggle.\(goal.id)")
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.title)
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                    .strikethrough(goal.isDone)
                if !goal.note.isEmpty {
                    Text(goal.note)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.top, 10)
            Spacer(minLength: 0)
            Menu {
                Button("Discuss", systemImage: "bubble.left") { context.onAsk("About my goal “\(goal.title)”: ") }
                Button(goal.isDone ? "Mark not done" : "Mark done", systemImage: "checkmark") {
                    Task { await context.store.setDone(goal, !goal.isDone) }
                }
                Button("Remove from list", systemImage: "eye.slash", role: .destructive) {
                    Task { await context.store.dismiss(goal) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: LoopdyTokens.hitTarget, height: LoopdyTokens.hitTarget)
            }
            .accessibilityLabel("More for \(goal.title)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.goal.\(goal.id)")
    }

    @LoopdyThemeReader private var theme
}

// MARK: - Apps

struct AgentAppsView<Artifacts: View>: View {
    enum Segment: String, CaseIterable, Identifiable {
        case artifacts = "Artifacts", media = "Media"
        var id: String { rawValue }
    }

    let context: AgentBoardContext
    let media: AgentMediaStore
    let tools: [(title: String, systemImage: String, action: () -> Void)]
    @ViewBuilder let artifacts: () -> Artifacts
    @State private var segment: Segment = .artifacts
    @State private var preview: ChatAttachment?

    var body: some View {
        VStack(spacing: LoopdyTokens.space12) {
            ZStack(alignment: .topTrailing) {
                AgentHeroHeader(agentID: context.agentID, displayName: context.agentName,
                                imageURL: context.imageURL, activity: context.activity,
                                onAvatarTap: context.onProfile, onNameTap: context.onSwitchAgent)
                    .frame(maxWidth: .infinity)
                Menu {
                    ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                        Button(tool.title, systemImage: tool.systemImage, action: tool.action)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                        .loopdyNavigationGlass(in: Circle(), isInteractive: true)
                }
                .accessibilityLabel("More tools")
                .accessibilityIdentifier("board.apps.more")
            }
            .padding(.horizontal, LoopdyTokens.space20)
            .padding(.top, LoopdyTokens.space8)
            Picker("Show", selection: $segment) {
                ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, LoopdyTokens.space20)
            .accessibilityIdentifier("board.apps.segment")
            switch segment {
            case .artifacts:
                artifacts()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .media:
                mediaGrid
            }
        }
        .background(LoopdyThemeCanvas(theme: theme).ignoresSafeArea())
        .task(id: context.agentID) {
            if context.store.agentID != context.agentID { await context.store.load(agentID: context.agentID) }
        }
        .accessibilityIdentifier("board.apps")
    }

    /// Pictures and videos the agent sent or made, then pictures from its posts.
    private var mediaGrid: some View {
        let pictures = context.store.items.filter { !$0.dismissed }.flatMap { item in
            item.pictures.map { (item, $0) }
        }
        return ScrollView {
            if media.items.isEmpty, pictures.isEmpty {
                if media.state == .loading || media.state == .idle {
                    ProgressView().padding(.top, LoopdyTokens.space32)
                } else {
                    ContentUnavailableView("No media yet", systemImage: "photo.on.rectangle",
                        description: Text(emptyMediaText))
                        .padding(.top, LoopdyTokens.space24)
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(media.items) { item in
                        AgentMediaTile(item: item, store: media) {
                            Task { preview = await media.attachment(for: item) }
                        }
                    }
                    ForEach(Array(pictures.enumerated()), id: \.offset) { _, entry in
                        BoardPictureView(item: entry.0, picture: entry.1, store: context.store)
                            .aspectRatio(1, contentMode: .fill)
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, LoopdyTokens.space20)
            }
        }
        .refreshable { await media.load(agentID: context.agentID) }
        .task(id: context.agentID) { await media.load(agentID: context.agentID) }
        .sheet(item: $preview) { ChatAttachmentPreviewView(attachment: $0) }
        .padding(.bottom, 100)
        .accessibilityIdentifier("board.media")
    }

    private var emptyMediaText: String {
        media.state == .unavailable
            ? "Pictures and videos \(context.agentName) sends you show up here once the bighelp plugin on your Hermes host is updated."
            : "Pictures and videos \(context.agentName) sends you or makes show up here."
    }

    @LoopdyThemeReader private var theme
}
