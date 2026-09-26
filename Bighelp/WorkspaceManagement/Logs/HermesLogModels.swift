import Foundation

enum HermesLogFile: String, CaseIterable, Identifiable, Sendable {
    case agent, errors, gateway, gui, desktop, mcp

    var id: Self { self }

    var title: String {
        switch self {
        case .agent: "Agent"
        case .errors: "Errors"
        case .gateway: "Gateway"
        case .gui: "Dashboard"
        case .desktop: "Desktop"
        case .mcp: "MCP"
        }
    }
}

enum HermesLogSeverity: String, CaseIterable, Identifiable, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    case critical = "CRITICAL"
    case unclassified = "LOG"

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .debug: "ladybug"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        case .critical: "exclamationmark.octagon.fill"
        case .unclassified: "doc.text"
        }
    }
}

enum HermesLogLevelFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "ALL"
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    case critical = "CRITICAL"

    var id: Self { self }
    var title: String { self == .all ? "All levels" : "\(rawValue.capitalized) and higher" }
    var queryValue: String? { self == .all ? nil : rawValue }
}

enum HermesLogComponent: String, CaseIterable, Identifiable, Sendable {
    case all, gateway, agent, tools, cli, cron, gui

    var id: Self { self }
    var title: String { self == .all ? "All components" : rawValue.capitalized }
    var queryValue: String? { self == .all ? nil : rawValue }
}

struct HermesLogQuery: Equatable, Sendable {
    static let initialLineLimit = 100
    static let lineStep = 100
    static let maximumLineLimit = 500
    static let maximumSearchBytes = 200

    let file: HermesLogFile
    let lineLimit: Int
    let level: HermesLogLevelFilter
    let component: HermesLogComponent
    let search: String?

    init(
        file: HermesLogFile = .agent,
        lineLimit: Int = initialLineLimit,
        level: HermesLogLevelFilter = .all,
        component: HermesLogComponent = .all,
        search: String? = nil
    ) throws {
        guard (1...Self.maximumLineLimit).contains(lineLimit) else {
            throw HermesLogsClientError.invalidRequest
        }
        let normalized = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            guard normalized.utf8.count <= Self.maximumSearchBytes,
                  !normalized.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
                throw HermesLogsClientError.invalidRequest
            }
            self.search = normalized
        } else {
            self.search = nil
        }
        self.file = file
        self.lineLimit = lineLimit
        self.level = level
        self.component = component
    }
}

struct HermesLogEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let timestamp: Date?
    let timestampText: String?
    let severity: HermesLogSeverity
    let logger: String?
    let message: String
}

struct HermesLogPage: Equatable, Sendable {
    let query: HermesLogQuery
    let entries: [HermesLogEntry]

    var canLoadEarlier: Bool {
        entries.count == query.lineLimit && query.lineLimit < HermesLogQuery.maximumLineLimit
    }
}

enum HermesLogsClientError: Error, Equatable, LocalizedError {
    case unsupported
    case invalidRequest
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "This Hermes host does not expose its authenticated bounded Logs endpoint."
        case .invalidRequest:
            "Choose a supported filter. Search text is limited to 200 UTF-8 bytes and cannot contain control characters."
        case .invalidResponse:
            "Hermes returned an invalid Logs response. No log content was retained."
        }
    }
}

@MainActor
protocol HermesLogsReading: AnyObject {
    var owner: WorkspaceOwner? { get }
    func read(_ query: HermesLogQuery) async throws -> HermesLogPage
}
