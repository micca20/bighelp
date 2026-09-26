import SwiftUI

enum SessionStatusRailDestination: String, Identifiable {
    case goal
    case subagents
    case tasks

    var id: String { rawValue }
}

struct SessionStatusRailView: View {
    let changes: ProjectChangesRailSummary?
    let goal: ChatGoalRailState?
    let subagents: [SessionSubagentSnapshot]
    let nativeSubagents: [NativeSubagentRailItem]
    let tasks: ChatTaskDrawerState?
    let onSelect: (SessionStatusRailKind) -> Void
    let onFittingVerticalDrag: (ChatRailScrollDirection) -> Void
    var context: SessionContextSnapshot? = nil
    var isContextPresented: Binding<Bool> = .constant(false)
    var onContextSelect: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var didDispatchFittingVerticalDrag = false

    private var displayedSubagentCount: Int {
        subagents.count + nativeSubagents.count
    }

    var body: some View {
        let items = SessionStatusRailPresentation.items(
            changes: changes,
            goal: goal,
            subagents: subagents,
            nativeSubagents: nativeSubagents,
            tasks: tasks
        )
        return Group {
            if !items.isEmpty || context != nil { adaptiveRail(items) }
        }
        .companionComposerAnchor(.railViewport)
    }

    @ViewBuilder
    private func adaptiveRail(_ items: [SessionStatusRailItem]) -> some View {
        Group {
            if items.isEmpty {
                contextControl
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    ForEach(items) { compactStatusButton($0) }
                    contextControl
                }
            } else if dynamicTypeSize >= .xxxLarge {
                wrappedRail(items)
            } else {
                ViewThatFits(in: .horizontal) {
                    if horizontalSizeClass == .regular { fullRailContent(items) }
                    HStack(spacing: LoopdyTokens.space4) {
                        ForEach(items) {
                            compactStatusButton($0)
                                .fixedSize(horizontal: true, vertical: true)
                        }
                        contextControl
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    wrappedRail(items)
                }
            }
        }
        .padding(LoopdyTokens.space4)
        // A one-row pill grows into a rounded surface when labels need to wrap.
        // There is exactly one background, including on iPad and context-only chats.
        .loopdyNavigationGlass(in: RoundedRectangle(cornerRadius: 26))
        .simultaneousGesture(fittingVerticalDragGesture)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.session-status-rail")
        .frame(maxWidth: 760, alignment: horizontalSizeClass == .regular ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: horizontalSizeClass == .regular ? .center : .leading)
    }

    private func wrappedRail(_ items: [SessionStatusRailItem]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: LoopdyTokens.space4),
                           count: min(2, max(1, items.count + (context == nil ? 0 : 1)))),
            spacing: LoopdyTokens.space4
        ) {
            ForEach(items) { compactStatusButton($0) }
            contextControl
        }
    }

    @ViewBuilder
    private var contextControl: some View {
        if let context {
            SessionContextRing(snapshot: context) { onContextSelect?() }
                .popover(
                    isPresented: isContextPresented,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .bottom
                ) {
                    SessionContextTokenPopover(snapshot: context)
                        .presentationCompactAdaptation(.popover)
                }
                .companionComposerAnchor(.contextRing)
        }
    }

    private var compactStatusLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(spacing: 4))
            : AnyLayout(VStackLayout(spacing: 2))
    }

    private func compactStatusButton(_ item: SessionStatusRailItem) -> some View {
        Button { onSelect(item.kind) } label: {
            compactStatusLayout {
                Text(statusTitle(item.kind))
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: dynamicTypeSize.isAccessibilitySize, vertical: true)
                if dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
                Text(compactDetail(item.kind))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.kind == .changes && changes?.state == .failed
                        ? theme.danger : theme.primaryText)
                    .monospacedDigit()
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .frame(minWidth: LoopdyTokens.hitTarget, maxWidth: .infinity,
                   minHeight: LoopdyTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .companionComposerAnchor(.railLedge(item.kind.rawValue))
        .accessibilityLabel(accessibilityLabel(for: item.kind))
        .accessibilityHint("Opens details")
        .accessibilityIdentifier("chat.session-status.\(item.kind.rawValue)")
        .accessibilityValue(item.kind == .subagents
            ? subagentStreamAcceptanceFixture?.readinessValue(displayedSubagents: subagents) ?? ""
            : "")
    }

    private func compactDetail(_ kind: SessionStatusRailKind) -> String {
        guard kind == .changes, let changes else { return statusDetail(kind) }
        switch changes.state {
        case .loading: return "Loading"
        case .failed: return "Retry"
        case .unavailable: return "N/A"
        case .clean: return "Clean"
        case .dirty: return changes.fileCount == 1 ? "1 file" : "\(changes.fileCount) files"
        }
    }

    private func fullRailContent(_ items: [SessionStatusRailItem]) -> some View {
        HStack(spacing: LoopdyTokens.space8) {
            ForEach(items) { item in
                if item.kind == .changes {
                    compactStatusButton(item)
                        .fixedSize(horizontal: true, vertical: true)
                } else {
                    fullStatusButton(item)
                }
            }
            contextControl
        }
        .padding(.horizontal, LoopdyTokens.space4)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func fullStatusButton(_ item: SessionStatusRailItem) -> some View {
        Button { onSelect(item.kind) } label: {
            HStack(spacing: LoopdyTokens.space8) {
                Image(systemName: icon(for: item.kind))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.action)
                    .accessibilityHidden(true)
                Text(statusTitle(item.kind))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text(statusDetail(item.kind))
                    .font(.caption)
                    .foregroundStyle(item.kind == .changes && changes?.state == .failed
                        ? theme.danger : theme.secondaryText)
                    .monospacedDigit()
                if item.kind == .changes, changes?.isRefreshing == true {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Refreshing project changes")
                }
            }
            .lineLimit(1)
            .padding(.horizontal, LoopdyTokens.space12)
            .frame(minHeight: LoopdyTokens.hitTarget)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .companionComposerAnchor(.railLedge(item.kind.rawValue))
        .accessibilityLabel(accessibilityLabel(for: item.kind))
        .accessibilityIdentifier("chat.session-status.\(item.kind.rawValue)")
        .accessibilityValue(item.kind == .subagents
            ? subagentStreamAcceptanceFixture?.readinessValue(displayedSubagents: subagents) ?? ""
            : "")
    }

    private func statusDetail(_ kind: SessionStatusRailKind) -> String {
        switch kind {
        case .changes:
            guard let changes else { return "Project" }
            switch changes.state {
            case .loading: return "Loading"
            case .failed: return "Unavailable · Retry"
            case .unavailable: return "N/A"
            case .clean, .dirty:
                return ProjectChangesRailPresentation.visibleLabels(for: changes).joined(separator: " ")
            }
        case .goal:
            guard let goal else { return "Goal" }
            return (goal.lifecycle == .paused ? "Paused · " : "") + goal.compactSummary
        case .subagents:
            return "\(displayedSubagentCount)"
        case .tasks:
            return tasks.map { "\($0.completedCount)/\($0.totalCount)" } ?? "Session"
        }
    }

    private func statusTitle(_ kind: SessionStatusRailKind) -> String {
        switch kind {
        case .changes: "Changes"
        case .goal: "Goal"
        case .subagents: "Agents"
        case .tasks: "Tasks"
        }
    }

    private var fittingVerticalDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !didDispatchFittingVerticalDrag,
                      abs(value.translation.height) > abs(value.translation.width),
                      abs(value.translation.height) >= 12 else { return }
                didDispatchFittingVerticalDrag = true
                onFittingVerticalDrag(
                    value.translation.height < 0
                        ? .towardLatest
                        : .towardOldest
                )
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    didDispatchFittingVerticalDrag = false
                }
            }
            .onEnded { _ in
                didDispatchFittingVerticalDrag = false
            }
    }

    private func icon(for kind: SessionStatusRailKind) -> String {
        switch kind {
        case .changes: "plusminus"
        case .goal: "target"
        case .subagents: "cpu"
        case .tasks: "checklist"
        }
    }

    private func accessibilityLabel(for kind: SessionStatusRailKind) -> String {
        switch kind {
        case .changes:
            guard let changes else { return "Project changes" }
            return ProjectChangesRailPresentation.accessibilityLabel(for: changes)
        case .goal:
            guard let goal else { return "Goal" }
            return "Goal \(goal.lifecycle.rawValue), \(goal.compactSummary)"
        case .subagents:
            return displayedSubagentCount == 1 ? "1 active subagent" : "\(displayedSubagentCount) active subagents"
        case .tasks:
            guard let tasks else { return "Tasks" }
            return "Tasks, \(tasks.completedCount) of \(tasks.totalCount) completed"
        }
    }

    @LoopdyThemeReader private var theme

    @Environment(\.subagentStreamAcceptanceFixture)
    private var subagentStreamAcceptanceFixture
}

enum ChatRailScrollDirection: Equatable, Sendable {
    case towardLatest
    case towardOldest
}

struct ChatRailScrollRequest: Equatable, Sendable {
    var generation = 0
    var direction: ChatRailScrollDirection = .towardLatest
}
