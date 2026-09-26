import Foundation

/// Converts stock Hermes' allowlisted `session.control` goal component into the
/// app's retained rail model. Missing goal state is an authoritative tombstone;
/// malformed or unknown state is not.
enum DirectHermesGoalControlProjection {
    static func argument(from invocation: String) -> String? {
        let trimmed = invocation.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let command = tokens.first,
              command.lowercased() == "/goal" else { return nil }
        return tokens.count == 2 ? String(tokens[1]) : ""
    }

    static func controlAction(for argument: String) -> DirectHermesSessionControlAction? {
        switch argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pause": .goalPause
        case "resume": .goalResume
        case "clear", "stop", "done": .goalClear
        case "unwait": .goalUnwait
        default: nil
        }
    }

    static func railState(
        from control: DirectHermesSessionControlSnapshot
    ) throws -> ChatGoalRailState? {
        guard let component = control.goal else { return nil }
        let parsed = try parse(component)
        switch parsed.status {
        case .active:
            return ChatGoalRailState(summary: parsed.title, lifecycle: .active)
        case .paused:
            return ChatGoalRailState(summary: parsed.title, lifecycle: .paused)
        case .done, .cleared, .none:
            return nil
        }
    }

    static func retainedSnapshot(
        from control: DirectHermesSessionControlSnapshot,
        visibleSessionID: String,
        storedSessionID: String,
        observedAt: Int
    ) throws -> SessionGoalSnapshot {
        guard !visibleSessionID.isEmpty, !storedSessionID.isEmpty, observedAt > 0 else {
            throw DirectHermesError.invalidResponse
        }
        guard let component = control.goal else {
            return SessionGoalSnapshot(
                sessionID: visibleSessionID,
                storedSessionID: storedSessionID,
                status: .none,
                summary: nil,
                updatedAt: observedAt
            )
        }
        let parsed = try parse(component)
        return SessionGoalSnapshot(
            sessionID: visibleSessionID,
            storedSessionID: storedSessionID,
            status: parsed.status,
            summary: parsed.status == .active || parsed.status == .paused ? parsed.title : nil,
            updatedAt: observedAt
        )
    }

    private static func parse(
        _ component: DirectHermesSessionControlComponent
    ) throws -> (title: String, status: SessionGoalSnapshot.Status) {
        guard let title = component.fields["title"]?.string,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 131_072,
              !title.unicodeScalars.contains(where: isUnsupportedGoalControl),
              let rawStatus = component.fields["status"]?.string,
              let status = SessionGoalSnapshot.Status(rawValue: rawStatus),
              status != .none else {
            throw DirectHermesError.invalidResponse
        }
        return (title, status)
    }

    private static func isUnsupportedGoalControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar)
            && scalar != "\n" && scalar != "\r" && scalar != "\t"
    }
}

extension ChatGoalRailState {
    /// One-line, deterministic rail copy. The complete host title remains in the
    /// management sheet and retained snapshot.
    var compactSummary: String {
        let singleLine = summary.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let limit = 48
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit - 1)) + "…"
    }
}
