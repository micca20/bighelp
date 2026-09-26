import SwiftUI

enum LoopdyMacLayoutMode: Equatable {
    case compact
    case expanded
}

enum LoopdyMacLayoutPolicy {
    static let expandedMinimumWidth: CGFloat = 900

    static func mode(for width: CGFloat) -> LoopdyMacLayoutMode {
        width < expandedMinimumWidth ? .compact : .expanded
    }
}

enum LoopdyMacColumnVisibility {
    static func toggled(
        from visibility: NavigationSplitViewVisibility,
        mode: LoopdyMacLayoutMode = .expanded
    ) -> NavigationSplitViewVisibility {
        switch mode {
        case .compact:
            return visibility == .all ? .detailOnly : .all
        case .expanded:
            return visibility == .all ? .doubleColumn : .all
        }
    }
}

@MainActor
struct LoopdyMacShellView: View {
    private enum FocusField: Hashable {
        case search
        case composer
    }

    @Bindable var workspace: LoopdyFoundationWorkspace
    @FocusState private var focusedField: FocusField?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsCompactInspector = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            let layoutMode = LoopdyMacLayoutPolicy.mode(for: proxy.size.width)
            splitView(for: layoutMode)
                .toolbar { toolbar(for: layoutMode) }
                .onChange(of: layoutMode) { _, _ in
                    columnVisibility = .all
                    showsCompactInspector = false
                }
        }
        .background(canvas)
        .onReceive(NotificationCenter.default.publisher(for: .loopdyFocusComposer)) { _ in
            focusedField = .composer
        }
        .onReceive(NotificationCenter.default.publisher(for: .loopdyFocusSearch)) { _ in
            focusedField = .search
        }
        .onReceive(NotificationCenter.default.publisher(for: .loopdySend)) { _ in
            workspace.sendDraft()
        }
        .onReceive(NotificationCenter.default.publisher(for: .loopdyCancel)) { _ in
            workspace.cancelResponse()
        }
        .onReceive(NotificationCenter.default.publisher(for: .loopdyOpenSettings)) { _ in
            workspace.open(.settings)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: workspace.route)
    }

    @ViewBuilder
    private func splitView(for layoutMode: LoopdyMacLayoutMode) -> some View {
        switch layoutMode {
        case .compact:
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
            } detail: {
                content
                    .navigationSplitViewColumnWidth(min: 360, ideal: 520)
            }
            .navigationSplitViewStyle(.balanced)
        case .expanded:
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            } content: {
                content
                    .navigationSplitViewColumnWidth(min: 420, ideal: 620)
            } detail: {
                LoopdyMacInspector(session: workspace.selectedSession)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private var sidebar: some View {
        LoopdyMacSessionSidebar(
            workspace: workspace,
            searchFocused: focusedField == .search,
            onSearchFocusChange: { focusedField = $0 ? .search : nil }
        )
    }

    @ToolbarContentBuilder
    private func toolbar(for layoutMode: LoopdyMacLayoutMode) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Toggle Sidebar", systemImage: "sidebar.left") {
                columnVisibility = LoopdyMacColumnVisibility.toggled(
                    from: columnVisibility,
                    mode: layoutMode
                )
            }
            .accessibilityHint("Shows or hides the session sidebar while keeping the conversation visible")
        }
        if layoutMode == .compact {
            ToolbarItem(placement: .secondaryAction) {
                Button("Session Details", systemImage: "sidebar.right") {
                    showsCompactInspector.toggle()
                }
                .popover(isPresented: $showsCompactInspector, arrowEdge: .bottom) {
                    LoopdyMacInspector(session: workspace.selectedSession)
                        .frame(width: 300, height: 360)
                }
                .accessibilityHint("Shows details for the selected session")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Settings", systemImage: "gearshape") {
                workspace.open(.settings)
            }
            .accessibilityIdentifier("mac.settings")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch workspace.route {
        case .conversation:
            LoopdyMacConversationView(
                workspace: workspace,
                composerFocused: focusedField == .composer,
                onComposerFocusChange: { focusedField = $0 ? .composer : nil }
            )
        case .settings:
            LoopdyMacSettingsView(
                reduceTransparency: reduceTransparency,
                reduceMotion: reduceMotion,
                increasedContrast: contrast == .increased
            )
        }
    }

    private var canvas: some ShapeStyle {
        reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.ultraThinMaterial)
    }
}
