import SwiftUI

/// The Mac menu bar's New Chat, Settings and text size, also listed when an
/// iPad's keyboard Command key is held. The shell publishes what they do.
struct BighelpMenuCommands: Commands {
    @FocusedValue(\.bighelpShellActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { actions?.newChat() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
        }
        CommandGroup(replacing: .sidebar) {
            Button(actions?.isSidebarOpen == true ? "Hide Sidebar" : "Show Sidebar") { actions?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(actions == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { BighelpInterfaceSize.shared.stepText(by: 1) }
                .keyboardShortcut("+")
            Button("Smaller Text") { BighelpInterfaceSize.shared.stepText(by: -1) }
                .keyboardShortcut("-")
            Button("Default Text Size") { BighelpInterfaceSize.shared.textSize = .standard }
                .keyboardShortcut("0")
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { actions?.openSettings() }
                .keyboardShortcut(",")
                .disabled(actions == nil)
        }
    }
}

struct BighelpShellActions {
    let newChat: @MainActor () -> Void
    let openSettings: @MainActor () -> Void
    /// ☰: the Mac's sidebar.
    let isSidebarOpen: Bool
    let toggleSidebar: @MainActor () -> Void
}

private struct BighelpShellActionsKey: FocusedValueKey {
    typealias Value = BighelpShellActions
}

extension FocusedValues {
    var bighelpShellActions: BighelpShellActions? {
        get { self[BighelpShellActionsKey.self] }
        set { self[BighelpShellActionsKey.self] = newValue }
    }
}
