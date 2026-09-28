#if canImport(ActivityKit)
import ActivityKit
#endif
import Foundation
import SwiftUI

/// Keeps its original "Loopdy" name: push-started Live Activities name this type,
/// and BuzzKit sends the type name to the push service.
struct LoopdySessionActivityAttributes: Hashable {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            case thinking
            case waiting
            case usingTool = "using_tool"
            case delegating
            case responding
            case completed
            case failed

            var isTerminal: Bool {
                self == .completed || self == .failed
            }
        }

        let phase: Phase
        let currentAction: String
        let progress: Int
        let completedSteps: Int
        let activeSubagentCount: Int
        let latestTool: String?
        let timestamp: Int

        static func initial(agentName: String, timestamp: Int) -> ContentState {
            let name = BighelpActivityText.personName(agentName) ?? "Your agent"
            return ContentState(
                phase: .thinking,
                currentAction: "\(name) is getting started",
                progress: 0,
                completedSteps: 0,
                activeSubagentCount: 0,
                latestTool: nil,
                timestamp: max(1, timestamp)
            )
        }
    }

    let sessionID: String
    let sessionTitle: String
    let agentID: String
    let agentName: String

    var deepLink: URL {
        URL(string: "loopdy://chat/\(sessionID)")!
    }

    static func make(
        sessionID: String,
        sessionTitle: String,
        agentID: String,
        agentName: String
    ) -> LoopdySessionActivityAttributes? {
        guard
            let sessionID = BighelpActivityText.coordinate(sessionID, maximum: 128),
            let agentID = BighelpActivityText.coordinate(agentID, maximum: 96),
            let agentName = BighelpActivityText.personName(agentName)
        else { return nil }
        // Retain the required v1 key without copying private chat titles.
        let title = "Active session"
        return LoopdySessionActivityAttributes(
            sessionID: sessionID,
            sessionTitle: title,
            agentID: agentID,
            agentName: agentName
        )
    }
}

enum BighelpActivityText {
    static func coordinate(_ value: String, maximum: Int) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            value == normalized,
            !normalized.isEmpty,
            normalized.count <= maximum,
            normalized.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
            })
        else { return nil }
        return normalized
    }

    static func display(_ value: String, maximum: Int) -> String? {
        let normalized = value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard
            !normalized.isEmpty,
            normalized.count <= maximum,
            !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return normalized
    }

    static func personName(_ value: String) -> String? {
        display(value, maximum: 50)
    }
}

/// Fixed vocabulary only; old remote/restored v1 free text is never rendered.
enum BighelpActivityStatus {
    static let responseReady = "Response ready"
    static let reviewingDelegatedWork = "Reviewing delegated work"
    static let agentsWorking = "Agents are still working"
    static let finished = "Finished"
    static let couldNotFinish = "Could not finish"
    static let stopped = "Stopped"
}

struct BighelpActivityPresentation: Equatable {
    let agentName: String
    let status: String
    let detail: String?
    let symbolName: String
    /// The kind of work, for the island's icon and accent.
    let pose: BighelpActivityPose

    init(attributes: LoopdySessionActivityAttributes, state: LoopdySessionActivityAttributes.ContentState, isStale: Bool) {
        agentName = BighelpActivityText.personName(attributes.agentName) ?? "Your agent"
        pose = isStale && !state.phase.isTerminal ? .idle : BighelpActivityPose(phase: state.phase, tool: state.latestTool)
        if isStale && !state.phase.isTerminal {
            status = "Updates paused"
            detail = "Open bighelp for current status"
            symbolName = "pause.circle"
            return
        }
        let children = min(max(state.activeSubagentCount, 0), 99)
        switch state.phase {
        case .thinking:
            status = state.currentAction == BighelpActivityStatus.reviewingDelegatedWork
                ? BighelpActivityStatus.reviewingDelegatedWork : "Thinking"
            symbolName = "sparkles"
        case .waiting:
            status = "Needs your attention"
            symbolName = "questionmark.bubble"
        case .usingTool:
            status = pose == .tools ? "Working" : pose.label
            symbolName = pose.symbolName
        case .delegating:
            status = state.currentAction == BighelpActivityStatus.responseReady
                ? BighelpActivityStatus.responseReady : "Working with other agents"
            symbolName = "person.2"
        case .responding:
            status = "Writing the response"
            symbolName = "text.bubble"
        case .completed:
            status = state.currentAction == BighelpActivityStatus.stopped
                ? BighelpActivityStatus.stopped : BighelpActivityStatus.finished
            symbolName = state.currentAction == BighelpActivityStatus.stopped ? "stop.circle" : "checkmark.circle"
        case .failed:
            status = BighelpActivityStatus.couldNotFinish
            symbolName = "exclamationmark.circle"
        }
        if children > 0 {
            detail = children == 1 ? "1 agent still working" : "\(children) agents still working"
        } else if state.phase == .waiting {
            detail = "Open bighelp to continue"
        } else {
            detail = nil
        }
    }

    var accessibilityLabel: String {
        [agentName, status, detail].compactMap { $0 }.joined(separator: ". ")
    }
}

/// The actual Lock Screen content, also available to an app/test ImageRenderer.
/// No ActivityViewContext, network, WidgetKit process or preview-only mock is needed.
struct BighelpLiveActivityCard: View {
    let attributes: LoopdySessionActivityAttributes
    let state: LoopdySessionActivityAttributes.ContentState
    var isStale = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3) private var markDiameter: CGFloat = 40

    private var presentation: BighelpActivityPresentation {
        BighelpActivityPresentation(attributes: attributes, state: state, isStale: isStale)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                BighelpActivityAvatar(agentID: attributes.agentID, name: presentation.agentName, diameter: markDiameter)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.agentName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(presentation.status)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                if let detail = presentation.detail, !dynamicTypeSize.isAccessibilitySize || isStale {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: presentation.symbolName)
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
        }
        .padding(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint("Opens the conversation in bighelp")
    }
}

struct BighelpActivityAgentMark: View {
    let name: String
    let diameter: CGFloat

    var body: some View {
        Text(String(name.first ?? "L").uppercased())
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: diameter, height: diameter)
            .background(.primary.opacity(0.08), in: Circle())
            .accessibilityHidden(true)
    }
}

#if canImport(ActivityKit)
// Vision Pro has no Live Activities; the same work state still drives the app there.
extension LoopdySessionActivityAttributes: ActivityAttributes {}
#endif
