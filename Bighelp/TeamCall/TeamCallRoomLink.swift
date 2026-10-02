import Foundation

/// A message in the room, as the call sees it.
struct TeamCallRoomEvent: Equatable, Sendable {
    let id: String
    /// Nil for a person's message.
    let memberID: String?
    let text: String
}

/// The group chat behind a call: what's been said, and a way to say more.
@MainActor
protocol TeamCallRoomLink: AnyObject {
    var events: [TeamCallRoomEvent] { get }
    /// Members are still answering.
    var isWorking: Bool { get }
    /// Posts to the room exactly like typing. Returns once Hermes has the
    /// message (and, for hosted rooms, once the round settles).
    func send(_ text: String) async throws
    func observe(_ onChange: @escaping @MainActor () -> Void)
    func stopObserving()
}

/// The production link: the room store's own send path (the same idempotent
/// one the composer uses) and its room observers.
@MainActor
final class BotModeTeamCallRoomLink: TeamCallRoomLink {
    private let store: BotModeRoomStore
    private let roomID: String
    private let senderSnapshot: @MainActor () -> TimelineSenderSnapshot?
    private let activitySink: ((BotModeRunActivity) -> Void)?
    private var observation: UUID?
    private var onChange: (@MainActor () -> Void)?

    init(
        store: BotModeRoomStore,
        roomID: String,
        senderSnapshot: @escaping @MainActor () -> TimelineSenderSnapshot?,
        activitySink: ((BotModeRunActivity) -> Void)? = nil
    ) {
        self.store = store
        self.roomID = roomID
        self.senderSnapshot = senderSnapshot
        self.activitySink = activitySink
    }

    var events: [TeamCallRoomEvent] {
        (store.room(id: roomID)?.visibleEvents ?? []).compactMap { event in
            guard let text = event.text else { return nil }
            switch event.kind {
            case .human: return TeamCallRoomEvent(id: event.id, memberID: nil, text: text)
            case .agent: return event.memberID.map { TeamCallRoomEvent(id: event.id, memberID: $0, text: text) }
            case .botModeStarted: return nil
            }
        }
    }

    var isWorking: Bool { store.nativeRoomIsWorking(roomID: roomID) }

    func send(_ text: String) async throws {
        // The store's own watcher stands down while a send owns the room;
        // pick it back up so later messages still reach the call.
        defer {
            if onChange != nil, store.room(id: roomID)?.hasNativeRoom == true {
                store.beginNativeRoomObservation(roomID: roomID)
            }
        }
        do {
            try await store.send(text: text, roomID: roomID, senderSnapshot: senderSnapshot(),
                                 activitySink: activitySink)
        } catch BotModeRoomError.nativeTurnTimedOut {
            // A quiet poll isn't a failed turn: Hermes has the message.
        }
    }

    func observe(_ onChange: @escaping @MainActor () -> Void) {
        stopObserving()
        self.onChange = onChange
        if store.room(id: roomID)?.hasNativeRoom == true {
            store.beginNativeRoomObservation(roomID: roomID)
        }
        observation = store.observeRoom(id: roomID, owner: self) { link in
            link.onChange?()
        }
    }

    func stopObserving() {
        if let observation { store.removeRoomObserver(observation) }
        observation = nil
        onChange = nil
    }
}
