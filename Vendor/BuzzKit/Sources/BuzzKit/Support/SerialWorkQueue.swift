import Foundation

final class SerialWorkQueue: Sendable {
    private let tail = LockedState<Task<Void, Never>?>(nil)

    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        tail.withLock { previous in
            let earlier = previous
            previous = Task {
                await earlier?.value
                await work()
            }
        }
    }

    func drain() async {
        await tail.read()?.value
    }

    func submit<Value: Sendable>(
        _ work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let submitted = tail.withLock { previous -> Task<Value, any Error> in
            let earlier = previous
            let task = Task {
                await earlier?.value
                try Task.checkCancellation()
                return try await work()
            }
            previous = Task { _ = try? await task.value }
            return task
        }
        return try await withTaskCancellationHandler {
            try await submitted.value
        } onCancel: {
            submitted.cancel()
        }
    }
}
