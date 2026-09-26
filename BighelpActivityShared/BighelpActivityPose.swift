import SwiftUI
import UIKit

/// What the agent is doing, shared by the app's live avatar and the Dynamic
/// Island. Raw values match the plugin's tool categories; raw tool names map
/// by the same rules, so either can arrive in a Live Activity update.
enum BighelpActivityPose: String, CaseIterable, Sendable {
    case idle, thinking, replying, coding, web, images, seeing, memory, scheduling
    case delegating, files, messaging, publishing, tools, waiting, done, failed

    init(tool: String) {
        if let category = Self(rawValue: tool) {
            self = category
            return
        }
        let name = tool.lowercased()
        func has(_ markers: String...) -> Bool { markers.contains { name.contains($0) } }
        if has("image_generate", "video", "image", "mixture_of") { self = .images }
        else if has("terminal", "execute_code", "process", "patch", "code") { self = .coding }
        else if has("web_search", "web_extract", "browser", "search_web", "fetch") { self = .web }
        else if has("vision") { self = .seeing }
        else if has("memory", "session_search", "skill") { self = .memory }
        else if has("cronjob", "schedule", "cron") { self = .scheduling }
        else if has("delegate", "subagent") { self = .delegating }
        else if has("read_file", "write_file", "search_files", "file") { self = .files }
        else if has("send_message", "text_to_speech", "tts") { self = .messaging }
        else if has("bighelp_board") { self = .publishing }
        else if has("clarify") { self = .waiting }
        else { self = .tools }
    }

    init(phase: LoopdySessionActivityAttributes.ContentState.Phase, tool: String?) {
        switch phase {
        case .thinking: self = .thinking
        case .waiting: self = .waiting
        case .usingTool: self = tool.map(Self.init(tool:)) ?? .tools
        case .delegating: self = .delegating
        case .responding: self = .replying
        case .completed: self = .done
        case .failed: self = .failed
        }
    }

    var label: String {
        switch self {
        case .idle: "Here for you"
        case .thinking: "Thinking"
        case .replying: "Replying"
        case .coding: "Writing code"
        case .web: "Browsing the web"
        case .images: "Making images"
        case .seeing: "Taking a look"
        case .memory: "Remembering"
        case .scheduling: "Scheduling"
        case .delegating: "Working with helpers"
        case .files: "Working with files"
        case .messaging: "Sending a message"
        case .publishing: "Posting an update"
        case .tools: "Using tools"
        case .waiting: "Needs you"
        case .done: "All done"
        case .failed: "Hit a snag"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: "circle"
        case .thinking: "sparkles"
        case .replying: "text.bubble"
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .web: "globe"
        case .images: "paintbrush.pointed"
        case .seeing: "eye"
        case .memory: "brain"
        case .scheduling: "calendar.badge.clock"
        case .delegating: "person.2"
        case .files: "doc.text"
        case .messaging: "paperplane"
        case .publishing: "pin"
        case .tools: "wrench.and.screwdriver"
        case .waiting: "hand.raised"
        case .done: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// Accent per kind of work, so the island reads at a glance.
    var tint: Color {
        switch self {
        case .coding, .files: Color(red: 0.36, green: 0.84, blue: 0.56)
        case .web, .seeing: Color(red: 0.35, green: 0.68, blue: 1.0)
        case .images, .publishing: Color(red: 1.0, green: 0.55, blue: 0.75)
        case .thinking, .memory: Color(red: 0.72, green: 0.6, blue: 1.0)
        case .waiting, .failed: Color(red: 1.0, green: 0.72, blue: 0.3)
        default: Color(red: 0.9, green: 0.9, blue: 0.95)
        }
    }
}

/// Each agent's picture in the shared app group, so the Dynamic Island shows
/// the real avatar. The app writes it; the Live Activity only reads it.
enum BighelpActivityAvatarStore {
    static let pixelSize = 180

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BighelpWidgetSnapshot.appGroup)?
            .appendingPathComponent("activity-avatars", isDirectory: true)
    }

    static func fileURL(agentID: String) -> URL? {
        guard let id = BighelpActivityText.coordinate(agentID, maximum: 96) else { return nil }
        return directory?.appendingPathComponent("\(id).png", isDirectory: false)
    }

    static func image(agentID: String) -> UIImage? {
        guard let url = fileURL(agentID: agentID),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? Int ?? .max) <= 262_144 else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

/// The agent's picture, or its initial when none was shared yet.
struct BighelpActivityAvatar: View {
    let agentID: String
    let name: String
    let diameter: CGFloat

    var body: some View {
        if let image = BighelpActivityAvatarStore.image(agentID: agentID) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            BighelpActivityAgentMark(name: name, diameter: diameter)
        }
    }
}
