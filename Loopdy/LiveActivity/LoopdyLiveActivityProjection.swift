import Foundation

/// Stateless, privacy-minimal fallback. The coordinator, not this projection,
/// owns exact turn/child membership and deduplicated work counts.
enum LoopdyLiveActivityProjection {
    typealias State = LoopdySessionActivityAttributes.ContentState

    static func apply(
        _ event: ChatActivityEvent,
        to previous: State,
        agentName: String
    ) -> State {
        let agent = LoopdyActivityText.personName(agentName) ?? "Your agent"
        let phase: State.Phase
        let action: String
        switch event.kind {
        case .reasoning:
            // A reasoning segment ending (even unsuccessfully) is not proof
            // that the owning parent turn has ended.
            phase = event.lifecycle == .succeeded ? .responding : .thinking
            action = event.lifecycle == .succeeded
                ? "\(agent) is writing the response"
                : "\(agent) is thinking through your request"
        case .tool:
            if event.lifecycle.isTerminal {
                phase = .thinking
                action = "\(agent) is continuing the work"
            } else if event.toolName == "clarify" || event.title == "Waiting for your answer" {
                // Exact legacy synthetic attention label, not a substring or
                // arbitrary tool/title classifier. New callers use setWaiting.
                phase = .waiting
                action = "\(agent) is waiting for your answer"
            } else {
                phase = .usingTool
                action = "\(agent) is using a tool"
            }
        case .subagent, .botHandoff:
            phase = event.lifecycle.isTerminal ? .thinking : .delegating
            action = event.lifecycle.isTerminal
                ? LoopdyActivityStatus.reviewingDelegatedWork
                : "\(agent) is working with other agents"
        }
        return State(
            phase: phase,
            currentAction: String(action.prefix(96)),
            progress: 0,
            completedSteps: min(max(previous.completedSteps, 0), 999),
            activeSubagentCount: min(max(previous.activeSubagentCount, 0), 99),
            latestTool: nil,
            timestamp: max(previous.timestamp, max(1, event.occurredAt))
        )
    }

    static func final(
        agentName: String,
        previous: State,
        succeeded: Bool,
        timestamp: Int
    ) -> State {
        final(previous: previous, outcome: succeeded ? .succeeded : .failed, timestamp: timestamp)
    }

    static func final(previous: State, outcome: LoopdyLiveActivityOutcome, timestamp: Int) -> State {
        let children = min(max(previous.activeSubagentCount, 0), 99)
        let phase: State.Phase = children > 0 ? .delegating : (outcome == .failed ? .failed : .completed)
        let action: String
        if children > 0 {
            action = outcome == .succeeded ? LoopdyActivityStatus.responseReady : LoopdyActivityStatus.agentsWorking
        } else {
            switch outcome {
            case .succeeded: action = LoopdyActivityStatus.finished
            case .failed: action = LoopdyActivityStatus.couldNotFinish
            case .cancelled: action = LoopdyActivityStatus.stopped
            }
        }
        return State(
            phase: phase,
            currentAction: action,
            progress: children > 0 ? 0 : 100,
            completedSteps: min(max(previous.completedSteps, 0), 999),
            activeSubagentCount: children,
            latestTool: nil,
            timestamp: max(previous.timestamp, max(1, timestamp))
        )
    }
}

/// Native lifecycle input only. Rich v1 Phase raw values are unchanged.
enum LoopdyLiveActivityOutcome: Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
}
