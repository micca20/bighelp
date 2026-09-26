@preconcurrency import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

/// The fixed managed-media operations available to native playback. The
/// concrete client remains owner-bound and confines every request to its
/// verified configured-workspace scope.
@MainActor
protocol DirectHermesManagedMediaReading: AnyObject {
    var ownsScope: Bool { get }
    func probeStream(_ file: HermesManagedFile) async throws -> HermesManagedMediaProbe
    func readMediaRange(_ file: HermesManagedFile, range: Range<Int>) async throws -> HermesManagedFileRange
}

extension DirectHermesManagedFilesClient: DirectHermesManagedMediaReading {
    func readMediaRange(
        _ file: HermesManagedFile,
        range: Range<Int>
    ) async throws -> HermesManagedFileRange {
        try await stream(file, range: range)
    }
}

struct DirectHermesManagedMediaMetadata: Equatable, Sendable {
    let contentTypeIdentifier: String
    let byteCount: Int
}

/// Streams AVFoundation requests through bounded managed-file range reads.
/// Bytes are handed to AVFoundation one chunk at a time and are never assembled
/// into a complete in-memory media file.
@MainActor
final class DirectHermesManagedMediaConsumer {
    nonisolated static let maximumRangeRequestBytes = 512 * 1_024

    let file: HermesManagedFile

    private let reader: any DirectHermesManagedMediaReading
    private var probeTask: Task<HermesManagedMediaProbe, any Error>?
    private var metadata: DirectHermesManagedMediaMetadata?
    private(set) var isRetired = false

    init(file: HermesManagedFile, reader: any DirectHermesManagedMediaReading) {
        self.file = file
        self.reader = reader
    }

    nonisolated static func supports(_ file: HermesManagedFile) -> Bool {
        guard !file.isDirectory,
              let byteCount = file.byteCount,
              byteCount > 0,
              let mimeType = file.mimeType,
              mimeType.hasPrefix("audio/") || mimeType.hasPrefix("video/"),
              let contentType = UTType(mimeType: mimeType) else { return false }
        return contentType.conforms(to: .audio) || contentType.conforms(to: .movie)
    }

    var ownsScope: Bool { !isRetired && reader.ownsScope }

    func prepare() async throws -> DirectHermesManagedMediaMetadata {
        try checkOwnership()
        if let metadata { return metadata }

        let task: Task<HermesManagedMediaProbe, any Error>
        if let probeTask {
            task = probeTask
        } else {
            let created = Task { @MainActor [file, reader] in
                try await reader.probeStream(file)
            }
            probeTask = created
            task = created
        }

        do {
            let probe = try await task.value
            try checkOwnership()
            guard probe.file == file,
                  probe.acceptsByteRanges,
                  let byteCount = file.byteCount,
                  byteCount > 0,
                  let mimeType = file.mimeType,
                  let contentType = UTType(mimeType: mimeType),
                  contentType.conforms(to: .audio) || contentType.conforms(to: .movie) else {
                throw DirectHermesManagedFilesError.invalidResponse
            }
            let prepared = DirectHermesManagedMediaMetadata(
                contentTypeIdentifier: contentType.identifier,
                byteCount: byteCount
            )
            metadata = prepared
            probeTask = nil
            return prepared
        } catch {
            probeTask = nil
            try checkOwnership()
            throw error
        }
    }

    func consume(
        range: Range<Int>,
        onChunk: (Data) throws -> Void
    ) async throws {
        let prepared = try await prepare()
        guard range.lowerBound >= 0,
              range.lowerBound < range.upperBound,
              range.upperBound <= prepared.byteCount else {
            throw DirectHermesManagedFilesError.invalidResponse
        }

        var offset = range.lowerBound
        while offset < range.upperBound {
            try checkOwnership()
            let chunkLength = min(
                range.upperBound - offset,
                Self.maximumRangeRequestBytes
            )
            let upperBound = offset + chunkLength
            let requested = offset..<upperBound
            let response = try await reader.readMediaRange(file, range: requested)
            try checkOwnership()
            guard response.file == file,
                  response.requested == requested,
                  response.totalByteCount == prepared.byteCount,
                  response.bytes.count == requested.count else {
                throw DirectHermesManagedFilesError.invalidResponse
            }
            try onChunk(response.bytes)
            offset = upperBound
        }
    }

    func retire() {
        guard !isRetired else { return }
        isRetired = true
        probeTask?.cancel()
        probeTask = nil
        metadata = nil
    }

    private func checkOwnership() throws {
        try Task.checkCancellation()
        guard ownsScope else { throw DirectHermesManagedFilesError.ownerChanged }
    }
}

private final class DirectHermesLoadingRequestBox: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
    let id = UUID()

    private let lock = NSLock()
    private var cancelled = false

    init(_ request: AVAssetResourceLoadingRequest) {
        self.request = request
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class DirectHermesLoadingRequestTracker: @unchecked Sendable {
    private let maximumCount: Int
    private let lock = NSLock()
    private var requests: [ObjectIdentifier: DirectHermesLoadingRequestBox] = [:]

    init(maximumCount: Int) {
        self.maximumCount = maximumCount
    }

    func register(_ request: AVAssetResourceLoadingRequest) -> DirectHermesLoadingRequestBox? {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(request)
        if let existing = requests[key] { return existing }
        guard requests.count < maximumCount else { return nil }
        let box = DirectHermesLoadingRequestBox(request)
        requests[key] = box
        return box
    }

    func cancel(_ request: AVAssetResourceLoadingRequest) -> DirectHermesLoadingRequestBox? {
        lock.lock()
        let box = requests.removeValue(forKey: ObjectIdentifier(request))
        lock.unlock()
        box?.cancel()
        return box
    }

    func complete(_ box: DirectHermesLoadingRequestBox) {
        lock.lock()
        let key = ObjectIdentifier(box.request)
        if let current = requests[key], current === box {
            requests.removeValue(forKey: key)
        }
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let boxes = Array(requests.values)
        requests.removeAll()
        lock.unlock()
        boxes.forEach { $0.cancel() }
    }
}

/// Bridges AVFoundation's callback-based custom asset loading into the bounded
/// managed-media consumer above.
@MainActor
final class DirectHermesManagedMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    nonisolated let delegateQueue = DispatchQueue(label: "app.loopdy.managed-media-resource-loader")
    nonisolated static let maximumOutstandingRequests = 8
    nonisolated private let requestTracker: DirectHermesLoadingRequestTracker

    private let consumer: DirectHermesManagedMediaConsumer
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isRetired = false
    var onFailure: (@MainActor (any Error) -> Void)?

    init(consumer: DirectHermesManagedMediaConsumer) {
        self.consumer = consumer
        requestTracker = DirectHermesLoadingRequestTracker(
            maximumCount: Self.maximumOutstandingRequests
        )
    }

    nonisolated func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let box = requestTracker.register(loadingRequest) else {
            Task { @MainActor [weak self] in
                self?.onFailure?(DirectHermesManagedFilesError.invalidResponse)
            }
            return false
        }
        Task { @MainActor [weak self, box] in
            self?.begin(box)
        }
        return true
    }

    nonisolated func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        guard let box = requestTracker.cancel(loadingRequest) else { return }
        Task { @MainActor [weak self, box] in
            self?.cancel(box.id)
        }
    }

    func retire() {
        guard !isRetired else { return }
        isRetired = true
        consumer.retire()
        requestTracker.cancelAll()
        let pending = Array(tasks.values)
        tasks.removeAll()
        pending.forEach { $0.cancel() }
    }

    nonisolated static func requestedRange(
        requestedOffset: Int64,
        currentOffset: Int64,
        requestedLength: Int,
        requestsAllDataToEnd: Bool,
        totalByteCount: Int
    ) -> Range<Int>? {
        guard totalByteCount > 0,
              requestedOffset >= 0,
              currentOffset >= 0,
              requestedLength > 0,
              let requestedStart = Int(exactly: requestedOffset),
              let currentStart = Int(exactly: currentOffset) else { return nil }
        let lowerBound = max(requestedStart, currentStart)
        guard lowerBound < totalByteCount else { return nil }
        if requestsAllDataToEnd { return lowerBound..<totalByteCount }
        let upper = requestedStart.addingReportingOverflow(requestedLength)
        guard !upper.overflow else { return nil }
        let upperBound = min(upper.partialValue, totalByteCount)
        guard lowerBound < upperBound else { return nil }
        return lowerBound..<upperBound
    }

    private func begin(_ box: DirectHermesLoadingRequestBox) {
        guard !box.isCancelled else { return }
        guard !isRetired else {
            box.request.finishLoading(with: DirectHermesManagedFilesError.ownerChanged)
            requestTracker.complete(box)
            return
        }

        tasks[box.id]?.cancel()
        tasks[box.id] = Task { @MainActor [weak self, box] in
            guard let self else { return }
            await fulfill(box)
            tasks[box.id] = nil
            requestTracker.complete(box)
        }
    }

    private func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
    }

    private func fulfill(_ box: DirectHermesLoadingRequestBox) async {
        do {
            let metadata = try await consumer.prepare()
            try Task.checkCancellation()
            guard !box.isCancelled else { throw CancellationError() }
            guard !isRetired else { throw DirectHermesManagedFilesError.ownerChanged }

            if let information = box.request.contentInformationRequest {
                if let allowedTypes = information.allowedContentTypes,
                   !allowedTypes.isEmpty,
                   !allowedTypes.contains(metadata.contentTypeIdentifier) {
                    throw DirectHermesManagedFilesError.invalidResponse
                }
                information.contentType = metadata.contentTypeIdentifier
                information.contentLength = Int64(metadata.byteCount)
                information.isByteRangeAccessSupported = true
            }

            if let dataRequest = box.request.dataRequest {
                guard let range = Self.requestedRange(
                    requestedOffset: dataRequest.requestedOffset,
                    currentOffset: dataRequest.currentOffset,
                    requestedLength: dataRequest.requestedLength,
                    requestsAllDataToEnd: dataRequest.requestsAllDataToEndOfResource,
                    totalByteCount: metadata.byteCount
                ) else {
                    throw DirectHermesManagedFilesError.invalidResponse
                }
                try await consumer.consume(range: range) { bytes in
                    try Task.checkCancellation()
                    guard !box.isCancelled, !isRetired else { throw CancellationError() }
                    dataRequest.respond(with: bytes)
                }
            }

            guard !box.isCancelled, !Task.isCancelled, !isRetired else { return }
            box.request.finishLoading()
        } catch {
            guard !box.isCancelled, !Task.isCancelled, !isRetired else { return }
            box.request.finishLoading(with: error)
            onFailure?(error)
        }
    }
}

@MainActor
@Observable
final class DirectHermesManagedMediaPlayback: Identifiable {
    nonisolated let id = UUID()
    let file: HermesManagedFile
    let player = AVPlayer()

    private(set) var isPreparing = false
    private(set) var isReady = false
    private(set) var errorMessage: String?
    private(set) var isRetired = false

    private let consumer: DirectHermesManagedMediaConsumer
    private let resourceLoader: DirectHermesManagedMediaResourceLoader
    private var didStart = false
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    init(file: HermesManagedFile, reader: any DirectHermesManagedMediaReading) {
        self.file = file
        let consumer = DirectHermesManagedMediaConsumer(file: file, reader: reader)
        self.consumer = consumer
        resourceLoader = DirectHermesManagedMediaResourceLoader(consumer: consumer)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
        resourceLoader.onFailure = { [weak self] error in
            self?.fail(error)
        }
    }

    nonisolated static func supports(_ file: HermesManagedFile) -> Bool {
        DirectHermesManagedMediaConsumer.supports(file)
    }

    var isVideo: Bool { file.mimeType?.lowercased().hasPrefix("video/") == true }

    func start() async {
        guard !didStart, !isRetired else { return }
        didStart = true
        isPreparing = true
        errorMessage = nil

        do {
            _ = try await consumer.prepare()
            try Task.checkCancellation()
            guard consumer.ownsScope, !isRetired,
                  let assetURL = URL(string: "loopdy-managed-media://asset/\(id.uuidString)") else {
                throw DirectHermesManagedFilesError.ownerChanged
            }
            let asset = AVURLAsset(url: assetURL)
            asset.resourceLoader.setDelegate(resourceLoader, queue: resourceLoader.delegateQueue)
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, !isRetired, player.currentItem === item else { return }
                    switch item.status {
                    case .readyToPlay:
                        isReady = true
                        isPreparing = false
                    case .failed:
                        fail(URLError(.cannotDecodeContentData))
                    default:
                        break
                    }
                }
            }
            player.play()
        } catch {
            if error is CancellationError { retire(); return }
            fail(error)
        }
    }

    func monitorOwnership() async {
        while !Task.isCancelled, !isRetired {
            guard consumer.ownsScope else {
                errorMessage = DirectHermesManagedFilesError.ownerChanged.localizedDescription
                retirePlayback(preservingError: true)
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
        }
    }

    func retire() {
        retirePlayback(preservingError: false)
    }

    private func retirePlayback(preservingError: Bool) {
        guard !isRetired else { return }
        isRetired = true
        statusObservation?.invalidate()
        statusObservation = nil
        resourceLoader.retire()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isReady = false
        isPreparing = false
        if !preservingError { errorMessage = nil }
    }

    private func fail(_ error: any Error) {
        guard !isRetired else { return }
        errorMessage = Self.message(for: error)
        retirePlayback(preservingError: true)
    }

    private static func message(for error: any Error) -> String {
        if let error = error as? DirectHermesManagedFilesError {
            return error.localizedDescription
        }
        if let error = error as? DirectHermesError {
            return error.localizedDescription
        }
        if let error = error as? WorkspaceClientError {
            return error.localizedDescription
        }
        return "This audio or video could not be played from Hermes."
    }
}
