import CryptoKit
import Foundation

// MARK: - Schema decoding

enum DirectHermesHostPayload: DirectHermesPayloadDecoding {
    static var invalidResponse: any Error { HostOperationsError.invalidResponse }
    static var arrayOverflow: any Error { HostOperationsError.invalidResponse }
    static let requiresNonemptyText = false

    static func strings(
        _ value: BighelpJSONValue?,
        maximum: Int,
        maximumBytes: Int
    ) throws -> [String] {
        guard value != nil, value != .null else { return [] }
        return try array(value, maximum: maximum).map { try text($0, maximumBytes: maximumBytes) }
    }

    static func numbers(
        _ value: BighelpJSONValue?,
        maximum: Int,
        range: ClosedRange<Double>
    ) throws -> [Double] {
        guard value != nil, value != .null else { return [] }
        return try array(value, maximum: maximum).map { try number($0, range: range) }
    }

    static func safeIdentifier(_ value: String, maximumBytes: Int) throws -> String {
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HostOperationsError.invalidResponse
        }
        return value
    }

    static func profile(_ value: String) throws -> String {
        let profile = try safeIdentifier(value, maximumBytes: 128)
        guard profile != "all", profile != ".", profile != "..",
              !profile.contains("/"), !profile.contains("\\") else {
            throw HostOperationsError.invalidRequest
        }
        return profile
    }

    static func hostArchivePath(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 4_096,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.lowercased().hasSuffix(".zip"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HostOperationsError.invalidRequest
        }
        return value
    }

    static func hostFilesystemPath(_ value: BighelpJSONValue?) throws -> String {
        let path = try text(value, maximumBytes: 4_096)
        guard !path.isEmpty,
              Data(path.utf8) == Data(path.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HostOperationsError.invalidResponse
        }
        return path
    }

    static func isConfigPath(_ configPath: String, insideProfileHome home: String) -> Bool {
        let separator = home.hasSuffix("/") || home.hasSuffix("\\") ? "" : "/"
        let posix = home + separator + "config.yaml"
        if Data(configPath.utf8) == Data(posix.utf8) { return true }
        guard separator == "/" else { return false }
        return Data(configPath.utf8) == Data((home + "\\config.yaml").utf8)
    }

    static func uploadFilename(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 255,
              value.lowercased().hasSuffix(".zip"), value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HostOperationsError.invalidRequest
        }
        return value
    }

    static func capacity(
        _ value: BighelpJSONValue?,
        availableKey: String
    ) throws -> HermesSystemStats.Capacity? {
        guard let value, value != .null else { return nil }
        let row = try object(value)
        return .init(
            total: try integer(row["total"], range: 0...Int.max),
            used: try integer(row["used"], range: 0...Int.max),
            available: try integer(row[availableKey], range: 0...Int.max),
            percent: try number(row["percent"], range: 0...100)
        )
    }

    static func process(_ value: BighelpJSONValue?) throws -> HermesSystemStats.Process? {
        guard let value, value != .null else { return nil }
        let row = try object(value)
        return .init(
            residentBytes: try integer(row["rss"], range: 0...Int.max),
            threadCount: try integer(row["num_threads"], range: 0...1_000_000),
            createdAt: date(try optionalInteger(row["create_time"], range: 0...Int.max))
        )
    }

    static func updateSummary(_ value: BighelpJSONValue) throws -> HermesUpdateReceiptSummary {
        let row = try object(value)
        return .init(
            outcome: try text(row["outcome"], maximumBytes: 32),
            startedAt: date(try optionalText(row["started_at"], maximumBytes: 128)),
            finishedAt: date(try optionalText(row["finished_at"], maximumBytes: 128)),
            preUpdateSHA: try optionalSHA(row["pre_sha"]),
            postUpdateSHA: try optionalSHA(row["post_sha"]),
            postUpdateVersion: try optionalText(row["post_version"], maximumBytes: 128),
            fleetStates: try strings(row["fleet_states"], maximum: 32, maximumBytes: 64)
        )
    }

    static func updateReceipt(_ value: BighelpJSONValue) throws -> HermesUpdateReceipt {
        let envelope = try object(value)
        let receipt = try object(envelope["receipt"] ?? .null)
        let summary = try updateSummary(envelope["summary"] ?? .null)
        let schema = try integer(receipt["schema"], range: 1...1)
        let steps = try array(receipt["steps"], maximum: 500).enumerated().map { index, value in
            let row = try object(value)
            return HermesUpdateReceipt.Step(
                index: index,
                name: try text(row["name"], maximumBytes: 256),
                succeeded: try boolean(row["ok"]),
                occurredAt: date(try optionalText(row["at"], maximumBytes: 128))
            )
        }
        let skips = try array(receipt["skips"], maximum: 500).enumerated().map { index, value in
            let row = try object(value)
            return HermesUpdateReceipt.Skip(
                index: index,
                name: try text(row["name"], maximumBytes: 256),
                occurredAt: date(try optionalText(row["at"], maximumBytes: 128))
            )
        }
        let fleet = try array(receipt["fleet"], maximum: 128).map { value in
            let row = try object(value)
            return HermesUpdateReceipt.FleetMember(
                profile: try safeIdentifier(try text(row["profile"], maximumBytes: 128), maximumBytes: 128),
                codeSHA: try optionalSHA(row["code_sha"]),
                codeVersion: try optionalText(row["code_version"], maximumBytes: 128),
                state: try text(row["state"], maximumBytes: 64)
            )
        }
        let gateway = try object(receipt["gateway_restart"] ?? .object([:]))
        let incomplete: Bool?
        if gateway.isEmpty { incomplete = nil }
        else { incomplete = gateway["incomplete"]?.boolean }
        return .init(
            schema: schema, summary: summary, steps: steps, skips: skips,
            fleet: fleet, gatewayRestartIncomplete: incomplete
        )
    }

    static func sha(_ value: BighelpJSONValue?) throws -> String {
        guard let sha = try optionalSHA(value) else { throw HostOperationsError.invalidResponse }
        return sha
    }

    static func optionalSHA(_ value: BighelpJSONValue?) throws -> String? {
        guard let value = try optionalText(value, maximumBytes: 64) else { return nil }
        guard (7...64).contains(value.utf8.count),
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
              }) else { throw HostOperationsError.invalidResponse }
        return value
    }

    static func optionalHTTPSURL(_ value: BighelpJSONValue?) throws -> URL? {
        guard let value = try optionalText(value, maximumBytes: 4_096), !value.isEmpty else { return nil }
        guard let parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "https", parts.user == nil,
              parts.password == nil, parts.host?.isEmpty == false,
              let url = parts.url else { throw HostOperationsError.invalidResponse }
        return url
    }

    static func downloadFilename(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 255,
              value.lowercased().hasSuffix(".zip"),
              value != ".", value != "..", !value.contains("/"), !value.contains("\\"),
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
              }) else { throw HostOperationsError.invalidResponse }
        return value
    }

    static func hasZIPSignature(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let signature = Array(data.prefix(4))
        return signature == [0x50, 0x4b, 0x03, 0x04]
            || signature == [0x50, 0x4b, 0x05, 0x06]
            || signature == [0x50, 0x4b, 0x07, 0x08]
    }

    static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func date(_ unixSeconds: Int?) -> Date? {
        unixSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

extension DirectHermesHostPayload {
    static func canonicalBytes(_ value: BighelpJSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
