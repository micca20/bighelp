import CryptoKit
import Foundation

// MARK: - Shell hooks

struct HermesShellHook: Equatable, Sendable, Identifiable {
    let event: String
    let matcher: String?
    let command: String
    let timeoutSeconds: Int
    let isAllowed: Bool
    let approvedAt: String?
    let isExecutable: Bool

    /// Hook identity is byte-preserving. Swift String identity would collapse
    /// canonically equivalent commands that the host treats as distinct bytes.
    var id: Data {
        Data(event.utf8) + Data([0]) + Data(command.utf8) + Data([0])
            + Data((matcher ?? "").utf8) + Data([0]) + Data(String(timeoutSeconds).utf8)
    }
}

struct HermesShellHooksSnapshot: Equatable, Sendable {
    let hooks: [HermesShellHook]
    let validEvents: [String]
    fileprivate let sourceToken: Data
}

struct HermesShellHookDraft: Equatable, Sendable {
    let event: String
    let command: String
    let matcher: String?
    let timeoutSeconds: Int?
    let approve: Bool
}

struct HermesShellHookCreateReview: Equatable, Sendable {
    let draft: HermesShellHookDraft
    let existingMatchingEntries: Int
    let reviewedAt: Date
    fileprivate let owner: WorkspaceOwner
    fileprivate let sourceToken: Data
}

struct HermesShellHookDeleteReview: Equatable, Sendable {
    let hook: HermesShellHook
    let matchingCommandsRemoved: Int
    let reviewedAt: Date
    fileprivate let owner: WorkspaceOwner
    fileprivate let sourceToken: Data
}

struct HermesShellHookMutationReceipt: Equatable, Sendable {
    let snapshot: HermesShellHooksSnapshot
    let consentApproved: Bool?
}

extension DirectHermesHostOperationsClient {
    // MARK: Shell hooks

    func shellHooks() async throws -> HermesShellHooksSnapshot {
        try DirectHermesHostPayload.hooksSnapshot(try await json(
            .init(path: "/api/ops/hooks", method: .get, maximumResponseBytes: 512 * 1_024),
            feature: "shell-hook management"
        ))
    }

    func reviewShellHookCreation(_ draft: HermesShellHookDraft) async throws -> HermesShellHookCreateReview {
        let snapshot = try await shellHooks()
        let checked = try DirectHermesHostPayload.hookDraft(draft, validEvents: snapshot.validEvents)
        return .init(
            draft: checked,
            existingMatchingEntries: snapshot.hooks.filter {
                Data($0.event.utf8) == Data(checked.event.utf8)
                    && Data($0.command.utf8) == Data(checked.command.utf8)
                    && $0.matcher.map { Data($0.utf8) } == checked.matcher.map { Data($0.utf8) }
                    && $0.timeoutSeconds == (checked.timeoutSeconds ?? 60)
            }.count,
            reviewedAt: Date(), owner: owner, sourceToken: snapshot.sourceToken
        )
    }

    func createShellHook(reviewed review: HermesShellHookCreateReview) async throws
        -> HermesShellHookMutationReceipt {
        try requireOwner()
        guard review.owner == owner else { throw HostOperationsError.ownerChanged }
        let current = try await shellHooks()
        guard current.sourceToken == review.sourceToken else { throw HostOperationsError.reviewChanged }
        let draft = try DirectHermesHostPayload.hookDraft(review.draft, validEvents: current.validEvents)
        var body: [String: LoopdyJSONValue] = [
            "event": .string(draft.event), "command": .string(draft.command),
            "approve": .boolean(draft.approve),
        ]
        if let matcher = draft.matcher { body["matcher"] = .string(matcher) }
        if let timeout = draft.timeoutSeconds { body["timeout"] = .integer(timeout) }
        let response = try DirectHermesHostPayload.object(try await json(
            .init(path: "/api/ops/hooks", method: .post, body: body, maximumResponseBytes: 64 * 1_024),
            feature: "shell-hook creation", mutation: true
        ))
        guard response["ok"]?.boolean == true,
              let returnedEvent = response["event"]?.string,
              let returnedCommand = response["command"]?.string,
              Data(returnedEvent.utf8) == Data(draft.event.utf8),
              Data(returnedCommand.utf8) == Data(draft.command.utf8),
              let approved = response["approved"]?.boolean else {
            throw HostOperationsError.outcomeUnknown
        }
        let readback = try await shellHooks()
        let exact = readback.hooks.filter {
            Data($0.event.utf8) == Data(draft.event.utf8)
                && Data($0.command.utf8) == Data(draft.command.utf8)
                && $0.matcher.map { Data($0.utf8) } == draft.matcher.map { Data($0.utf8) }
                && $0.timeoutSeconds == (draft.timeoutSeconds ?? 60)
        }
        guard exact.count > review.existingMatchingEntries else {
            throw HostOperationsError.outcomeUnknown
        }
        return .init(snapshot: readback, consentApproved: approved)
    }

    func reviewShellHookDeletion(_ hook: HermesShellHook) async throws -> HermesShellHookDeleteReview {
        let snapshot = try await shellHooks()
        let matches = snapshot.hooks.filter {
            Data($0.event.utf8) == Data(hook.event.utf8)
                && Data($0.command.utf8) == Data(hook.command.utf8)
        }.count
        guard matches > 0 else { throw HostOperationsError.reviewChanged }
        return .init(
            hook: hook, matchingCommandsRemoved: matches, reviewedAt: Date(),
            owner: owner, sourceToken: snapshot.sourceToken
        )
    }

    func deleteShellHook(reviewed review: HermesShellHookDeleteReview) async throws
        -> HermesShellHookMutationReceipt {
        try requireOwner()
        guard review.owner == owner else { throw HostOperationsError.ownerChanged }
        let current = try await shellHooks()
        guard current.sourceToken == review.sourceToken else { throw HostOperationsError.reviewChanged }
        let matches = current.hooks.filter {
            Data($0.event.utf8) == Data(review.hook.event.utf8)
                && Data($0.command.utf8) == Data(review.hook.command.utf8)
        }.count
        guard matches == review.matchingCommandsRemoved else { throw HostOperationsError.reviewChanged }
        let response = try DirectHermesHostPayload.object(try await json(
            .init(
                path: "/api/ops/hooks", method: .delete,
                body: ["event": .string(review.hook.event), "command": .string(review.hook.command)],
                maximumResponseBytes: 64 * 1_024
            ),
            feature: "shell-hook deletion", mutation: true
        ))
        guard response["ok"]?.boolean == true else { throw HostOperationsError.outcomeUnknown }
        let readback = try await shellHooks()
        guard !readback.hooks.contains(where: {
            Data($0.event.utf8) == Data(review.hook.event.utf8)
                && Data($0.command.utf8) == Data(review.hook.command.utf8)
        }) else { throw HostOperationsError.outcomeUnknown }
        return .init(snapshot: readback, consentApproved: nil)
    }
}

extension DirectHermesHostPayload {
    static func hooksSnapshot(_ value: LoopdyJSONValue) throws -> HermesShellHooksSnapshot {
        let object = try object(value)
        let events = try strings(object["valid_events"], maximum: 256, maximumBytes: 128)
        var eventBytes = Set<Data>()
        let validEvents = try events.map {
            let checked = try safeIdentifier($0, maximumBytes: 128)
            guard eventBytes.insert(Data(checked.utf8)).inserted else {
                throw HostOperationsError.invalidResponse
            }
            return checked
        }
        let rows = try array(object["hooks"], maximum: 2_000)
        let hooks = try rows.map { value -> HermesShellHook in
            let row = try Self.object(value)
            let event = try safeIdentifier(try text(row["event"], maximumBytes: 128), maximumBytes: 128)
            guard validEvents.contains(where: { Data($0.utf8) == Data(event.utf8) }) else {
                throw HostOperationsError.invalidResponse
            }
            return .init(
                event: event,
                matcher: try optionalText(row["matcher"], maximumBytes: 8_192),
                command: try text(row["command"], maximumBytes: 8_192),
                timeoutSeconds: try integer(row["timeout"], range: 1...300),
                isAllowed: try boolean(row["allowed"]),
                approvedAt: try optionalText(row["approved_at"], maximumBytes: 128),
                isExecutable: try boolean(row["executable"])
            )
        }
        return .init(
            hooks: hooks, validEvents: validEvents,
            sourceToken: Data(SHA256.hash(data: try canonicalBytes(value)))
        )
    }

    static func hookDraft(
        _ draft: HermesShellHookDraft,
        validEvents: [String]
    ) throws -> HermesShellHookDraft {
        let event = draft.event.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !event.isEmpty, !command.isEmpty,
              event.utf8.count <= 128, command.utf8.count <= 8_192,
              validEvents.contains(where: { Data($0.utf8) == Data(event.utf8) }),
              !command.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw HostOperationsError.invalidRequest
        }
        let matcher: String?
        if let source = draft.matcher?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
            guard source.utf8.count <= 8_192,
                  event == "pre_tool_call" || event == "post_tool_call",
                  !source.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw HostOperationsError.invalidRequest
            }
            matcher = source
        } else {
            matcher = nil
        }
        if let timeout = draft.timeoutSeconds, !(1...300).contains(timeout) {
            throw HostOperationsError.invalidRequest
        }
        return .init(
            event: event, command: command, matcher: matcher,
            timeoutSeconds: draft.timeoutSeconds, approve: draft.approve
        )
    }
}
