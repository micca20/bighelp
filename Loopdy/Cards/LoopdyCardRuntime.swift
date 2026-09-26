import Foundation
import Observation

/// Dormant live-source contract retained for compatibility tests. Shipping card
/// views use only validated static documents and never construct this runtime.
@MainActor
@Observable
final class LoopdyCardRuntime {
    enum State: Equatable {
        case idle
        case loading
        case updated(Date)
        case stale
        case expired
        case unavailable(String)
    }

    enum SourceState: Equatable {
        case idle
        case loading
        case updated(Date)
        case stale(Date)
        case expired
        case unavailable(String)
    }

    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias Now = @Sendable () -> Date

    private struct Source: Sendable {
        let id: String
        let url: URL
        let responseRoot: String
        let minimumInterval: Int
        let staleAfter: Int
        let expiresAt: Date
    }

    private(set) var state: State = .idle
    private(set) var sourceStates: [String: SourceState] = [:]
    private(set) var values: [String: LoopdyJSONValue] = [:]

    private let client: any LoopdyCardDataFetching
    private let sources: [String: Source]
    private let sleep: Sleep
    private let now: Now
    private var tasks: [String: Task<Void, Never>] = [:]
    private var isVisible = false
    private var isSceneActive = true

    init(
        document: LoopdyCardDocument,
        client: any LoopdyCardDataFetching = LoopdyCardStaticDataClient(),
        now: @escaping Now = Date.init,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.now = now
        self.sleep = sleep
        let parsedSources: [String: Source] = Dictionary(
            uniqueKeysWithValues: document.dataSources.compactMap { rawSource -> (String, Source)? in
            guard let source = rawSource.object,
                  let id = source["id"]?.string,
                  let request = source["request"]?.object,
                  let rawURL = request["url"]?.string,
                  let url = URL(string: rawURL),
                  let response = source["response"]?.object,
                  let root = response["root"]?.string,
                  let refresh = source["refresh"]?.object,
                  let minimum = refresh["minimum_interval_seconds"]?.integer,
                  let stale = refresh["stale_after_seconds"]?.integer,
                  let rawExpiry = refresh["expires_at"]?.string,
                  let expiry = ISO8601DateFormatter().date(from: rawExpiry) else {
                return nil
            }
            return (id, Source(
                id: id,
                url: url,
                responseRoot: root,
                minimumInterval: minimum,
                staleAfter: stale,
                expiresAt: expiry
            ))
        })
        self.sources = parsedSources
        self.sourceStates = Dictionary<String, SourceState>(
            uniqueKeysWithValues: parsedSources.keys.map { ($0, SourceState.idle) }
        )
    }

    func start() {
        isVisible = true
        resumeIfAllowed()
    }

    func stop() {
        isVisible = false
        suspend()
    }

    func setSceneActive(_ active: Bool) {
        isSceneActive = active
        if active {
            resumeIfAllowed()
        } else {
            suspend()
        }
    }

    func retry(sourceID: String) {
        guard sources[sourceID] != nil, isVisible, isSceneActive else { return }
        tasks[sourceID]?.cancel()
        tasks[sourceID] = makeTask(for: sourceID, repeats: true)
    }

    func refresh(sourceID: String) async {
        guard let source = sources[sourceID] else { return }
        let currentDate = now()
        guard currentDate < source.expiresAt else {
            sourceStates[sourceID] = .expired
            updateAggregateState()
            return
        }

        if values[sourceID] == nil {
            sourceStates[sourceID] = .loading
            updateAggregateState()
        }
        do {
            let response = try await client.fetch(source.url)
            try Task.checkCancellation()
            let value: LoopdyJSONValue
            if source.responseRoot.isEmpty {
                value = response
            } else if let resolved = LoopdyCardValueResolver.pointer(source.responseRoot, in: response) {
                value = resolved
            } else {
                throw LoopdyCardRuntimeError.responseRootUnavailable
            }
            values[sourceID] = value
            let updateDate = now()
            sourceStates[sourceID] = .updated(updateDate)
        } catch is CancellationError {
            return
        } catch {
            if values[sourceID] != nil {
                let lastUpdate: Date
                switch sourceStates[sourceID] {
                case .updated(let date), .stale(let date): lastUpdate = date
                default: lastUpdate = now()
                }
                if now().timeIntervalSince(lastUpdate) >= TimeInterval(source.staleAfter) {
                    sourceStates[sourceID] = .stale(lastUpdate)
                } else {
                    sourceStates[sourceID] = .updated(lastUpdate)
                }
            } else {
                sourceStates[sourceID] = .unavailable(error.localizedDescription)
            }
        }
        updateAggregateState()
    }

    private func resumeIfAllowed() {
        guard isVisible, isSceneActive else { return }
        if sources.isEmpty {
            state = .updated(now())
            return
        }
        for id in sources.keys where tasks[id] == nil {
            tasks[id] = makeTask(for: id, repeats: true)
        }
    }

    private func suspend() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func makeTask(for sourceID: String, repeats: Bool) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self, let source = self.sources[sourceID] else { return }
            repeat {
                await self.refresh(sourceID: sourceID)
                if Task.isCancelled || !repeats { break }
                do {
                    try await self.sleep(.seconds(source.minimumInterval))
                } catch {
                    break
                }
            } while !Task.isCancelled
            self.tasks[sourceID] = nil
        }
    }

    private func updateAggregateState() {
        let states = Array(sourceStates.values)
        if states.allSatisfy({ if case .expired = $0 { true } else { false } }) {
            state = .expired
        } else if states.contains(where: { if case .loading = $0 { true } else { false } }) {
            state = .loading
        } else if states.contains(where: { if case .stale = $0 { true } else { false } }) {
            state = .stale
        } else if let latest = states.compactMap({ sourceState -> Date? in
            guard case .updated(let date) = sourceState else { return nil }
            return date
        }).max() {
            state = .updated(latest)
        } else if let error = states.compactMap({ sourceState -> String? in
            guard case .unavailable(let reason) = sourceState else { return nil }
            return reason
        }).first {
            state = .unavailable(error)
        } else {
            state = .idle
        }
    }
}

enum LoopdyCardRuntimeError: Error {
    case responseRootUnavailable
}
