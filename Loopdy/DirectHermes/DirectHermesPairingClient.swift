import Foundation

struct HermesPairingPendingRequest: Identifiable, Sendable {
    let platform: String
    let requestID: String
    let userID: String
    let userName: String
    let ageMinutes: Int

    var id: Data { Self.identity(platform: platform, value: requestID.isEmpty ? userID : requestID) }
    var canApproveByExactID: Bool { DirectHermesPairingClient.validRequestID(requestID) }

    static func identity(platform: String, value: String) -> Data {
        var data = Data(platform.utf8)
        data.append(0)
        data.append(contentsOf: value.utf8)
        return data
    }
}

extension HermesPairingPendingRequest: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        DirectHermesPairingClient.exact(lhs.platform, rhs.platform)
            && DirectHermesPairingClient.exact(lhs.requestID, rhs.requestID)
            && DirectHermesPairingClient.exact(lhs.userID, rhs.userID)
            && lhs.userName == rhs.userName
            && lhs.ageMinutes == rhs.ageMinutes
    }
}

struct HermesPairingApprovedUser: Identifiable, Sendable {
    let platform: String
    let userID: String
    let userName: String
    let approvedAt: Date?

    var id: Data { HermesPairingPendingRequest.identity(platform: platform, value: userID) }
}

extension HermesPairingApprovedUser: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        DirectHermesPairingClient.exact(lhs.platform, rhs.platform)
            && DirectHermesPairingClient.exact(lhs.userID, rhs.userID)
            && lhs.userName == rhs.userName
            && lhs.approvedAt == rhs.approvedAt
    }
}

struct HermesPairingCatalog: Equatable, Sendable {
    let profileID: String
    let pending: [HermesPairingPendingRequest]
    let approved: [HermesPairingApprovedUser]
}

@MainActor
protocol HermesPairingManaging: AnyObject {
    func list(profileID: String) async throws -> HermesPairingCatalog
    func approve(_ request: HermesPairingPendingRequest, profileID: String) async throws -> HermesPairingApprovedUser
    func revoke(_ user: HermesPairingApprovedUser, profileID: String) async throws
    func clearPending(profileID: String) async throws -> Int
}

/// Pairing administration is separate from Loopdy notification registration.
/// Approval accepts only the exact server-side request ID returned by the pairing
/// list; it never accepts, displays, or stores a DM pairing code.
@MainActor
final class DirectHermesPairingClient: HermesPairingManaging {
    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?

    init(
        rpc: any DirectHermesRPC,
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        self.rpc = rpc
        self.http = http
        self.owner = owner
        self.currentOwner = currentOwner
    }

    func list(profileID: String) async throws -> HermesPairingCatalog {
        let profile = try Self.profile(profileID)
        let value = try await request(.init(
            path: "/api/pairing", method: .get,
            query: [.init(name: "profile", value: profile)]
        ))
        guard let object = value.object,
              let pendingValues = object["pending"]?.array, pendingValues.count <= 500,
              let approvedValues = object["approved"]?.array, approvedValues.count <= 2_000 else {
            throw WorkspaceClientError.invalidResponse
        }
        let pending = try pendingValues.map(Self.pending)
        let approved = try approvedValues.map(Self.approved)
        guard Self.uniquePending(pending), Self.uniqueApproved(approved) else {
            throw WorkspaceClientError.invalidResponse
        }
        return .init(profileID: profile, pending: pending, approved: approved)
    }

    func approve(
        _ request: HermesPairingPendingRequest,
        profileID: String
    ) async throws -> HermesPairingApprovedUser {
        let profile = try Self.profile(profileID)
        let platform = try Self.platform(request.platform)
        guard Self.validRequestID(request.requestID) else { throw WorkspaceClientError.invalidRequest }
        let before = try await list(profileID: profile)
        guard before.pending.contains(where: {
            Self.exact($0.platform, platform)
                && Self.exact($0.requestID, request.requestID)
                && Self.exact($0.userID, request.userID)
        }) else { throw WorkspaceClientError.conflict }

        let value = try await self.request(.init(
            path: "/api/pairing/approve", method: .post,
            body: [
                "platform": .string(platform), "request_id": .string(request.requestID),
                "profile": .string(profile)
            ]
        ))
        guard let object = value.object, object["ok"]?.boolean == true,
              let user = object["user"]?.object,
              let userID = Self.text(user["user_id"], maximum: 512),
              let userName = Self.text(user["user_name"], maximum: 512, empty: true),
              Self.exact(userID, request.userID) else {
            throw WorkspaceClientError.outcomeUnknown
        }

        let after = try await list(profileID: profile)
        guard !after.pending.contains(where: {
            Self.exact($0.platform, platform) && Self.exact($0.requestID, request.requestID)
        }), let approved = after.approved.first(where: {
            Self.exact($0.platform, platform) && Self.exact($0.userID, userID)
        }) else { throw WorkspaceClientError.outcomeUnknown }
        guard approved.userName == userName || userName.isEmpty else { throw WorkspaceClientError.outcomeUnknown }
        return approved
    }

    func revoke(_ user: HermesPairingApprovedUser, profileID: String) async throws {
        let profile = try Self.profile(profileID)
        let platform = try Self.platform(user.platform)
        let userID = try Self.userID(user.userID)
        let before = try await list(profileID: profile)
        guard before.approved.contains(where: {
            Self.exact($0.platform, platform) && Self.exact($0.userID, userID)
        }) else { throw WorkspaceClientError.conflict }

        let value = try await request(.init(
            path: "/api/pairing/revoke", method: .post,
            body: [
                "platform": .string(platform), "user_id": .string(userID),
                "profile": .string(profile)
            ]
        ))
        guard value.object?["ok"]?.boolean == true else { throw WorkspaceClientError.outcomeUnknown }
        let after = try await list(profileID: profile)
        guard !after.approved.contains(where: {
            Self.exact($0.platform, platform) && Self.exact($0.userID, userID)
        }) else { throw WorkspaceClientError.outcomeUnknown }
    }

    func clearPending(profileID: String) async throws -> Int {
        let profile = try Self.profile(profileID)
        let before = try await list(profileID: profile)
        let value = try await request(.init(
            path: "/api/pairing/clear-pending", method: .post,
            query: [.init(name: "profile", value: profile)], body: [:]
        ))
        guard let object = value.object, object["ok"]?.boolean == true,
              let cleared = object["cleared"]?.integer,
              cleared >= 0, cleared == before.pending.count else {
            throw WorkspaceClientError.outcomeUnknown
        }
        let after = try await list(profileID: profile)
        guard after.pending.isEmpty else { throw WorkspaceClientError.outcomeUnknown }
        return cleared
    }

    private func request(_ request: DirectHermesHTTPRequest) async throws -> LoopdyJSONValue {
        try checkOwner()
        do {
            let value = try await http.request(request)
            try checkOwner()
            return value
        } catch {
            try checkOwner()
            throw error
        }
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        _ = rpc
        guard owner.authority.kind == .direct, currentOwner() == owner else {
            throw WorkspaceClientError.ownerChanged
        }
    }

    private static func pending(_ value: LoopdyJSONValue) throws -> HermesPairingPendingRequest {
        guard let object = value.object,
              let platform = text(object["platform"], maximum: 128),
              let requestID = text(object["request_id"], maximum: 64, empty: true),
              let userID = text(object["user_id"], maximum: 512),
              let userName = text(object["user_name"], maximum: 512, empty: true),
              let age = object["age_minutes"]?.integer, age >= 0 else {
            throw WorkspaceClientError.invalidResponse
        }
        _ = try Self.platform(platform)
        guard requestID.isEmpty || validRequestID(requestID) else { throw WorkspaceClientError.invalidResponse }
        return .init(platform: platform, requestID: requestID, userID: userID,
                     userName: userName, ageMinutes: age)
    }

    private static func approved(_ value: LoopdyJSONValue) throws -> HermesPairingApprovedUser {
        guard let object = value.object,
              let platform = text(object["platform"], maximum: 128),
              let userID = text(object["user_id"], maximum: 512),
              let userName = text(object["user_name"], maximum: 512, empty: true) else {
            throw WorkspaceClientError.invalidResponse
        }
        _ = try Self.platform(platform)
        let date: Date?
        if object["approved_at"] == nil || object["approved_at"] == .null {
            date = nil
        } else if let timestamp = object["approved_at"]?.number,
                  timestamp.isFinite, timestamp >= 0 {
            date = Date(timeIntervalSince1970: timestamp)
        } else {
            throw WorkspaceClientError.invalidResponse
        }
        return .init(platform: platform, userID: userID, userName: userName, approvedAt: date)
    }

    private static func uniquePending(_ values: [HermesPairingPendingRequest]) -> Bool {
        for index in values.indices {
            for other in values.indices where other > index {
                if exact(values[index].platform, values[other].platform),
                   exact(values[index].requestID, values[other].requestID),
                   !values[index].requestID.isEmpty { return false }
            }
        }
        return true
    }

    private static func uniqueApproved(_ values: [HermesPairingApprovedUser]) -> Bool {
        for index in values.indices {
            for other in values.indices where other > index {
                if exact(values[index].platform, values[other].platform),
                   exact(values[index].userID, values[other].userID) { return false }
            }
        }
        return true
    }

    nonisolated static func validRequestID(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    nonisolated static func exact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func profile(_ value: String) throws -> String {
        try DirectHermesCoreRequestScope.profile(value)
    }

    private static func platform(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0)
                  || $0 == 45 || $0 == 95 }) else { throw WorkspaceClientError.invalidRequest }
        return value
    }

    private static func userID(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw WorkspaceClientError.invalidRequest
        }
        return value
    }

    private static func text(
        _ value: LoopdyJSONValue?,
        maximum: Int,
        empty: Bool = false
    ) -> String? {
        guard let text = value?.string, text.utf8.count <= maximum,
              (empty || !text.isEmpty),
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return text
    }
}
