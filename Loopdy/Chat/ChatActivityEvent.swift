import Foundation

enum ChatActivityKind: String, Codable, Equatable, Sendable {
    case reasoning
    case tool
    case subagent
    case botHandoff = "bot_handoff"
}

enum ChatActivityLifecycle: String, Codable, Equatable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
    case recorded

    var isTerminal: Bool {
        self != .running && self != .recorded
    }
}

struct ChatActivityEvent: Identifiable, Codable, Equatable, Sendable {
    let eventID: String
    private(set) var sessionID: String
    let turnID: String
    let kind: ChatActivityKind
    private(set) var lifecycle: ChatActivityLifecycle
    let title: String
    private(set) var summary: String?
    private(set) var detail: String?
    private(set) var occurredAt: Int
    private(set) var durationMilliseconds: Int?
    let toolCallID: String?
    /// Canonical Hermes tool name from the authenticated tool-call coordinate.
    /// Unlike `title`, this field is never free-form presentation prose.
    let toolName: String?
    /// Authenticated Hermes tool-call arguments retained for on-demand detail.
    private(set) var arguments: String?
    /// Authenticated Hermes tool result retained for on-demand detail.
    private(set) var result: String?
    /// Locally cached bytes resolved from the exact stored tool result. This is
    /// never populated from a provider URL or a client-supplied path.
    private(set) var generatedMedia: GeneratedMediaResolution?
    let subagentID: String?
    let botRunID: String?
    let memberID: String?
    let fromMemberID: String?
    /// The first authenticated arrival position for live activity, or the
    /// canonical Hermes history row when restored.
    private(set) var sourceOrder: Int?
    /// The result/source row is a preview until explicitly read and verified.
    private(set) var contentReference: CanonicalContentReference?

    var id: String {
        let activityID = switch kind {
        case .tool:
            toolCallID.map { "tool:\($0)" } ?? "event:\(eventID)"
        case .subagent:
            subagentID.map { "subagent:\($0)" } ?? "event:\(eventID)"
        case .botHandoff:
            if let botRunID, let memberID {
                "handoff:\(botRunID):\(memberID)"
            } else {
                "event:\(eventID)"
            }
        case .reasoning:
            "event:\(eventID)"
        }
        return "\(sessionID):\(turnID):\(activityID)"
    }

    var isPresentable: Bool {
        kind != .reasoning || reasoningText != nil
    }

    var reasoningText: String? {
        guard kind == .reasoning else { return nil }
        let emptyLifecycleLabels = [
            "",
            "preparing a response",
            "response ready",
            "response stopped",
            "reasoning completed",
        ]
        for value in [detail, summary] {
            guard let value,
                  !emptyLifecycleLabels.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else { continue }
            return value
        }
        return nil
    }

    var presentationTitle: String {
        if kind == .reasoning { return "Thinking" }
        guard kind == .tool else { return title }
        let arguments = argumentObject ?? [:]
        let canonicalToolName = toolName.flatMap(safeCollapsedIdentifier)
        let discriminator = canonicalToolName?.lowercased()
            ?? title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch discriminator {
        case "skill_view", "using skill view":
            guard
                let name = nonemptyArgument("name", in: arguments),
                let identifier = safeCollapsedIdentifier(name)
            else { return "Tool activity" }
            return "Skill: \(identifier)"
        case "terminal", "running a command":
            guard
                let command = nonemptyArgument("command", in: arguments),
                let executable = commandExecutableName(command)
            else { return canonicalToolName.map { "Command: \($0)" } ?? "Tool activity" }
            return "Command: \(executable)"
        case "execute_code", "using execute code":
            guard
                let executable = nonemptyArgument("executable", in: arguments)
                    ?? nonemptyArgument("name", in: arguments),
                let basename = executableBasename(executable),
                let identifier = safeCollapsedIdentifier(basename)
            else { return "Using execute code" }
            return "Execute: \(identifier)"
        case "tool_call", "using tool call":
            guard
                let name = nonemptyArgument("name", in: arguments),
                let identifier = safeCollapsedIdentifier(name)
            else { return canonicalToolName.map { "Tool: \($0)" } ?? "Tool activity" }
            return "Tool: \(identifier)"
        default:
            return canonicalToolName.map { "Tool: \($0)" } ?? "Tool activity"
        }
    }

    var collapsedPresentationSummary: String? {
        kind == .tool ? nil : summary
    }

    func collapsedAccessibilityLabel(status: String) -> String {
        [presentationTitle, collapsedPresentationSummary, status]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: ". ")
    }

    private var argumentObject: [String: Any]? {
        guard
            let arguments,
            let data = arguments.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func nonemptyArgument(_ key: String, in object: [String: Any]) -> String? {
        guard let value = object[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func safeCollapsedIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy(isSafeIdentifierScalar) else {
            return nil
        }
        return String(trimmed.prefix(80))
    }

    private func isSafeIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            true
        default:
            "_-.@:/+".unicodeScalars.contains(scalar)
        }
    }

    private func commandExecutableName(_ command: String) -> String? {
        guard let firstLine = command.split(whereSeparator: { $0.isNewline }).first else {
            return nil
        }
        let tokens = firstLine.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }

        var index = 0
        if executableBasename(tokens[0]) == "env" {
            index += 1
            while index < tokens.count, tokens[index].hasPrefix("-") {
                index += 1
            }
        }

        while index < tokens.count, isEnvironmentAssignment(tokens[index]) {
            guard hasBalancedQuotes(tokens[index]) else { return nil }
            index += 1
        }
        guard index < tokens.count, hasBalancedQuotes(tokens[index]) else { return nil }
        guard let basename = executableBasename(tokens[index]) else { return nil }
        return safeCollapsedIdentifier(basename)
    }

    private func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "=") else { return false }
        let name = token[..<equals]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private func hasBalancedQuotes(_ token: String) -> Bool {
        token.filter { $0 == "'" }.count.isMultiple(of: 2)
            && token.filter { $0 == "\"" }.count.isMultiple(of: 2)
    }

    private func executableBasename(_ token: String) -> String? {
        let stripped = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard !stripped.isEmpty else { return nil }
        return stripped.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
    }

    func isVisible(using visibility: ChatActivityVisibility) -> Bool {
        guard isPresentable else { return false }
        return switch kind {
        case .reasoning: visibility.showReasoning
        case .tool: visibility.showToolCalls
        case .subagent, .botHandoff: true
        }
    }

    init(
        eventID: String,
        sessionID: String,
        turnID: String,
        kind: ChatActivityKind,
        lifecycle: ChatActivityLifecycle,
        title: String,
        summary: String?,
        detail: String?,
        occurredAt: Int,
        durationMilliseconds: Int? = nil,
        toolCallID: String? = nil,
        toolName: String? = nil,
        arguments: String? = nil,
        result: String? = nil,
        generatedMedia: GeneratedMediaResolution? = nil,
        subagentID: String? = nil,
        botRunID: String? = nil,
        memberID: String? = nil,
        fromMemberID: String? = nil,
        sourceOrder: Int? = nil,
        contentReference: CanonicalContentReference? = nil
    ) {
        self.contentReference = contentReference
        self.eventID = eventID
        self.sessionID = sessionID
        self.turnID = turnID
        self.kind = kind
        self.lifecycle = lifecycle
        self.title = title
        self.summary = summary
        self.detail = detail
        self.occurredAt = occurredAt
        self.durationMilliseconds = durationMilliseconds
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.generatedMedia = generatedMedia
        self.subagentID = subagentID
        self.botRunID = botRunID
        self.memberID = memberID
        self.fromMemberID = fromMemberID
        self.sourceOrder = sourceOrder
    }

    func updating(
        lifecycle: ChatActivityLifecycle,
        summary: String?,
        detail: String?,
        occurredAt: Int,
        durationMilliseconds: Int? = nil,
        arguments: String? = nil,
        result: String? = nil
    ) -> ChatActivityEvent {
        var event = self
        event.lifecycle = lifecycle
        event.summary = summary
        event.detail = detail
        event.occurredAt = occurredAt
        event.durationMilliseconds = durationMilliseconds
        event.arguments = arguments ?? self.arguments
        event.result = result ?? self.result
        return event
    }

    func ordered(_ sourceOrder: Int) -> ChatActivityEvent {
        var event = self
        event.sourceOrder = sourceOrder
        return event
    }

    func routed(to sessionID: String) -> ChatActivityEvent {
        var event = self
        event.sessionID = sessionID
        event.contentReference = contentReference?.routed(to: sessionID)
        return event
    }

    func resolvingGeneratedMedia(_ resolution: GeneratedMediaResolution) -> ChatActivityEvent {
        var event = self
        event.generatedMedia = resolution
        return event
    }

    var semanticIdentity: String? {
        switch kind {
        case .tool:
            guard let toolCallID else { return nil }
            return "\(turnID):tool:\(toolCallID)"
        case .subagent:
            guard let subagentID else { return nil }
            return "\(turnID):subagent:\(subagentID)"
        case .botHandoff:
            guard let botRunID, let memberID else { return nil }
            return "\(turnID):handoff:\(botRunID):\(memberID)"
        case .reasoning:
            return nil
        }
    }
}

struct ChatActivityVisibility: Codable, Equatable, Sendable {
    var showReasoning: Bool
    var showToolCalls: Bool

    static let `default` = ChatActivityVisibility(
        showReasoning: false,
        showToolCalls: true
    )
}

enum ChatActivityReconciliation: Equatable, Sendable {
    case inserted
    case recovered
    case updated
    case duplicate
    case stale
    case ignoredWrongSession
    case ignoredTerminalWithoutStart
    case ignoredIdentityConflict
}

enum ChatActivityVisualTone: Equatable, Sendable {
    case neutral
    case success
    case failure
    case secondary
}

struct ChatActivityVisualState: Equatable, Sendable {
    let tone: ChatActivityVisualTone
    let shimmers: Bool

    init(lifecycle: ChatActivityLifecycle) {
        switch lifecycle {
        case .running:
            tone = .neutral
            shimmers = true
        case .succeeded:
            tone = .success
            shimmers = false
        case .failed:
            tone = .failure
            shimmers = false
        case .cancelled:
            tone = .secondary
            shimmers = false
        case .recorded:
            tone = .secondary
            shimmers = false
        }
    }
}

struct ChatToolActivityVisualState: Equatable, Sendable {
    let tone: ChatActivityVisualTone
    let shimmers: Bool

    init(lifecycle: ChatActivityLifecycle) {
        tone = lifecycle == .failed ? .failure : .neutral
        shimmers = lifecycle == .running
    }
}
