@preconcurrency import CoreLocation
import Foundation
import WeatherKit

enum DashboardEventIntentPolicy {
    static let intentionalUserSurfaceTypes = ["channel.message"]
    static let notificationSurfaceTypes: Set<String> = [
        "channel.message", "attention.required", "approval.required",
    ]
    static let completedLifecycleTypes: Set<String> = [
        "delegation.completed", "job.completed", "session.completed",
    ]
    static let supportedEventTypes: Set<String> = [
        "approval.required", "attention.required", "channel.message",
        "delegation.completed", "delegation.started", "delegation.updated",
        "job.completed", "job.failed", "session.completed", "session.failed",
        "task.updated",
    ]

    static func isIntentionalUserSurface(
        eventType: String,
        message: String?
    ) -> Bool {
        guard intentionalUserSurfaceTypes.contains(eventType) else { return false }
        let message = message?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return !operationalNoisePrefixes.contains(where: message.hasPrefix)
    }

    static func isNotificationSurface(
        eventType: String,
        message: String?
    ) -> Bool {
        guard notificationSurfaceTypes.contains(eventType) else { return false }
        if eventType != "channel.message" { return true }
        return isIntentionalUserSurface(eventType: eventType, message: message)
    }

    static func isCompletedLifecycle(_ eventType: String) -> Bool {
        completedLifecycleTypes.contains(eventType)
    }

    private static let operationalNoisePrefixes = [
        "♻️ Gateway online", "♻ Gateway online",
        "♻️ Gateway restarted", "♻ Gateway restarted",
        "⚠️ Gateway restarting", "⚠ Gateway restarting",
        "⚠️ Gateway shutting down", "⚠ Gateway shutting down",
    ]
}

struct DashboardSnapshot: Equatable, Sendable {
    let weather: DashboardWeather?
    let inbox: [DashboardInboxItem]
    let attentionItems: [DashboardAttentionItem]
    let completedItems: [DashboardCompletion]
    let agents: [DashboardAgent]
}

struct DashboardConnectionPresentation: Equatable, Sendable {
    let title: String
    let systemImage: String
    let isConnected: Bool

    init(linkState: BighelpAppReadinessLinkState) {
        self.init(isConnected: linkState == .verified)
    }

    init(isConnected: Bool) {
        if isConnected {
            title = "Connected"
            systemImage = "checkmark.circle.fill"
            self.isConnected = true
        } else {
            title = "Reconnecting"
            systemImage = "exclamationmark.circle.fill"
            self.isConnected = false
        }
    }
}

enum DashboardWeatherFreshness: Equatable, Sendable {
    case fresh
    case stale

    var label: String {
        switch self {
        case .fresh: "Current"
        case .stale: "May be stale"
        }
    }
}

enum DashboardWeatherLoadingState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case unavailable
}

struct DashboardWeather: Equatable, Sendable {
    let cardID: String?
    let city: String
    let condition: String
    let temperature: Int
    let high: Int
    let low: Int
    let systemImage: String
    let sourceName: String?
    let sourceTimestamp: Date?
    let freshness: DashboardWeatherFreshness
    let attribution: DashboardWeatherAttribution?

    init(
        cardID: String? = nil,
        city: String,
        condition: String,
        temperature: Int,
        high: Int,
        low: Int,
        systemImage: String,
        sourceName: String? = nil,
        sourceTimestamp: Date? = nil,
        freshness: DashboardWeatherFreshness = .fresh,
        attribution: DashboardWeatherAttribution? = nil
    ) {
        self.cardID = cardID
        self.city = city
        self.condition = condition
        self.temperature = temperature
        self.high = high
        self.low = low
        self.systemImage = systemImage
        self.sourceName = sourceName
        self.sourceTimestamp = sourceTimestamp
        self.freshness = freshness
        self.attribution = attribution
    }
}

struct DashboardWeatherAttribution: Equatable, Sendable {
    let serviceName: String
    let legalPageURL: URL
    let combinedMarkLightURL: URL
    let combinedMarkDarkURL: URL
}

enum DashboardWeatherProjection {
    static let freshInterval: TimeInterval = 2 * 60 * 60
    static let maximumAge: TimeInterval = 6 * 60 * 60
    static let maximumFutureSkew: TimeInterval = 5 * 60

    static func project(
        from inbox: [DashboardInboxItem],
        now: Date
    ) -> DashboardWeather? {
        var seenCardIDs = Set<String>()
        return inbox.compactMap { item -> Candidate? in
            guard let card = item.card, seenCardIDs.insert(card.id).inserted else {
                return nil
            }
            return candidate(card: card, now: now)
        }
        .max { left, right in
            if left.sourceTimestamp == right.sourceTimestamp {
                return left.weather.cardID ?? "" < right.weather.cardID ?? ""
            }
            return left.sourceTimestamp < right.sourceTimestamp
        }?
        .weather
    }

    private struct Candidate {
        let weather: DashboardWeather
        let sourceTimestamp: Date
    }

    private static func candidate(
        card: GenerativeUICard,
        now: Date
    ) -> Candidate? {
        guard
            card.version == 2,
            card.component == .weatherForecast,
            let provenance = card.provenance,
            let sourceName = normalized(provenance["source_name"]?.string),
            let sourceTimestamp = date(provenance["source_timestamp"]?.string),
            let city = normalized(card.data["location"]?.string),
            let current = card.data["current"]?.object,
            let condition = normalized(current["condition_label"]?.string),
            let conditionCode = current["condition_code"]?.string,
            let temperature = integer(current["temperature"]?.number)
        else { return nil }

        let age = now.timeIntervalSince(sourceTimestamp)
        guard age >= -maximumFutureSkew, age <= maximumAge else { return nil }
        if let rawValidUntil = provenance["valid_until"] {
            guard
                let validUntil = date(rawValidUntil.string),
                validUntil >= sourceTimestamp,
                now < validUntil
            else { return nil }
        }

        let periods = card.data["periods"]?.array?.compactMap(\.object) ?? []
        let highs = periods.compactMap { integer($0["high"]?.number) }
        let lows = periods.compactMap { integer($0["low"]?.number) }
        let high = highs.max() ?? temperature
        let low = lows.min() ?? temperature
        let weather = DashboardWeather(
            cardID: card.id,
            city: city,
            condition: condition,
            temperature: temperature,
            high: high,
            low: low,
            systemImage: systemImage(conditionCode),
            sourceName: sourceName,
            sourceTimestamp: sourceTimestamp,
            freshness: age <= freshInterval ? .fresh : .stale
        )
        return Candidate(weather: weather, sourceTimestamp: sourceTimestamp)
    }

    private static func normalized(_ value: String?) -> String? {
        let normalized = value?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func integer(_ value: Double?) -> Int? {
        guard let value, value.isFinite, (-200...200).contains(value) else { return nil }
        return Int(value.rounded())
    }

    private static func systemImage(_ code: String) -> String {
        switch code {
        case "clear": "sun.max.fill"
        case "partly_cloudy": "cloud.sun.fill"
        case "cloudy": "cloud.fill"
        case "rain": "cloud.rain.fill"
        case "snow": "cloud.snow.fill"
        case "sleet": "cloud.sleet.fill"
        case "storm": "cloud.bolt.rain.fill"
        case "fog", "smoke": "cloud.fog.fill"
        case "wind": "wind"
        default: "cloud.fill"
        }
    }
}

struct DashboardInboxItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let agentName: String
    let status: String
    let card: GenerativeUICard?
    let bighelpCard: BighelpCardDocument?
    let sessionID: String?
    let agentID: String?
    let isRead: Bool
    let isPinned: Bool
    let isSessionClosed: Bool
    let createdAt: Date

    init(
        id: String,
        title: String,
        detail: String,
        agentName: String,
        status: String,
        card: GenerativeUICard? = nil,
        bighelpCard: BighelpCardDocument? = nil,
        sessionID: String? = nil,
        agentID: String? = nil,
        isRead: Bool = false,
        isPinned: Bool = false,
        isSessionClosed: Bool = false,
        createdAt: Date = .distantPast
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.agentName = agentName
        self.status = status
        self.card = card
        self.bighelpCard = bighelpCard
        self.sessionID = sessionID
        self.agentID = agentID
        self.isRead = isRead
        self.isPinned = isPinned
        self.isSessionClosed = isSessionClosed
        self.createdAt = createdAt
    }

    var cardEnvelope: BighelpCardEnvelope? {
        if let bighelpCard { return .card(bighelpCard) }
        if let card { return .legacy(card) }
        return nil
    }

    var cardImportance: BighelpCardImportance {
        bighelpCard?.importance ?? .normal
    }

    func withState(isRead: Bool, isPinned: Bool) -> DashboardInboxItem {
        DashboardInboxItem(
            id: id,
            title: title,
            detail: detail,
            agentName: agentName,
            status: status,
            card: card,
            bighelpCard: bighelpCard,
            sessionID: sessionID,
            agentID: agentID,
            isRead: isRead,
            isPinned: isPinned,
            isSessionClosed: isSessionClosed,
            createdAt: createdAt
        )
    }
}

struct DashboardClarificationQuestion: Equatable, Sendable, Identifiable {
    let id: String
    let question: String
    let choices: [String]
    let allowsCustomResponse: Bool
    let isMultiSelect: Bool
    let lockedAnswer: String?

    init(
        id: String,
        question: String,
        choices: [String] = [],
        allowsCustomResponse: Bool = true,
        isMultiSelect: Bool = false,
        lockedAnswer: String? = nil
    ) {
        self.id = id
        self.question = question
        self.choices = choices
        self.allowsCustomResponse = allowsCustomResponse
        self.isMultiSelect = isMultiSelect
        self.lockedAnswer = lockedAnswer
    }
}

struct DashboardClarificationAnswer: Equatable, Sendable {
    let questionID: String
    let value: String
}

struct DashboardClarificationResponse: Equatable, Sendable {
    let answers: [DashboardClarificationAnswer]

    func answer(for questionID: String) -> String? {
        let identity = Data(questionID.utf8)
        let matches = answers.filter { Data($0.questionID.utf8) == identity }
        return matches.count == 1 ? matches[0].value : nil
    }

    var singleAnswer: String? {
        answers.count == 1 ? answers[0].value : nil
    }
}

struct DashboardClarificationRequest: Equatable, Sendable {
    let eventID: String
    let requestID: String
    let sessionID: String
    let questions: [DashboardClarificationQuestion]
    let expiresAt: Date?

    init(
        eventID: String,
        requestID: String,
        sessionID: String,
        question: String,
        choices: [String],
        allowsCustomResponse: Bool,
        isMultiSelect: Bool,
        expiresAt: Date?
    ) {
        self.init(
            eventID: eventID,
            requestID: requestID,
            sessionID: sessionID,
            questions: [DashboardClarificationQuestion(
                id: "q0",
                question: question,
                choices: choices,
                allowsCustomResponse: allowsCustomResponse,
                isMultiSelect: isMultiSelect
            )],
            expiresAt: expiresAt
        )
    }

    init(
        eventID: String,
        requestID: String,
        sessionID: String,
        questions: [DashboardClarificationQuestion],
        expiresAt: Date?
    ) {
        self.eventID = eventID
        self.requestID = requestID
        self.sessionID = sessionID
        self.questions = questions
        self.expiresAt = expiresAt
    }

    var question: String { questions.first?.question ?? "" }
    var choices: [String] { questions.first?.choices ?? [] }
    var allowsCustomResponse: Bool { questions.count == 1 && questions[0].allowsCustomResponse }
    var isMultiSelect: Bool { questions.count != 1 || questions[0].isMultiSelect }

    func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return date >= expiresAt
    }

    func accepts(_ response: DashboardClarificationResponse) -> Bool {
        guard !questions.isEmpty, response.answers.count == questions.count else { return false }
        var seen = Set<Data>()
        for question in questions {
            let identity = Data(question.id.utf8)
            guard seen.insert(identity).inserted,
                  let answer = response.answer(for: question.id),
                  !answer.isEmpty,
                  answer.utf8.count <= 10_000,
                  !answer.contains("\0") else { return false }
            if let locked = question.lockedAnswer,
               !answer.utf8.elementsEqual(locked.utf8) { return false }
        }
        return response.answers.allSatisfy { answer in
            questions.contains { Data($0.id.utf8) == Data(answer.questionID.utf8) }
        }
    }
}

struct DashboardClarificationReceipt: Equatable, Sendable {
    let eventID: String
    let requestID: String
}

@MainActor
protocol DashboardClarificationClient {
    func respond(
        to request: DashboardClarificationRequest,
        response: String
    ) async throws -> DashboardClarificationReceipt

    func respond(
        to request: DashboardClarificationRequest,
        response: DashboardClarificationResponse
    ) async throws -> DashboardClarificationReceipt
}

extension DashboardClarificationClient {
    func respond(
        to request: DashboardClarificationRequest,
        response: DashboardClarificationResponse
    ) async throws -> DashboardClarificationReceipt {
        guard request.questions.count == 1,
              request.accepts(response),
              let value = response.singleAnswer else {
            throw DashboardMutationError.unsupported
        }
        return try await respond(to: request, response: value)
    }
}

struct DashboardApprovalRequest: Equatable, Sendable {
    let eventID: String
    let approvalID: String
    let allowedDecisions: [ApprovalDecision]
    let expiresAt: Date

    func isExpired(at date: Date) -> Bool {
        date >= expiresAt
    }
}

enum DashboardAttentionInteraction: Equatable, Sendable {
    case none
    case clarification(DashboardClarificationRequest)
    case approval(DashboardApprovalRequest)

    var isStructuredDecision: Bool {
        switch self {
        case .none: false
        case .clarification, .approval: true
        }
    }
}


struct DashboardAttentionItem: Identifiable, Equatable, Sendable {
    enum Urgency: String, Equatable, Sendable {
        case important
        case needsReview

        var title: String {
            switch self {
            case .important: "Important"
            case .needsReview: "Needs review"
            }
        }

        var systemImage: String {
            switch self {
            case .important: "exclamationmark.triangle.fill"
            case .needsReview: "eye.fill"
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let urgency: Urgency
    let approvalID: String?
    let sessionID: String?
    let agentID: String?
    let isRead: Bool
    let isPinned: Bool
    let isSessionClosed: Bool
    let interaction: DashboardAttentionInteraction
    let createdAt: Date

    init(
        id: String,
        title: String,
        detail: String,
        urgency: Urgency,
        approvalID: String? = nil,
        sessionID: String? = nil,
        agentID: String? = nil,
        isRead: Bool = false,
        isPinned: Bool = false,
        isSessionClosed: Bool = false,
        interaction: DashboardAttentionInteraction = .none,
        createdAt: Date = .distantPast
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.urgency = urgency
        self.approvalID = approvalID
        self.sessionID = sessionID
        self.agentID = agentID
        self.isRead = isRead
        self.isPinned = isPinned
        self.isSessionClosed = isSessionClosed
        self.interaction = interaction
        self.createdAt = createdAt
    }

    var owningSessionID: String? {
        if case .clarification(let request) = interaction {
            guard sessionID == nil || sessionID == request.sessionID else { return nil }
            return request.sessionID
        }
        return sessionID
    }

    func withState(isRead: Bool, isPinned: Bool) -> DashboardAttentionItem {
        DashboardAttentionItem(
            id: id,
            title: title,
            detail: detail,
            urgency: urgency,
            approvalID: approvalID,
            sessionID: sessionID,
            agentID: agentID,
            isRead: isRead,
            isPinned: isPinned,
            isSessionClosed: isSessionClosed,
            interaction: interaction,
            createdAt: createdAt
        )
    }
}

struct DashboardCompletion: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let taskID: String?
    let jobID: String?
    let agentName: String?
    let status: String
    let completedAt: Date
    let completedLabel: String
    let sessionID: String?
    let agentID: String?
    let childSessionID: String?
    let parentSessionID: String?
    let delegationID: String?
    let turnID: String?

    init(
        id: String,
        title: String,
        detail: String,
        taskID: String? = nil,
        jobID: String? = nil,
        agentName: String? = nil,
        status: String = "completed",
        completedAt: Date = .distantPast,
        completedLabel: String,
        sessionID: String? = nil,
        agentID: String? = nil,
        childSessionID: String? = nil,
        parentSessionID: String? = nil,
        delegationID: String? = nil,
        turnID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.taskID = taskID
        self.jobID = jobID
        self.agentName = agentName
        self.status = status
        self.completedAt = completedAt
        self.completedLabel = completedLabel
        self.sessionID = sessionID
        self.agentID = agentID
        self.childSessionID = childSessionID
        self.parentSessionID = parentSessionID
        self.delegationID = delegationID
        self.turnID = turnID
    }

    func presented(title: String, sessionID: String?) -> DashboardCompletion {
        DashboardCompletion(
            id: id, title: title, detail: detail, taskID: taskID, jobID: jobID,
            agentName: agentName, status: status, completedAt: completedAt,
            completedLabel: completedLabel, sessionID: sessionID, agentID: agentID,
            childSessionID: childSessionID, parentSessionID: parentSessionID,
            delegationID: delegationID, turnID: turnID
        )
    }
}

enum DashboardCompletionProjection {
    static func make(
        id: String,
        eventType: String,
        detail: [String: String],
        agentName: String,
        createdAt: Date,
        completedLabel: String,
        fallbackTitle: String,
        fallbackDetail: String,
        sessionID: String? = nil,
        agentID: String? = nil
    ) -> DashboardCompletion {
        let copy = eventType == "job.completed"
            ? jobCopy(detail: detail)
            : (
                DashboardWorkProjection.meaningfulTitle(detail["title"])
                    ?? (eventType == "delegation.completed" ? "Subagent task" : "Conversation"),
                fallbackDetail
            )
        return DashboardCompletion(
            id: id,
            title: copy.0,
            detail: copy.1,
            taskID: normalized(detail["task_id"], maximum: 180),
            jobID: normalized(detail["job_id"], maximum: 180),
            agentName: agentName,
            status: eventType,
            completedAt: createdAt,
            completedLabel: completedLabel,
            sessionID: sessionID,
            agentID: agentID,
            childSessionID: coordinate(detail["child_session_id"]),
            parentSessionID: coordinate(detail["parent_session_id"]),
            delegationID: coordinate(detail["delegation_id"]),
            turnID: coordinate(detail["turn_id"])
        )
    }

    private static func coordinate(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 180,
              !value.contains("\0"), !value.contains(where: \.isWhitespace)
        else { return nil }
        return value
    }

    private static func jobCopy(detail: [String: String]) -> (String, String) {
        let title = ["task_name", "task_title", "job_title"]
            .compactMap { normalized(detail[$0], maximum: 160) }
            .first
            ?? distinctJobTitle(detail["title"])
            ?? "Scheduled task"
        let result = ["summary", "message", "result", "detail", "description"]
            .compactMap { normalized(detail[$0], maximum: 240) }
            .first { $0 != title }
            ?? "No result details were provided."
        return (title, result)
    }

    private static func distinctJobTitle(_ value: String?) -> String? {
        guard let value = normalized(value, maximum: 160) else { return nil }
        return ["Scheduled task completed", "Job completed"].contains(value) ? nil : value
    }

    private static func normalized(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : String(normalized.prefix(maximum))
    }
}

struct DashboardAgent: Identifiable, Equatable, Sendable {
    let id: String
    let initials: String
    let name: String
    let role: String
    let availability: String
}

@MainActor
protocol DashboardDataSource {
    func loadDashboard() async throws -> DashboardSnapshot
    func setDashboardEventState(id: String, isRead: Bool, isPinned: Bool) async throws
    func dismissDashboardEvent(id: String) async throws
    func dismissDashboardEvents(types: [String], createdBefore: Date) async throws
}

enum DashboardMutationError: Error {
    case unsupported
}

extension DashboardDataSource {
    func setDashboardEventState(id: String, isRead: Bool, isPinned: Bool) async throws {
        throw DashboardMutationError.unsupported
    }

    func dismissDashboardEvent(id: String) async throws {
        throw DashboardMutationError.unsupported
    }

    func dismissDashboardEvents(types: [String], createdBefore: Date) async throws {
        throw DashboardMutationError.unsupported
    }
}

@MainActor
protocol DashboardWeatherLoading {
    func loadCurrentWeather() async throws -> DashboardWeather?
}

@MainActor
final class AppleDashboardWeatherLoader: DashboardWeatherLoading {
    private let location: DashboardWeatherLocationClient
    private let service: WeatherService
    private let locale: Locale
    private let now: () -> Date

    init(
        location: DashboardWeatherLocationClient = DashboardWeatherLocationClient(),
        service: WeatherService = .shared,
        locale: Locale = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.location = location
        self.service = service
        self.locale = locale
        self.now = now
    }

    func loadCurrentWeather() async throws -> DashboardWeather? {
        guard let coordinate = try await location.currentAuthorizedLocation() else {
            return nil
        }

        async let placeName = Self.placeName(for: coordinate, locale: locale)
        async let attribution = service.attribution
        let (current, daily) = try await service.weather(
            for: coordinate,
            including: .current,
            .daily
        )
        guard let today = daily.first else { return nil }
        let source = try await attribution
        let age = max(0, now().timeIntervalSince(current.date))
        let unit: UnitTemperature = locale.measurementSystem == .us
            ? .fahrenheit
            : .celsius

        return DashboardWeather(
            city: await placeName,
            condition: current.condition.description,
            temperature: Self.rounded(current.temperature, unit: unit),
            high: Self.rounded(today.highTemperature, unit: unit),
            low: Self.rounded(today.lowTemperature, unit: unit),
            systemImage: current.symbolName,
            sourceName: source.serviceName,
            sourceTimestamp: current.date,
            freshness: age <= DashboardWeatherProjection.freshInterval ? .fresh : .stale,
            attribution: DashboardWeatherAttribution(
                serviceName: source.serviceName,
                legalPageURL: source.legalPageURL,
                combinedMarkLightURL: source.combinedMarkLightURL,
                combinedMarkDarkURL: source.combinedMarkDarkURL
            )
        )
    }

    private static func rounded(
        _ value: Measurement<UnitTemperature>,
        unit: UnitTemperature
    ) -> Int {
        Int(value.converted(to: unit).value.rounded())
    }

    private static func placeName(for location: CLLocation, locale: Locale) async -> String {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            location,
            preferredLocale: locale
        )
        guard let placemark = placemarks?.first else { return "Your location" }
        let locality = placemark.locality ?? placemark.subAdministrativeArea
        let region = placemark.administrativeArea
        switch (locality, region) {
        case let (.some(locality), .some(region)) where locality != region:
            return "\(locality), \(region)"
        case let (.some(locality), _):
            return locality
        case let (_, .some(region)):
            return region
        default:
            return "Your location"
        }
    }
}

@MainActor
final class DashboardWeatherLocationRequestPool<Value: Sendable> {
    private var continuations: [UUID: CheckedContinuation<Value, any Error>] = [:]

    var pendingCount: Int { continuations.count }

    func value(start: @MainActor () -> Void) async throws -> Value {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let shouldStart = continuations.isEmpty
                continuations[requestID] = continuation
                if shouldStart { start() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID)
            }
        }
    }

    func finish(returning value: Value) {
        let pending = continuations.values
        continuations.removeAll()
        pending.forEach { $0.resume(returning: value) }
    }

    func finish(throwing error: any Error) {
        let pending = continuations.values
        continuations.removeAll()
        pending.forEach { $0.resume(throwing: error) }
    }

    private func cancel(_ requestID: UUID) {
        continuations.removeValue(forKey: requestID)?.resume(
            throwing: CancellationError()
        )
    }
}

@MainActor
final class DashboardWeatherLocationClient: NSObject, @preconcurrency CLLocationManagerDelegate {
    private enum LocationError: Error {
        case unavailable
    }

    private let manager: CLLocationManager
    private let requests = DashboardWeatherLocationRequestPool<CLLocation?>()

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func currentAuthorizedLocation() async throws -> CLLocation? {
        let servicesEnabled = await Task.detached {
            CLLocationManager.locationServicesEnabled()
        }.value
        guard servicesEnabled else { return nil }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        case .notDetermined, .restricted, .denied:
            return nil
        @unknown default:
            return nil
        }

        return try await requests.value {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) else {
            finish(throwing: LocationError.unavailable)
            return
        }
        finish(returning: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        finish(throwing: error)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard requests.pendingCount > 0 else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse, .notDetermined:
            break
        case .restricted, .denied:
            finish(returning: nil)
        @unknown default:
            finish(returning: nil)
        }
    }

    private func finish(returning location: CLLocation?) {
        requests.finish(returning: location)
    }

    private func finish(throwing error: any Error) {
        requests.finish(throwing: error)
    }
}

enum DashboardLoadingState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failure(message: String)
}
