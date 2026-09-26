import Network
import Observation
import SwiftUI

/// The selected host connection as a chat sees it.
enum WorkspaceConnectionState: Equatable, Sendable {
    case connected, reconnecting, disconnected
}

enum WorkspaceReconnectPolicy {
    /// The transport already retries for a few seconds. After that, keep trying
    /// with backoff while the app is open instead of giving up silently.
    static let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30)]
    /// Attempts made before the chat offers a manual Retry.
    static let quietAttempts = 3

    static func delay(afterAttempt attempt: Int) -> Duration {
        delays[min(max(attempt, 0), delays.count - 1)]
    }
}

/// Restores a dropped host connection while the app is open, and tells an
/// open chat what is happening so a disabled Send button is never a mystery.
///
/// It observes the store directly instead of relying on view updates: a view
/// under a pushed chat does not refresh its tasks until it is visible again.
@MainActor
@Observable
final class WorkspaceConnectionKeeper {
    private(set) var state: WorkspaceConnectionState = .connected

    @ObservationIgnored private var storeProvider: () -> DirectHermesWorkspaceStore? = { nil }
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var isPathSatisfied = true
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var tracking = 0
    @ObservationIgnored private nonisolated(unsafe) let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "app.loopdy.network-path"))
    }

    deinit { monitor.cancel() }

    /// Follows whichever host store is selected; safe to call repeatedly.
    func bind(_ provider: @escaping () -> DirectHermesWorkspaceStore?) {
        storeProvider = provider
        evaluate()
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        attempt = 0
        evaluate()
    }

    /// A chat's Retry button: try now and restart the backoff.
    func retry() {
        attempt = 0
        loop?.cancel()
        loop = nil
        evaluate(tryNow: true)
    }

    private func pathChanged(satisfied: Bool) {
        let recovered = satisfied && !isPathSatisfied
        isPathSatisfied = satisfied
        if recovered { attempt = 0; loop?.cancel(); loop = nil }
        evaluate(tryNow: recovered)
    }

    /// Recomputes the state and re-arms observation of the store's connection.
    private func evaluate(tryNow: Bool = false) {
        tracking &+= 1
        let current = tracking
        let store = withObservationTracking {
            let store = storeProvider()
            _ = store.map { ($0.isConnected, $0.isConnecting, $0.hasSavedConnection) }
            return store
        } onChange: { [weak self] in
            // Only the latest registration re-arms, so observations never pile up.
            Task { @MainActor [weak self] in
                guard let self, self.tracking == current else { return }
                self.evaluate()
            }
        }
        guard let store, store.hasSavedConnection, !store.isConnected else {
            loop?.cancel(); loop = nil; attempt = 0
            publish(.connected)
            return
        }
        guard isActive, isPathSatisfied else {
            loop?.cancel(); loop = nil
            publish(isActive ? .disconnected : .reconnecting)
            return
        }
        publish(store.isConnecting || attempt < WorkspaceReconnectPolicy.quietAttempts ? .reconnecting : .disconnected)
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            await self?.reconnectWithBackoff(store, immediately: tryNow)
        }
    }

    private func reconnectWithBackoff(_ store: DirectHermesWorkspaceStore, immediately: Bool) async {
        var waitFirst = !immediately
        while !Task.isCancelled {
            if waitFirst {
                do { try await Task.sleep(for: WorkspaceReconnectPolicy.delay(afterAttempt: attempt)) } catch { return }
                attempt += 1
            }
            waitFirst = true
            guard !Task.isCancelled, isActive, isPathSatisfied, storeProvider() === store,
                  store.hasSavedConnection, !store.isConnected else { break }
            if !store.isConnecting { await store.reconnect() }
            if store.isConnected { break }
            publish(attempt < WorkspaceReconnectPolicy.quietAttempts ? .reconnecting : .disconnected)
        }
        if !Task.isCancelled { loop = nil; evaluate() }
    }

    private func publish(_ value: WorkspaceConnectionState) {
        if state != value { state = value }
    }
}

/// Shown above the composer while the host connection is being restored.
struct ChatConnectionBanner: View {
    let state: WorkspaceConnectionState
    let retry: () -> Void

    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            if state == .reconnecting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityHidden(true)
            }
            Text(state == .reconnecting ? "Reconnecting to your computer…" : "Not connected to your computer")
                .font(.footnote.weight(.medium))
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: BighelpTokens.space8)
            if state == .disconnected {
                Button("Retry", action: retry)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.action)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("chat.connection.retry")
            }
        }
        .padding(.horizontal, BighelpTokens.space12)
        .frame(minHeight: 36)
        .background(theme.incomingMessageBackground, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.connection-banner")
    }
}
