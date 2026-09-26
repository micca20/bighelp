import CryptoKit
import Foundation

/// Conditional client for the public bundled Achievements dashboard mount.
/// Discovery uses `/scan-status`, which does not itself start a history scan.
@MainActor
final class DirectHermesAchievementsClient {
    nonisolated static let maximumResponseBytes = 4 * 1_024 * 1_024
    nonisolated static let maximumAchievements = 512
    nonisolated static let pollingIntervalNanoseconds: UInt64 = 2_000_000_000

    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private(set) var mount: HermesAchievementsMount = .unknown

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

    var ownsScope: Bool { currentOwner() == owner }

    @discardableResult
    func discoverMount() async throws -> HermesAchievementsMount {
        try requireOwner()
        let probe = DirectHermesHTTPRequest(
            path: "/api/plugins/hermes-achievements/scan-status", method: .get,
            maximumResponseBytes: 128 * 1_024
        )
        do {
            let value: BighelpJSONValue
            if let native = http as? any DirectHermesNativeHTTP {
                let response = try await native.nativeResponse(probe, requestGuard: nil)
                try requireOwner()
                switch response.http.statusCode {
                case 200...299: value = try response.value()
                case 404, 405:
                    mount = .unavailable
                    return mount
                case 401, 403: throw WorkspaceClientError.authenticationRequired
                default:
                    try DirectHermesHTTP.requireSuccess(response)
                    value = try response.value()
                }
            } else {
                value = try await http.request(probe)
            }
            _ = try Self.decodeStatus(value)
            try requireOwner()
            mount = .available
            return mount
        } catch DirectHermesError.unsupportedAuthentication {
            try requireOwner()
            mount = .unavailable
            return mount
        } catch WorkspaceClientError.unavailable(_) {
            try requireOwner()
            mount = .unavailable
            return mount
        } catch {
            try requireOwner()
            throw Self.safe(error, mutation: false)
        }
    }

    func scanStatus() async throws -> HermesAchievementScanStatus {
        try await requireMount()
        let value = try await request(.init(
            path: "/api/plugins/hermes-achievements/scan-status", method: .get,
            maximumResponseBytes: 128 * 1_024
        ))
        return try Self.decodeStatus(value)
    }

    func catalog() async throws -> HermesAchievementsCatalog {
        try await requireMount()
        let value = try await request(.init(
            path: "/api/plugins/hermes-achievements/achievements", method: .get,
            maximumResponseBytes: Self.maximumResponseBytes
        ))
        return try Self.decodeCatalog(value)
    }

    func recentUnlocks() async throws -> [HermesAchievement] {
        try await requireMount()
        let value = try await request(.init(
            path: "/api/plugins/hermes-achievements/recent-unlocks", method: .get,
            maximumResponseBytes: Self.maximumResponseBytes
        ))
        guard let rows = value.array, rows.count <= 20 else { throw HermesAchievementsError.invalidResponse }
        let achievements = try rows.map(Self.decodeAchievement)
        guard Set(achievements.map(\.id)).count == achievements.count,
              achievements.allSatisfy(\.isUnlocked) else { throw HermesAchievementsError.invalidResponse }
        return achievements
    }

    func sessionBadges(sessionID: String) async throws -> [HermesAchievement] {
        try await requireMount()
        let sessionID = try Self.identifier(sessionID, maximum: 512)
        let value = try await request(.init(
            path: "/api/plugins/hermes-achievements/sessions/\(Self.component(sessionID))/badges", method: .get,
            maximumResponseBytes: Self.maximumResponseBytes
        ))
        guard let object = value.object,
              object["session_id"]?.string.map({ Self.exact($0, sessionID) }) == true,
              let rows = object["badges"]?.array, rows.count <= Self.maximumAchievements else {
            throw HermesAchievementsError.invalidResponse
        }
        let achievements = try rows.map(Self.decodeAchievement)
        guard Set(achievements.map(\.id)).count == achievements.count else {
            throw HermesAchievementsError.invalidResponse
        }
        return achievements
    }

    func prepare(_ action: HermesAchievementsReview.Action) async throws -> HermesAchievementsReview {
        async let catalogValue = catalog()
        async let statusValue = scanStatus()
        let catalog = try await catalogValue
        let status = try await statusValue
        guard status.state != .running else { throw HermesAchievementsError.scanStillRunning }
        return .init(
            action: action,
            catalogRevision: try Self.revision(catalog),
            status: status,
            unlockedCount: catalog.unlockedCount,
            totalCount: catalog.totalCount
        )
    }

    func rescan(approved review: HermesAchievementsReview, maximumPolls: Int = 90) async throws
        -> HermesAchievementsRescanResult {
        guard review.action == .rescan, (1...300).contains(maximumPolls) else {
            throw HermesAchievementsError.invalidRequest
        }
        let currentCatalog = try await catalog()
        let currentStatus = try await scanStatus()
        guard try Self.revision(currentCatalog) == review.catalogRevision,
              Self.sameStableStatus(currentStatus, review.status), currentStatus.state != .running else {
            throw HermesAchievementsError.reviewChanged
        }
        do {
            let value = try await mutate(.init(
                path: "/api/plugins/hermes-achievements/rescan", method: .post,
                maximumResponseBytes: Self.maximumResponseBytes
            ))
            guard value.object?["ok"]?.boolean == true else { throw HermesAchievementsError.invalidResponse }
            let status = try await scanStatus()
            let catalog = try Self.decodeCatalog(value, statusOverride: status)
            return try Self.finishedResult(catalog: catalog, status: status, previousRunCount: review.status.runCount)
        } catch WorkspaceClientError.outcomeUnknown {
            return try await reconcileRescan(previousRunCount: review.status.runCount, maximumPolls: maximumPolls)
        }
    }

    func reset(approved review: HermesAchievementsReview) async throws -> HermesAchievementScanStatus {
        guard review.action == .reset else { throw HermesAchievementsError.invalidRequest }
        let currentCatalog = try await catalog()
        let currentStatus = try await scanStatus()
        guard try Self.revision(currentCatalog) == review.catalogRevision,
              Self.sameStableStatus(currentStatus, review.status), currentStatus.state != .running else {
            throw HermesAchievementsError.reviewChanged
        }
        do {
            let value = try await mutate(.init(
                path: "/api/plugins/hermes-achievements/reset-state", method: .post,
                maximumResponseBytes: 64 * 1_024
            ))
            guard value.object?["ok"]?.boolean == true else { throw HermesAchievementsError.resetNotVerified }
        } catch WorkspaceClientError.outcomeUnknown {
            // Never replay an uncertain destructive reset.
            throw HermesAchievementsError.resetNotVerified
        }
        let status = try await scanStatus()
        guard status.state == .idle,
              status.startedAt == nil, status.finishedAt == nil, status.lastError == nil,
              status.lastDurationMilliseconds == nil, status.snapshotGeneratedAt == nil else {
            throw HermesAchievementsError.resetNotVerified
        }
        return status
    }

    private func reconcileRescan(previousRunCount: Int, maximumPolls: Int) async throws
        -> HermesAchievementsRescanResult {
        var status = try await scanStatus()
        for _ in 0..<maximumPolls where status.state == .running || status.runCount == previousRunCount {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: Self.pollingIntervalNanoseconds)
            status = try await scanStatus()
        }
        switch status.state {
        case .running:
            return .running(status)
        case .failed:
            guard status.runCount > previousRunCount else { throw HermesAchievementsError.invalidResponse }
            return .failed(status)
        case .idle:
            guard status.runCount > previousRunCount else { throw HermesAchievementsError.invalidResponse }
            return .completed(try await catalog(), status)
        }
    }

    private static func finishedResult(
        catalog: HermesAchievementsCatalog,
        status: HermesAchievementScanStatus,
        previousRunCount: Int
    ) throws -> HermesAchievementsRescanResult {
        switch status.state {
        case .running: return .running(status)
        case .failed:
            guard status.runCount > previousRunCount else { throw HermesAchievementsError.invalidResponse }
            return .failed(status)
        case .idle:
            guard status.runCount > previousRunCount else { throw HermesAchievementsError.invalidResponse }
            return .completed(catalog, status)
        }
    }

    private func requireMount() async throws {
        try requireOwner()
        if mount == .unknown { _ = try await discoverMount() }
        guard mount == .available else { throw HermesAchievementsError.unavailable }
    }

    private func requireOwner() throws {
        try Task.checkCancellation()
        guard currentOwner() == owner else { throw HermesAchievementsError.staleOwner }
        _ = rpc
    }

    private func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        try requireOwner()
        do {
            let value = try await http.request(request)
            try requireOwner()
            guard try JSONEncoder().encode(value).count <= request.maximumResponseBytes else {
                throw HermesAchievementsError.capacityExceeded
            }
            return value
        } catch {
            try requireOwner()
            throw Self.safe(error, mutation: false)
        }
    }

    private func mutate(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        try requireOwner()
        do {
            let value = try await http.request(request)
            try requireOwner()
            return value
        } catch {
            try requireOwner()
            throw Self.safe(error, mutation: true)
        }
    }

    private static func safe(_ error: any Error, mutation: Bool) -> any Error {
        if error is CancellationError || error is HermesAchievementsError || error is WorkspaceClientError { return error }
        guard let direct = error as? DirectHermesError else {
            return mutation ? WorkspaceClientError.outcomeUnknown : WorkspaceClientError.transportUnavailable
        }
        if direct.outcomeIsUnknown { return WorkspaceClientError.outcomeUnknown }
        switch direct {
        case .invalidCredentials, .authenticationRequired: return WorkspaceClientError.authenticationRequired
        case .unsupportedAuthentication: return HermesAchievementsError.unavailable
        case .invalidResponse: return HermesAchievementsError.invalidResponse
        case .messageTooLarge, .tooManyRequests: return HermesAchievementsError.capacityExceeded
        default: return WorkspaceClientError.transportUnavailable
        }
    }

    private static func decodeCatalog(
        _ value: BighelpJSONValue,
        statusOverride: HermesAchievementScanStatus? = nil
    ) throws -> HermesAchievementsCatalog {
        guard let object = value.object,
              let rows = object["achievements"]?.array, rows.count <= maximumAchievements,
              let unlocked = object["unlocked_count"]?.integer, unlocked >= 0,
              let discovered = object["discovered_count"]?.integer, discovered >= 0,
              let secret = object["secret_count"]?.integer, secret >= 0,
              let total = object["total_count"]?.integer, total == rows.count,
              let generated = object["generated_at"]?.number,
              let meta = object["scan_meta"]?.object else {
            throw HermesAchievementsError.invalidResponse
        }
        let stale = object["is_stale"]?.boolean ?? false
        let status: HermesAchievementScanStatus
        if let statusOverride {
            status = statusOverride
        } else if let statusValue = meta["status"] {
            status = try decodeStatus(statusValue)
        } else {
            throw HermesAchievementsError.invalidResponse
        }
        let achievements = try rows.map(Self.decodeAchievement)
        guard Set(achievements.map(\.id)).count == achievements.count,
              achievements.filter(\.isUnlocked).count == unlocked,
              unlocked + discovered + secret == total else {
            throw HermesAchievementsError.invalidResponse
        }
        return .init(
            achievements: achievements, unlockedCount: unlocked,
            discoveredCount: discovered, secretCount: secret, totalCount: total,
            generatedAt: Date(timeIntervalSince1970: generated), isStale: stale,
            scanMode: try optionalText(meta["mode"], maximum: 80) ?? "unknown",
            sessionsTotal: try integer(meta["sessions_total"], default: 0),
            sessionsRescanned: try integer(meta["sessions_rescanned"], default: 0),
            sessionsReused: try integer(meta["sessions_reused"], default: 0),
            sessionsScannedSoFar: try optionalInteger(meta["sessions_scanned_so_far"]),
            sessionsExpectedTotal: try optionalInteger(meta["sessions_expected_total"]),
            status: status,
            error: object["error"] == nil || object["error"] == .null ? nil : "Hermes reported an achievements scan error."
        )
    }

    private static func decodeStatus(_ value: BighelpJSONValue) throws -> HermesAchievementScanStatus {
        guard let row = value.object,
              let raw = row["state"]?.string,
              let state = HermesAchievementScanState(rawValue: raw),
              let runCount = row["run_count"]?.integer, runCount >= 0,
              let ttl = row["ttl_seconds"]?.integer, ttl > 0,
              let stale = row["snapshot_stale"]?.boolean else {
            throw HermesAchievementsError.invalidResponse
        }
        return .init(
            state: state,
            startedAt: try optionalDate(row["started_at"]),
            finishedAt: try optionalDate(row["finished_at"]),
            lastError: row["last_error"] == nil || row["last_error"] == .null ? nil : "Hermes reported that the achievements scan failed.",
            lastDurationMilliseconds: try optionalInteger(row["last_duration_ms"]),
            runCount: runCount, TTLSeconds: ttl,
            snapshotGeneratedAt: try optionalDate(row["snapshot_generated_at"]),
            snapshotAgeSeconds: try optionalInteger(row["snapshot_age_seconds"]),
            snapshotIsStale: stale
        )
    }

    private static func decodeAchievement(_ value: BighelpJSONValue) throws -> HermesAchievement {
        guard let row = value.object,
              let unlocked = row["unlocked"]?.boolean,
              let discovered = row["discovered"]?.boolean,
              let progress = row["progress"]?.integer, progress >= 0,
              let progressPercent = row["progress_pct"]?.integer, (0...100).contains(progressPercent) else {
            throw HermesAchievementsError.invalidResponse
        }
        let secret = row["secret"]?.boolean ?? false
        let evidence: HermesAchievementEvidence?
        if let raw = row["evidence"], raw != .null {
            guard let object = raw.object else { throw HermesAchievementsError.invalidResponse }
            evidence = .init(
                sessionID: try optionalText(object["session_id"], maximum: 512),
                sessionTitle: try optionalText(object["title"], maximum: 2_048),
                value: try optionalInteger(object["value"])
            )
        } else {
            evidence = nil
        }
        return .init(
            id: try text(row["id"], maximum: 160),
            name: try text(row["name"], maximum: 240),
            summary: try text(row["description"], maximum: 4_096),
            criteria: try text(row["criteria"], maximum: 8_192),
            category: try text(row["category"], maximum: 160),
            kind: try text(row["kind"], maximum: 80),
            icon: try text(row["icon"], maximum: 120),
            isSecret: secret, isUnlocked: unlocked, isDiscovered: discovered,
            state: try text(row["state"], maximum: 80),
            tier: try optionalText(row["tier"], maximum: 120),
            progress: progress, progressPercent: progressPercent,
            nextTier: try optionalText(row["next_tier"], maximum: 120),
            nextThreshold: try optionalInteger(row["next_threshold"]),
            unlockedAt: try optionalDate(row["unlocked_at"]), evidence: evidence
        )
    }

    private static func revision(_ catalog: HermesAchievementsCatalog) throws -> Data {
        let value: BighelpJSONValue = .object([
            "generated_at": .number(catalog.generatedAt.timeIntervalSince1970),
            "counts": .array([
                .integer(catalog.unlockedCount), .integer(catalog.discoveredCount),
                .integer(catalog.secretCount), .integer(catalog.totalCount),
            ]),
            "achievements": .array(catalog.achievements.map {
                .object([
                    "id": .string($0.id), "state": .string($0.state),
                    "tier": $0.tier.map(BighelpJSONValue.string) ?? .null,
                    "progress": .integer($0.progress), "unlocked": .boolean($0.isUnlocked),
                ])
            }),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumResponseBytes else { throw HermesAchievementsError.capacityExceeded }
        return Data(SHA256.hash(data: data))
    }

    private static func text(_ value: BighelpJSONValue?, maximum: Int) throws -> String {
        guard let string = value?.string, !string.isEmpty, string.utf8.count <= maximum,
              !string.unicodeScalars.contains(where: { $0.value == 0 || (0x202A...0x202E).contains($0.value) }) else {
            throw HermesAchievementsError.invalidResponse
        }
        return string
    }

    private static func optionalText(_ value: BighelpJSONValue?, maximum: Int) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let string = value.string, string.utf8.count <= maximum,
              !string.unicodeScalars.contains(where: { $0.value == 0 || (0x202A...0x202E).contains($0.value) }) else {
            throw HermesAchievementsError.invalidResponse
        }
        return string
    }

    private static func integer(_ value: BighelpJSONValue?, default defaultValue: Int) throws -> Int {
        guard let value else { return defaultValue }
        guard let integer = value.integer, integer >= 0 else { throw HermesAchievementsError.invalidResponse }
        return integer
    }

    private static func optionalInteger(_ value: BighelpJSONValue?) throws -> Int? {
        guard let value, value != .null else { return nil }
        guard let integer = value.integer, integer >= 0 else { throw HermesAchievementsError.invalidResponse }
        return integer
    }

    private static func optionalDate(_ value: BighelpJSONValue?) throws -> Date? {
        guard let value, value != .null else { return nil }
        guard let seconds = value.number, seconds.isFinite,
              (-62_135_596_800...253_402_300_799).contains(seconds) else {
            throw HermesAchievementsError.invalidResponse
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func identifier(_ value: String, maximum: Int) throws -> String {
        guard !value.isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HermesAchievementsError.invalidRequest
        }
        return value
    }

    private static func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? ""
    }

    private static func exact(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }

    private static func sameStableStatus(
        _ lhs: HermesAchievementScanStatus,
        _ rhs: HermesAchievementScanStatus
    ) -> Bool {
        lhs.state == rhs.state && lhs.startedAt == rhs.startedAt &&
        lhs.finishedAt == rhs.finishedAt && lhs.lastError == rhs.lastError &&
        lhs.lastDurationMilliseconds == rhs.lastDurationMilliseconds &&
        lhs.runCount == rhs.runCount && lhs.TTLSeconds == rhs.TTLSeconds &&
        lhs.snapshotGeneratedAt == rhs.snapshotGeneratedAt
    }
}
