import Foundation

enum HermesBotModeApprovalChoice: String, Codable, Equatable, Sendable {
    case once
    case deny
}

/// The exact decision submitted to a hosted-room approval gate.
struct HermesBotModeApprovalDecision: Codable, Equatable, Sendable {
    let requestID: String
    let choice: HermesBotModeApprovalChoice

    init(requestID: String, choice: HermesBotModeApprovalChoice) {
        self.requestID = requestID
        self.choice = choice
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case choice
    }
}

/// One approval action reported by `groups.state`'s outer `driver_status`.
///
/// Hermes filters the choices exposed by hosted rooms to `once` and `deny`.
/// Other pending action kinds, such as retry, are intentionally ignored by the
/// decoder and remain owned by their corresponding operation.
struct HermesBotModePendingApproval: Identifiable, Equatable, Sendable {
    let roomID: String
    let memberID: String
    let taskID: String
    let executionGeneration: Int
    let requestID: String
    let command: String?
    let description: String?
    let choices: [HermesBotModeApprovalChoice]

    var id: String {
        [roomID, memberID, taskID, String(executionGeneration), requestID]
            .map { "\($0.utf8.count):\($0)" }
            .joined()
    }

    var decisionChoices: [HermesBotModeApprovalDecision] {
        choices.map { HermesBotModeApprovalDecision(requestID: requestID, choice: $0) }
    }

    /// Decodes only approval actions from the exact `groups.state` status map.
    /// Unknown action kinds are ignored. A recognized approval with malformed
    /// identity, request, command, or choice data throws instead of vanishing.
    static func decode(
        roomID: String,
        driverStatus: [String: LoopdyJSONValue]?
    ) throws -> [Self] {
        guard !roomID.isEmpty else { throw HermesBotModeApprovalError.invalidPendingAction }
        guard let driverStatus else { return [] }
        guard let rawActions = driverStatus["pending_actions"] else { return [] }
        guard case .array(let actions) = rawActions else {
            throw HermesBotModeApprovalError.invalidPendingAction
        }

        return try actions.compactMap { rawAction in
            guard case .object(let action) = rawAction else {
                throw HermesBotModeApprovalError.invalidPendingAction
            }
            guard let rawKind = action["kind"] else {
                throw HermesBotModeApprovalError.invalidPendingAction
            }
            guard case .string(let kind) = rawKind else {
                throw HermesBotModeApprovalError.invalidPendingAction
            }
            guard kind == "approval" else { return nil }

            guard let memberID = action["member_id"]?.nonEmptyString,
                  let taskID = action["task_id"]?.nonEmptyString,
                  let executionGeneration = action["execution_generation"]?.integer,
                  executionGeneration > 0,
                  let requestID = action["request_id"]?.nonEmptyString,
                  case .object(let approval)? = action["approval"],
                  let approvalRequestID = approval["request_id"]?.nonEmptyString,
                  approvalRequestID == requestID,
                  case .array(let rawChoices)? = approval["choices"]
            else {
                throw HermesBotModeApprovalError.invalidPendingAction
            }

            let command: String?
            if let rawCommand = approval["command"], rawCommand != .null {
                guard let value = rawCommand.nonEmptyString else {
                    throw HermesBotModeApprovalError.invalidPendingAction
                }
                command = value
            } else {
                command = nil
            }

            let choices = try rawChoices.map { rawChoice -> HermesBotModeApprovalChoice in
                guard case .string(let rawValue) = rawChoice,
                      let choice = HermesBotModeApprovalChoice(rawValue: rawValue)
                else {
                    throw HermesBotModeApprovalError.invalidPendingAction
                }
                return choice
            }
            guard !choices.isEmpty else {
                throw HermesBotModeApprovalError.invalidPendingAction
            }
            let description: String?
            if let rawDescription = approval["description"] {
                guard case .string(let value) = rawDescription else {
                    throw HermesBotModeApprovalError.invalidPendingAction
                }
                description = value
            } else {
                description = nil
            }

            return Self(
                roomID: roomID,
                memberID: memberID,
                taskID: taskID,
                executionGeneration: executionGeneration,
                requestID: requestID,
                command: command,
                description: description,
                choices: choices
            )
        }
    }
}

struct HermesBotModeApprovalReceipt: Codable, Equatable, Sendable {
    let approved: Bool
    let result: [String: LoopdyJSONValue]
}

enum HermesBotModeApprovalError: Error, Equatable {
    case invalidPendingAction
}

@MainActor
protocol HermesBotModeApprovalClient: AnyObject {
    func groupsApprove(
        roomID: String,
        memberID: String,
        taskID: String,
        executionGeneration: Int,
        requestID: String,
        choice: HermesBotModeApprovalChoice
    ) async throws -> HermesBotModeApprovalReceipt
}

extension LoopdyLinkHermesBotModeClient: HermesBotModeApprovalClient {}

private extension LoopdyJSONValue {
    var nonEmptyString: String? {
        guard case .string(let value) = self else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}
