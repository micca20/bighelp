import Foundation

@MainActor
final class AsyncOperationTestGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, any Error>?
    func wait() async throws {
        entered = true
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(error: (any Error)? = nil) {
        let pending = continuation
        continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
