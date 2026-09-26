import Foundation
import Observation
import SwiftUI
import UIKit

protocol ProviderLogoFetching: Sendable {
    func data(from url: URL, maximumBytes: Int) async throws -> Data
}

/// Optional public artwork, independent of accounts, hosts, and model selection.
/// The app root owns the live instance; previews and fixtures default to bundled art.
@MainActor
@Observable
final class ProviderLogoStore {
    private(set) var revision: String?
    private var images: [String: UIImage] = [:]
    private var manifest: ProviderLogoManifest?

    @ObservationIgnored private let repository: ProviderLogoRepository
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var restoredCache = false
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var retryAfter: Date?
    @ObservationIgnored private var cachedBytes: [String: Data] = [:]
    @ObservationIgnored private var inFlight: ProviderLogoRefreshFlight?

    init(
        manifestURL: URL,
        cacheURL: URL?,
        transport: any ProviderLogoFetching,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        repository = ProviderLogoRepository(
            manifestURL: manifestURL,
            cacheURL: cacheURL,
            transport: transport,
            allowedAssetNames: Set(AIProviderBrand.allCases.compactMap(\.logoAssetName))
        )
    }

    static func makeLive() -> ProviderLogoStore {
        ProviderLogoStore(
            manifestURL: ProviderLogoPolicy.manifestURL,
            cacheURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
                .first?.appending(path: "ProviderLogos/v1-snapshot.json"),
            transport: ProviderLogoURLSessionTransport()
        )
    }

    func image(for assetName: String, colorScheme: ColorScheme) -> UIImage? {
        guard let variants = manifest?.logos[assetName] else { return nil }
        let reference = colorScheme == .dark ? variants.dark : variants.light
        return images[reference.sha256]
    }

    /// One whole-catalog request is shared by all callers, never by the selected model.
    /// Cancelling the final waiter cancels the transport and prevents publication.
    func refreshIfNeeded(force: Bool = false) async {
        guard !Task.isCancelled else { return }
        let waiter = UUID()
        let flight: ProviderLogoRefreshFlight
        if let inFlight, inFlight.add(waiter) {
            flight = inFlight
        } else {
            flight = ProviderLogoRefreshFlight(waiter: waiter)
            inFlight = flight
            let flightID = flight.id
            let task = Task { [self] in
                await refresh(force: force)
                if inFlight?.id == flightID { inFlight = nil }
            }
            flight.start(task)
        }
        await withTaskCancellationHandler {
            await flight.wait()
            flight.remove(waiter)
        } onCancel: {
            flight.remove(waiter)
        }
    }

    private func refresh(force: Bool) async {
        do {
            try Task.checkCancellation()
            if !restoredCache {
                let restored = await repository.restore()
                try Task.checkCancellation()
                restoredCache = true
                if let restored { apply(restored) }
            }
            let currentTime = now()
            if !force {
                if let retryAfter, currentTime < retryAfter { return }
                if let fetchedAt {
                    let age = currentTime.timeIntervalSince(fetchedAt)
                    if age >= 0, age < ProviderLogoPolicy.refreshInterval { return }
                }
            }
            let prepared = try await repository.fetch(reusing: cachedBytes, now: now)
            try Task.checkCancellation()
            // A cache-write failure must not hide a fully verified network result.
            // Disk replacement is atomic and contains only the complete new catalog.
            await repository.persist(prepared.snapshot)
            try Task.checkCancellation()
            apply(prepared)
            retryAfter = nil
        } catch {
            // Optional decoration has no user-facing errors or loading state.
            // Cancellation is not a network failure and must not delay reactivation.
            if !Task.isCancelled {
                retryAfter = now().addingTimeInterval(ProviderLogoPolicy.failureBackoff)
            }
        }
    }

    private func apply(_ prepared: ProviderLogoPreparedSnapshot) {
        images = prepared.images.mapValues { UIImage(cgImage: $0.value) }
        cachedBytes = prepared.snapshot.images
        manifest = prepared.manifest
        revision = prepared.manifest.revision
        fetchedAt = prepared.snapshot.fetchedAt
    }
}

private struct ProviderLogoStoreKey: EnvironmentKey {
    static let defaultValue: ProviderLogoStore? = nil
}

extension EnvironmentValues {
    var providerLogoStore: ProviderLogoStore? {
        get { self[ProviderLogoStoreKey.self] }
        set { self[ProviderLogoStoreKey.self] = newValue }
    }
}

/// Only the waiter set and task handle cross executors; both are lock-protected.
private final class ProviderLogoRefreshFlight: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var waiters: Set<UUID>
    private var task: Task<Void, Never>?

    init(waiter: UUID) { waiters = [waiter] }

    func add(_ waiter: UUID) -> Bool {
        lock.withLock {
            // A new foreground caller must not join already-cancelled work.
            guard !waiters.isEmpty else { return false }
            waiters.insert(waiter)
            return true
        }
    }

    func start(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            self.task = task
            return waiters.isEmpty
        }
        if shouldCancel { task.cancel() }
    }

    func wait() async {
        let task = lock.withLock { self.task }
        await task?.value
    }

    func remove(_ waiter: UUID) {
        let taskToCancel = lock.withLock { () -> Task<Void, Never>? in
            guard waiters.remove(waiter) != nil, waiters.isEmpty else { return nil }
            return task
        }
        taskToCancel?.cancel()
    }
}
