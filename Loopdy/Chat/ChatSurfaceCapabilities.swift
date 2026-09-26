import SwiftUI

/// Presentation follows the selected client's real capabilities. Defaults keep
/// the existing Link experience unchanged.
struct ChatSurfaceCapabilities: Equatable, Sendable {
    var voice = true
    var interruptAndSend = true

    static let standard = ChatSurfaceCapabilities()
    static let standaloneDirect = ChatSurfaceCapabilities(voice: false, interruptAndSend: false)

    func resolve(_ action: ChatComposerPrimaryAction) -> ChatComposerPrimaryAction {
        action == .voice && !voice ? .send : action
    }

    func allows(_ behavior: MidSessionChatBehavior) -> Bool {
        behavior != .interruptAndSend || interruptAndSend
    }
}

private struct ChatSurfaceCapabilitiesKey: EnvironmentKey {
    static let defaultValue = ChatSurfaceCapabilities.standard
}

extension EnvironmentValues {
    var chatSurfaceCapabilities: ChatSurfaceCapabilities {
        get { self[ChatSurfaceCapabilitiesKey.self] }
        set { self[ChatSurfaceCapabilitiesKey.self] = newValue }
    }
}
