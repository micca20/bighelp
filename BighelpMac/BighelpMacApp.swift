import SwiftUI

extension Notification.Name {
    static let bighelpFocusComposer = Notification.Name("loopdy.focus-composer")
    static let bighelpFocusSearch = Notification.Name("loopdy.focus-search")
    static let bighelpSend = Notification.Name("loopdy.send")
    static let bighelpCancel = Notification.Name("loopdy.cancel")
    static let bighelpOpenSettings = Notification.Name("loopdy.open-settings")
}

@main
struct BighelpMacApp: App {
    @State private var workspace = BighelpFoundationWorkspace.fixture()

    var body: some Scene {
        WindowGroup("bighelp") {
            BighelpMacShellView(workspace: workspace)
                .frame(minWidth: 720, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Focus Composer") {
                    NotificationCenter.default.post(name: .bighelpFocusComposer, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Conversation") {
                Button("Send Message") {
                    NotificationCenter.default.post(name: .bighelpSend, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button("Cancel Response") {
                    NotificationCenter.default.post(name: .bighelpCancel, object: nil)
                }
                .keyboardShortcut(".", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Search Sessions") {
                    NotificationCenter.default.post(name: .bighelpFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("bighelp Settings…") {
                    NotificationCenter.default.post(name: .bighelpOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
