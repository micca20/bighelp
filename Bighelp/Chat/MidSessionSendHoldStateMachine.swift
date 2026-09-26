import Foundation

struct MidSessionSendHoldStateMachine {
    enum Output: Equatable {
        case presentOptions
        case sendDefault
    }

    private enum State {
        case idle
        case tracking(start: TimeInterval)
        case optionsPresented
        case cancelled
    }

    static let threshold: TimeInterval = 3.0
    static let maximumDistance: Double = 50
    static let deliberateHoldMinimum: TimeInterval = 0.5

    private(set) var isOptionsPresented = false
    private var state: State = .idle

    mutating func begin(at time: TimeInterval) -> [Output] {
        isOptionsPresented = false
        state = .tracking(start: time)
        return []
    }

    mutating func move(distance: Double) -> [Output] {
        guard case .tracking = state, distance > Self.maximumDistance else { return [] }
        state = .cancelled
        return []
    }

    mutating func advance(to time: TimeInterval) -> [Output] {
        guard case let .tracking(start) = state,
              time - start >= Self.threshold else { return [] }
        state = .optionsPresented
        isOptionsPresented = true
        return [.presentOptions]
    }

    mutating func end(at time: TimeInterval) -> [Output] {
        defer {
            state = .idle
            isOptionsPresented = false
        }

        switch state {
        case .optionsPresented, .cancelled, .idle:
            return []
        case let .tracking(start):
            return time - start < Self.deliberateHoldMinimum ? [.sendDefault] : []
        }
    }
}
