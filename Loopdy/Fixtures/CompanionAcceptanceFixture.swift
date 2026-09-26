import Foundation

/// Explicit, Debug-only presentation inputs for native companion acceptance.
/// These do not synthesize production agent activity or change saved settings.
enum CompanionAcceptanceFixture {
    static func reaction(_ live: CompanionReaction) -> CompanionReaction {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-use-demo-fixtures"),
           let index = arguments.firstIndex(of: "-test-companion-reaction"),
           arguments.indices.contains(index + 1),
           let selected = CompanionReaction(rawValue: arguments[index + 1]) {
            return selected
        }
        #endif
        return live
    }

    static var reducedMotion: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-use-demo-fixtures")
            && arguments.contains("-test-companion-reduced-motion")
        #else
        return false
        #endif
    }
}
