import BuzzKit
import Foundation

/// BuzzKit is the only category-preference store. Device authorization and
/// ActivityKit enablement remain distinct OS/local lifecycle states.
struct LoopdyBuzzKitPreference: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String?
    let category: String?
    let enabled: Bool
    let isDefault: Bool
}

enum LoopdyBuzzKitTopic: String, CaseIterable, Sendable {
    case chatRepliesAndCompletions = "chat-replies-completions"
    case scheduledTasksAndDeliveries = "scheduled-tasks-deliveries"
    case questionsAndApprovals = "questions-approvals"
    case subagentCompletions = "subagent-completions"
}

struct LoopdyBuzzKitPreferencesClient: Sendable {
    func load() async throws -> [LoopdyBuzzKitPreference] {
        try await BuzzKit.preferences.all().compactMap(Self.project)
    }

    /// Migrates only explicit legacy provider choices, once, into the replacement
    /// provider topic. No local preference bit is created and a resolved default
    /// never overwrites an explicit value on the new topic.
    func migrateLegacyPreferences() async throws {
        var topics = try await BuzzKit.preferences.all()
        for migration in Self.legacyMigrations {
            guard let replacement = topics.first(where: { $0.slug == migration.topic.rawValue }),
                  let replacementPush = replacement.channels[.push], replacementPush.isDefault else { continue }
            let legacyChoices = topics.filter { migration.legacySlugs.contains($0.slug) }
                .compactMap { $0.channels[.push] }
                .filter { !$0.isDefault }
            guard !legacyChoices.isEmpty else { continue }
            // A combined category preserves every earlier opt-out.
            let enabled = legacyChoices.allSatisfy(\.isOptedIn)
            topics = try await BuzzKit.preferences.set(
                migration.topic.rawValue,
                channel: .push,
                enabled: enabled
            )
        }
    }

    @discardableResult
    func set(_ topic: LoopdyBuzzKitTopic, enabled: Bool) async throws -> [LoopdyBuzzKitPreference] {
        try await BuzzKit.preferences.set(topic.rawValue, channel: .push, enabled: enabled)
            .compactMap(Self.project)
    }

    private static let legacyMigrations: [(topic: LoopdyBuzzKitTopic, legacySlugs: Set<String>)] = [
        (.chatRepliesAndCompletions, ["session-completed-desktop", "session-failed-desktop"]),
        (.questionsAndApprovals, ["approval-required-desktop", "clarification-required-desktop"]),
    ]

    private static func project(_ topic: BuzzKit.Topic) -> LoopdyBuzzKitPreference? {
        guard LoopdyBuzzKitTopic(rawValue: topic.slug) != nil,
              let push = topic.channels[.push] else { return nil }
        return LoopdyBuzzKitPreference(
            id: topic.slug,
            name: topic.name,
            detail: topic.description,
            category: topic.category,
            enabled: push.isOptedIn,
            isDefault: push.isDefault
        )
    }
}
