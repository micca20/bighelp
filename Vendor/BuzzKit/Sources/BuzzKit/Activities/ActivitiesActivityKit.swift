#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

/// ActivityKit can deadlock when several threads read push tokens or open token/state
/// streams while it delivers a token (seen as a main-thread watchdog kill with four
/// threads inside ActivityKit). Every such call from BuzzKit and the host app goes
/// through this one serial lane, off the main thread, one at a time.
public enum ActivityKitSerialAccess {
    private static let queue = DispatchQueue(label: "dev.buzzkit.activitykit-access", qos: .userInitiated)

    /// Runs a short ActivityKit read (a token, a sequence, an iterator) on the serial lane.
    public static func read<T>(_ body: @escaping @Sendable () -> T) async -> T {
        let work = UncheckedSendableBox(body)
        let result: UncheckedSendableBox<T> = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: UncheckedSendableBox(work.value())) }
        }
        return result.value
    }

    /// Opens an ActivityKit sequence and its iterator on the serial lane. Waiting for the
    /// next element happens on the caller's task; only setup touches ActivityKit's locks.
    public static func iterate<S: AsyncSequence>(_ sequence: @escaping @Sendable () -> S) async -> SerialIterator<S.Element> {
        await read { SerialIterator(sequence().makeAsyncIterator()) }
    }

    /// One consumer's iterator, handed across the serial lane.
    public final class SerialIterator<Element>: @unchecked Sendable {
        private let advance: () async -> Element?

        init<I: AsyncIteratorProtocol>(_ iterator: I) where I.Element == Element {
            var iterator = iterator
            advance = { try? await iterator.next() }
        }

        public func next() async -> Element? { await advance() }
    }
}

@available(iOS 16.2, *)
extension BuzzKit.Activities {
    /// Starts a Live Activity and hands it to BuzzKit in one call: requests it through
    /// ActivityKit with a push token, registers the token, and tracks
    /// `$activity.started`.
    ///
    /// ```swift
    /// let activity = try BuzzKit.activities.start(
    ///     WorkoutAttributes(workoutId: id),
    ///     state: .init(elapsed: 0)
    /// )
    /// ```
    @discardableResult
    public func start<Attributes: ActivityAttributes>(
        _ attributes: Attributes,
        state: Attributes.ContentState,
        staleDate: Date? = nil,
        relevanceScore: Double = 0
    ) throws -> Activity<Attributes> {
        let activity = try Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: staleDate, relevanceScore: relevanceScore),
            pushType: .token
        )
        monitor(activity)
        return activity
    }

    /// Watches every activity of a type, current and future, wherever it was started:
    /// by the app, by ``start(_:state:staleDate:)``, or remotely by the server. Tokens
    /// stay registered, lifecycle events are tracked, and on iOS 17.2 the push-to-start
    /// token registers too. Call once at launch per attributes type.
    public func observe<Attributes: ActivityAttributes>(_ type: Attributes.Type) {
        Task {
            let existing = await ActivityKitSerialAccess.read { UncheckedSendableBox(Activity<Attributes>.activities) }
            for activity in existing.value {
                monitor(activity, isNew: false)
            }
            let updates = await ActivityKitSerialAccess.iterate { Activity<Attributes>.activityUpdates }
            while let activity = await updates.next() {
                monitor(activity)
            }
        }
        if #available(iOS 17.2, *) {
            enablePushToStart(for: type)
        }
    }

    /// Ends an activity everywhere: on the device through ActivityKit, on the server,
    /// and as an `$activity.ended` event.
    public func end<Attributes: ActivityAttributes>(
        _ activity: Activity<Attributes>,
        dismissalPolicy: ActivityUIDismissalPolicy = .default
    ) async {
        await activity.end(activity.content, dismissalPolicy: dismissalPolicy)
        try? await end(id: activity.id)
    }

    /// Keeps an activity's push token registered and its lifecycle tracked. Prefer
    /// ``observe(_:)`` or ``start(_:state:staleDate:)``, which call this for you.
    public func monitor<Attributes: ActivityAttributes>(_ activity: Activity<Attributes>) {
        monitor(activity, isNew: true)
    }

    func monitor<Attributes: ActivityAttributes>(_ activity: Activity<Attributes>, isNew: Bool) {
        let activityId = activity.id
        let attributesType = String(describing: Attributes.self)
        guard ActivitySeen.markNew(activityId) else { return }
        if isNew {
            trackLifecycle(EventNames.activityStarted, id: activityId, attributesType: attributesType)
        }
        let boxed = UncheckedSendableBox(activity)
        Task {
            let tokens = await ActivityKitSerialAccess.iterate { boxed.value.pushTokenUpdates }
            while let token = await tokens.next() {
                try? await register(id: activityId, token: token, attributesType: attributesType)
            }
        }
        Task {
            let states = await ActivityKitSerialAccess.iterate { boxed.value.activityStateUpdates }
            while let state = await states.next() {
                switch state {
                case .ended:
                    trackLifecycle(EventNames.activityEnded, id: activityId, attributesType: attributesType)
                    try? await end(id: activityId)
                case .dismissed:
                    trackLifecycle(EventNames.activityDismissed, id: activityId, attributesType: attributesType)
                    try? await end(id: activityId)
                    return
                case .stale:
                    trackLifecycle(EventNames.activityStale, id: activityId, attributesType: attributesType)
                default:
                    break
                }
            }
        }
    }

    /// Registers push-to-start tokens for an attributes type, so the server can start
    /// activities of this type without the app running.
    @available(iOS 17.2, *)
    public func enablePushToStart<Attributes: ActivityAttributes>(for _: Attributes.Type) {
        let attributesType = String(describing: Attributes.self)
        Task {
            let tokens = await ActivityKitSerialAccess.iterate { Activity<Attributes>.pushToStartTokenUpdates }
            while let token = await tokens.next() {
                try? await registerPushToStartToken(token, attributesType: attributesType)
            }
        }
    }
}
#endif
