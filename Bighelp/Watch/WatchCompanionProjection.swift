import Foundation

enum WatchCompanionProjection {
    static func make(
        dashboard: DashboardSnapshot?,
        sessions: [SessionRecord],
        selectedSessionID: String?,
        agentNamesByID: [String: String],
        agentRolesByID: [String: String],
        publishedApprovals: [WatchApprovalRequest],
        generatedAt: Date = .now
    ) -> WatchCompanionSnapshot {
        let recentRecords = Array(
            sessions
                .filter { $0.hasAcceptedMessage || $0.isActive }
                .sorted { left, right in
                    if left.isActive != right.isActive { return left.isActive }
                    return left.updatedAt > right.updatedAt
                }
                .prefix(16)
        )
        let validSelection = selectedSessionID.flatMap { requested in
            recentRecords.contains(where: { $0.id == requested }) ? requested : nil
        } ?? recentRecords.first?.id
        let selectedRecord = validSelection.flatMap { selected in
            recentRecords.first(where: { $0.id == selected })
        }

        let updateItems = dashboard?.inbox.prefix(8).map { item in
            WatchInboxItem(
                id: item.id,
                kind: .update,
                title: bounded(item.title, bytes: 160),
                detail: bounded(item.detail, bytes: 600),
                agentName: bounded(item.agentName, bytes: 120),
                agentRole: bounded(item.agentID.flatMap { agentRolesByID[$0] } ?? "Agent", bytes: 120),
                createdAt: item.createdAt,
                choices: [],
                allowsCustomResponse: false,
                canDismiss: true
            )
        } ?? []
        let attentionItems = dashboard?.attentionItems.prefix(8).compactMap { item -> WatchInboxItem? in
            switch item.interaction {
            case .approval(let approval):
                guard !publishedApprovals.contains(where: { $0.requestID == approval.approvalID }) else {
                    return nil
                }
                return WatchInboxItem(
                    id: item.id, kind: .update,
                    title: bounded(item.title, bytes: 160),
                    detail: bounded(item.detail, bytes: 600),
                    agentName: bounded(item.agentID.flatMap { agentNamesByID[$0] } ?? "bighelp", bytes: 120),
                    agentRole: "Approval", createdAt: item.createdAt,
                    choices: [], allowsCustomResponse: false,
                    phoneActionReason: "Open bighelp on iPhone to review this approval.",
                    expiresAt: approval.expiresAt
                )
            case .clarification(let request):
                let phoneReason: String? = request.isExpired(at: .now)
                    ? "This request has expired. Check iPhone for the latest state."
                    : request.isMultiSelect || request.question.utf8.count > 600
                        || request.choices.count > 4 || request.choices.contains(where: { $0.utf8.count > 500 })
                    ? "Open bighelp on iPhone to answer the complete request."
                    : nil
                return WatchInboxItem(
                    id: item.id,
                    kind: .clarification,
                    title: bounded(item.title, bytes: 160),
                    detail: bounded(request.question, bytes: 600),
                    agentName: bounded(item.agentID.flatMap { agentNamesByID[$0] } ?? "bighelp", bytes: 120),
                    agentRole: bounded(item.agentID.flatMap { agentRolesByID[$0] } ?? "Agent", bytes: 120),
                    createdAt: item.createdAt,
                    choices: phoneReason == nil ? request.choices : [],
                    allowsCustomResponse: phoneReason == nil && request.allowsCustomResponse,
                    phoneActionReason: phoneReason,
                    expiresAt: request.expiresAt,
                    requestID: request.requestID,
                    sessionID: request.sessionID,
                    agentID: item.agentID
                )
            case .none:
                return WatchInboxItem(
                    id: item.id,
                    kind: .update,
                    title: bounded(item.title, bytes: 160),
                    detail: bounded(item.detail, bytes: 600),
                    agentName: bounded(item.agentID.flatMap { agentNamesByID[$0] } ?? "bighelp", bytes: 120),
                    agentRole: bounded(item.agentID.flatMap { agentRolesByID[$0] } ?? "Agent", bytes: 120),
                    createdAt: item.createdAt,
                    choices: [],
                    allowsCustomResponse: false,
                    phoneActionReason: "Open bighelp on iPhone for the next action."
                )
            }
        } ?? []
        let inbox = Array((attentionItems + updateItems)
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(12))

        let watchSessions = recentRecords.map { record in
            let agentID = record.agentIDs.first
            return WatchSessionSummary(
                id: record.id,
                title: bounded(record.title, bytes: 180),
                agentName: bounded(agentID.flatMap { agentNamesByID[$0] } ?? "bighelp", bytes: 120),
                preview: bounded(record.summary.preview, bytes: 400),
                updatedAt: record.updatedAt,
                isActive: record.isActive
            )
        }
        let transcript: [WatchTranscriptItem] = selectedRecord.map { record in
            let messages = record.items.compactMap { item -> WatchTranscriptItem? in
                guard case .message(let text) = item.content else { return nil }
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { return nil }
                return WatchTranscriptItem(
                    id: item.id,
                    speaker: bounded(item.sender.snapshot.name, bytes: 120),
                    text: bounded(normalized, bytes: 1_200),
                    timestamp: item.metadata.timestamp ?? record.updatedAt,
                    isUser: item.role == .human
                )
            }
            return Array(messages.suffix(16))
        } ?? []
        let weather = dashboard?.weather.map {
            WatchWeatherSummary(
                city: bounded($0.city, bytes: 120),
                temperature: $0.temperature,
                condition: bounded($0.condition, bytes: 120),
                systemImage: bounded($0.systemImage, bytes: 80)
            )
        }

        return WatchCompanionSnapshot(
            generatedAt: generatedAt,
            weather: weather,
            inbox: inbox,
            approvals: Array(publishedApprovals.prefix(8)),
            sessions: watchSessions,
            selectedSessionID: validSelection,
            transcript: transcript
        )
    }

    private static func bounded(_ value: String, bytes maximum: Int) -> String {
        guard value.utf8.count > maximum else { return value }
        var result = ""
        result.reserveCapacity(min(value.count, maximum))
        for character in value {
            let next = String(character)
            guard result.utf8.count + next.utf8.count <= maximum else { break }
            result.append(character)
        }
        return result
    }
}
