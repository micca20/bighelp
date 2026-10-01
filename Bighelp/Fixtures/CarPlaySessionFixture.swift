#if DEBUG && os(iOS) && targetEnvironment(simulator)
import SwiftUI

/// UI tests drive CarPlay's voice session here: the simulator's CarPlay
/// window can't be opened from a test. Runs on the demo data.
enum CarPlaySessionFixture {
    static let launchArgument = "-test-carplay-session"

    @MainActor
    static func rootView() -> some View {
        CarPlaySessionFixtureView(session: CarPlayVoiceSession(microphoneAllowed: { true }, speechAllowed: { true }))
    }
}

private struct CarPlaySessionFixtureView: View {
    @State var session: CarPlayVoiceSession

    var body: some View {
        VStack(spacing: 20) {
            Text(phase).font(.title2).accessibilityIdentifier("carplay.phase")
            Text(session.agentName).accessibilityIdentifier("carplay.agent")
            HStack {
                Button("Talk") { Task { await session.start() } }.accessibilityIdentifier("carplay.talk")
                Button(session.isMuted ? "Unmute" : "Mute") { session.toggleMute() }.accessibilityIdentifier("carplay.mute")
                Button("End") { session.stop() }.accessibilityIdentifier("carplay.end")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var phase: String {
        switch session.phase {
        case .connecting: "connecting"
        case .listening: "listening"
        case .working: "working"
        case .speaking: "speaking"
        case .paused: "paused"
        case .problem(let message): "problem: \(message)"
        }
    }
}
#endif
