import CryptoKit
import Foundation

struct HermesGatewayMigrationPlan: Equatable, Sendable {
    struct Profile: Identifiable, Equatable, Sendable {
        let id: String
        let hasRunningProcess: Bool
        let serviceKind: String?
        let isSystemService: Bool?
    }

    let profiles: [Profile]
    let multiplexFlagOn: Bool
    let liveServedProfiles: [String]
    let alreadyMultiplexed: Bool
    let blockers: [String]
    let notices: [String]
    let isEligible: Bool
    fileprivate let reviewToken: Data
}

struct HermesGatewayDrainResult: Equatable, Sendable {
    enum Action: String, Sendable { case drain, cancel }
    let action: Action
    let markerPresent: Bool
    let wasDraining: Bool?
    let requestedAt: String?
}

enum HermesMessagingGatewayCommand: String, Sendable {
    case start, stop, restart

    fileprivate var action: HermesHostAction {
        switch self {
        case .start: .gatewayStart
        case .stop: .gatewayStop
        case .restart: .gatewayRestart
        }
    }
}

extension DirectHermesHostOperationsClient {
    func gatewayMigrationPlan() async throws -> HermesGatewayMigrationPlan {
        let value = try await json(
            .init(path: "/api/gateway/migrate/plan", method: .get, maximumResponseBytes: 256 * 1_024),
            feature: "messaging-gateway migration planning"
        )
        return try DirectHermesHostPayload.migrationPlan(value)
    }

    func launchGatewayMigration(reviewed plan: HermesGatewayMigrationPlan) async throws -> HermesHostActionReceipt {
        guard plan.isEligible, plan.blockers.isEmpty, !plan.alreadyMultiplexed else {
            throw HostOperationsError.invalidRequest
        }
        let current = try await gatewayMigrationPlan()
        guard current.reviewToken == plan.reviewToken, current.isEligible,
              current.blockers.isEmpty, !current.alreadyMultiplexed else {
            throw HostOperationsError.reviewChanged
        }
        return try await launch(
            .init(path: "/api/gateway/migrate", method: .post, body: [:]),
            expectedAction: .gatewayMigrate,
            feature: "messaging-gateway migration"
        )
    }

    func setGatewayDraining(_ draining: Bool) async throws -> HermesGatewayDrainResult {
        let expected = draining ? "drain" : "cancel"
        let object = try DirectHermesHostPayload.object(try await json(
            .init(
                path: "/api/gateway/drain", method: .post,
                body: ["action": .string(expected), "suppress_notification": .boolean(false)]
            ),
            feature: "messaging-gateway drain control",
            mutation: true
        ))
        guard object["ok"]?.boolean == true,
              object["action"]?.string == expected,
              let action = HermesGatewayDrainResult.Action(rawValue: expected) else {
            throw HostOperationsError.outcomeUnknown
        }
        if draining {
            guard let marker = object["draining"]?.boolean else { throw HostOperationsError.outcomeUnknown }
            return .init(
                action: action, markerPresent: marker, wasDraining: nil,
                requestedAt: try DirectHermesHostPayload.optionalText(object["requested_at"], maximumBytes: 128)
            )
        }
        return .init(
            action: action, markerPresent: false,
            wasDraining: object["was_draining"]?.boolean,
            requestedAt: nil
        )
    }

    func launchMessagingGateway(
        _ command: HermesMessagingGatewayCommand,
        profileID: String
    ) async throws -> HermesHostActionReceipt {
        let profile = try DirectHermesHostPayload.profile(profileID)
        return try await launch(
            .init(
                path: "/api/gateway/\(command.rawValue)", method: .post,
                query: [.init(name: "profile", value: profile)], body: [:]
            ),
            expectedAction: command.action,
            feature: "messaging-gateway \(command.rawValue)"
        )
    }
}

extension DirectHermesHostPayload {
    static func migrationPlan(_ value: BighelpJSONValue) throws -> HermesGatewayMigrationPlan {
        let row = try object(value)
        let profiles = try array(row["profiles"], maximum: 128).map { value in
            let item = try object(value)
            let service: [String: BighelpJSONValue]?
            if item["service"] == nil || item["service"] == .null { service = nil }
            else { service = try object(item["service"] ?? .null) }
            let serviceKind: String?
            if let service {
                serviceKind = try optionalText(service["kind"], maximumBytes: 64)
            } else {
                serviceKind = nil
            }
            return HermesGatewayMigrationPlan.Profile(
                id: try safeIdentifier(try text(item["profile"], maximumBytes: 128), maximumBytes: 128),
                hasRunningProcess: item["pid"] != nil && item["pid"] != .null,
                serviceKind: serviceKind,
                isSystemService: service?["system"]?.boolean
            )
        }
        let canonical = try canonicalBytes(value)
        return .init(
            profiles: profiles,
            multiplexFlagOn: try boolean(row["multiplex_flag_on"]),
            liveServedProfiles: try strings(row["live_served"], maximum: 128, maximumBytes: 128),
            alreadyMultiplexed: try boolean(row["already_multiplexed"]),
            blockers: try strings(row["blockers"], maximum: 128, maximumBytes: 8_192),
            notices: try strings(row["notices"], maximum: 128, maximumBytes: 8_192),
            isEligible: try boolean(row["eligible"]),
            reviewToken: Data(SHA256.hash(data: canonical))
        )
    }
}
