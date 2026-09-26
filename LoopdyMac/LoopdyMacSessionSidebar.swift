import SwiftUI

@MainActor
struct LoopdyMacSessionSidebar: View {
    @Bindable var workspace: LoopdyFoundationWorkspace
    let searchFocused: Bool
    let onSearchFocusChange: (Bool) -> Void
    @FocusState private var localSearchFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Loopdy")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            TextField("Search sessions", text: $workspace.searchQuery)
                .textFieldStyle(.roundedBorder)
                .focused($localSearchFocus)
                .padding(12)
                .accessibilityLabel("Search sessions")
                .accessibilityIdentifier("mac.session-search")
                .onChange(of: localSearchFocus) { _, value in onSearchFocusChange(value) }
                .onChange(of: searchFocused) { _, value in localSearchFocus = value }

            List(workspace.filteredSessions, selection: selection) { session in
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(session.agentName)
                        Text("•")
                        Text(session.updatedAt, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(.vertical, 4)
                .tag(session.id)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(session.title), \(session.agentName)")
            }
            .listStyle(.sidebar)
        }
        .background(.thinMaterial)
    }

    private var selection: Binding<String?> {
        Binding(
            get: { workspace.selectedSessionID },
            set: { id in
                guard let id else { return }
                workspace.open(.conversation(id))
            }
        )
    }
}
