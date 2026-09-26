import Foundation
import SwiftUI
import UIKit

enum LoopdyWorkspaceConnectivity: Equatable {
    case nativeOnly
}

struct LoopdyFixtureProtectedDataAvailability:
    LoopdyProtectedDataAvailabilityProviding
{
    let isProtectedDataAvailable = true
}

@MainActor
final class LoopdyHostSelectionChangeRelay {
    typealias Handler = @MainActor (String?) async -> Void

    private enum PendingChange {
        case host(String?)
    }

    var willChange: @MainActor (String?) -> Void = { _ in }
    var handler: Handler = { _ in }
    private var pendingChange: PendingChange?
    private var task: Task<Void, Never>?

    func send(_ hostID: String?) {
        // The socket target changes synchronously. Fence old composers in the
        // same main-actor turn, before asynchronous refresh work is enqueued.
        willChange(hostID)
        pendingChange = .host(hostID)
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            await self?.drainChanges()
        }
    }

    private func drainChanges() async {
        while let change = pendingChange {
            pendingChange = nil
            switch change {
            case .host(let hostID):
                await handler(hostID)
            }
        }
        task = nil
    }
}
