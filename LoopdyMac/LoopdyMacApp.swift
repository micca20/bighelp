import SwiftUI

extension Notification.Name {
    static let loopdyFocusComposer = Notification.Name("loopdy.focus-composer")
    static let loopdyFocusSearch = Notification.Name("loopdy.focus-search")
    static let loopdySend = Notification.Name("loopdy.send")
    static let loopdyCancel = Notification.Name("loopdy.cancel")
    static let loopdyOpenSettings = Notification.Name("loopdy.open-settings")
}

@main
struct LoopdyMacApp: App {
    @State private var workspace = LoopdyFoundationWorkspace.fixture()

    var body: some Scene {
        WindowGroup("Loopdy") {
            LoopdyMacShellView(workspace: workspace)
                .frame(minWidth: 720, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Focus Composer") {
                    NotificationCenter.default.post(name: .loopdyFocusComposer, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Conversation") {
                Button("Send Message") {
                    NotificationCenter.default.post(name: .loopdySend, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button("Cancel Response") {
                    NotificationCenter.default.post(name: .loopdyCancel, object: nil)
                }
                .keyboardShortcut(".", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Search Sessions") {
                    NotificationCenter.default.post(name: .loopdyFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Loopdy Settings…") {
                    NotificationCenter.default.post(name: .loopdyOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
