import AVFoundation
import Foundation

/// Fixed-route stock voice media transport. It reuses the retained Direct
/// authenticator, but neither exposes it nor accepts caller-authored routes,
/// headers, bearer values, or WebSocket URLs.
@MainActor
final class DirectHermesVoiceMediaTransport: DirectHermesVoiceRelayMediaHTTP,
    DirectHermesVoiceStreamingPlaybackTransport {
    private static let maximumControlFrameBytes = 32 * 1_024
    /// Matches the stock streamer's per-sentence PCM cap. A large provider
    /// frame is split into short native buffers before it is scheduled.
    private static let maximumBinaryFrameBytes = 16 * 1_024 * 1_024
    private static let maximumTotalPCMBytes = 64 * 1_024 * 1_024

    private let authenticator: DirectHermesAuthenticator
    private let isCurrent: @MainActor () -> Bool
    private let sessionCoordinator: VoiceAudioSessionCoordinator
    private var operationID: UUID?
    private var socket: URLSessionWebSocketTask?
    private var pcmPlayer: DirectHermesPCMStreamingPlayer?

    init(
        authenticator: DirectHermesAuthenticator,
        isCurrent: @escaping @MainActor () -> Bool,
        sessionCoordinator: VoiceAudioSessionCoordinator = .shared
    ) {
        self.authenticator = authenticator
        self.isCurrent = isCurrent
        self.sessionCoordinator = sessionCoordinator
    }

    func transcribeVoice(
        profileID: String,
        recording: DirectHermesVoiceRecording
    ) async throws -> LoopdyJSONValue {
        let profile = try DirectHermesProviderClient.profile(profileID)
        try checkTransportOwner()
        guard !recording.bytes.isEmpty,
              recording.bytes.count <= DirectHermesVoiceRecording.maximumHostBytes else {
            throw WorkspaceClientError.capacityExceeded
        }
        let dataURL = "data:\(recording.mimeType);base64,\(recording.bytes.base64EncodedString())"
        let response = try await authenticator.authenticatedResponse(.init(
            path: "/api/audio/transcribe",
            method: .post,
            query: [.init(name: "profile", value: profile)],
            body: [
                "data_url": .string(dataURL),
                "mime_type": .string(recording.mimeType),
            ],
            maximumResponseBytes: 1 * 1_024 * 1_024
        ))
        try checkTransportOwner()
        try DirectHermesHTTP.requireSuccess(response)
        return try response.value()
    }

    func play(
        profileID: String,
        text: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws -> DirectHermesVoiceStreamResult {
        let profile = try DirectHermesProviderClient.profile(profileID)
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 20_000 else {
            throw WorkspaceClientError.invalidRequest
        }
        try checkTransportOwner()

        stop()
        let id = UUID()
        operationID = id
        return try await withTaskCancellationHandler {
            do {
                let result = try await runPlayback(
                    id: id,
                    profileID: profile,
                    text: normalized,
                    onPlayback: onPlayback
                )
                finishOperation(id: id, failed: false)
                return result
            } catch {
                let stillOwned = operationID == id
                finishOperation(id: id, failed: stillOwned)
                if !stillOwned {
                    if Task.isCancelled { throw CancellationError() }
                    throw WorkspaceClientError.ownerChanged
                }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.operationID == id else { return }
                self?.finishOperation(id: id, failed: true)
            }
        }
    }

    func stop() {
        guard let operationID else { return }
        finishOperation(id: operationID, failed: true)
    }

    private func runPlayback(
        id: UUID,
        profileID: String,
        text: String,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) async throws -> DirectHermesVoiceStreamResult {
        let request = try await authenticator.voiceStreamingRequest(profileID: profileID)
        try check(id: id)
        let expectedURL = request.url
        let socket = authenticator.http.session.webSocketTask(with: request)
        socket.maximumMessageSize = Self.maximumBinaryFrameBytes
        self.socket = socket
        socket.resume()
        let ownerMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard let self, self.operationID == id else { return }
                guard self.isCurrent() else {
                    self.finishOperation(id: id, failed: true)
                    return
                }
            }
        }
        defer { ownerMonitor.cancel() }

        let outbound = LoopdyJSONValue.object([
            "text": .string(text),
            "done": .boolean(true),
        ])
        let outboundData = try JSONEncoder().encode(outbound)
        guard outboundData.count <= Self.maximumControlFrameBytes,
              let outboundText = String(data: outboundData, encoding: .utf8) else {
            throw WorkspaceClientError.capacityExceeded
        }
        try await socket.send(.string(outboundText))
        try check(id: id)

        var receivedStart = false
        var receivedAudio = false
        var sampleRate = 0
        var channels = 0
        var carry = Data()
        var totalPCMBytes = 0

        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                try throwSocketError(error, socket: socket, expectedURL: expectedURL)
            }
            try check(id: id)
            try validateUpgrade(socket, expectedURL: expectedURL)

            switch message {
            case .string(let text):
                let frame = try Self.controlFrame(text)
                switch frame {
                case .start(let rate, let count):
                    guard !receivedStart, !receivedAudio, pcmPlayer == nil else {
                        throw WorkspaceClientError.invalidResponse
                    }
                    receivedStart = true
                    sampleRate = rate
                    channels = count
                    let player = DirectHermesPCMStreamingPlayer(
                        sessionCoordinator: sessionCoordinator,
                        operationID: id,
                        sampleRate: rate,
                        channels: count,
                        onPlayback: onPlayback
                    )
                    try player.start()
                    pcmPlayer = player

                case .fallback:
                    guard !receivedStart, !receivedAudio, pcmPlayer == nil else {
                        throw WorkspaceClientError.invalidResponse
                    }
                    return .fallbackRequired

                case .end:
                    guard receivedStart, receivedAudio, carry.isEmpty,
                          let player = pcmPlayer else {
                        throw WorkspaceClientError.invalidResponse
                    }
                    try await player.finish()
                    try check(id: id)
                    return .played
                }

            case .data(let bytes):
                guard receivedStart, let player = pcmPlayer else {
                    throw WorkspaceClientError.invalidResponse
                }
                let frameBytes = channels * MemoryLayout<Int16>.size
                guard frameBytes > 0 else { throw WorkspaceClientError.invalidResponse }

                var joined = Data()
                if carry.isEmpty {
                    joined = bytes
                } else {
                    guard carry.count + bytes.count <= Self.maximumBinaryFrameBytes + frameBytes - 1 else {
                        throw WorkspaceClientError.capacityExceeded
                    }
                    joined.reserveCapacity(carry.count + bytes.count)
                    joined.append(carry)
                    joined.append(bytes)
                    carry.removeAll(keepingCapacity: false)
                }
                guard joined.count <= Self.maximumBinaryFrameBytes + frameBytes - 1 else {
                    throw WorkspaceClientError.capacityExceeded
                }

                let usableCount = joined.count - joined.count % frameBytes
                if usableCount < joined.count {
                    carry = joined.subdata(in: usableCount..<joined.count)
                }
                guard usableCount > 0 else { continue }

                let addition = totalPCMBytes.addingReportingOverflow(usableCount)
                guard !addition.overflow, addition.partialValue <= Self.maximumTotalPCMBytes else {
                    throw WorkspaceClientError.capacityExceeded
                }
                totalPCMBytes = addition.partialValue
                let maximumScheduleBytes = sampleRate * channels * MemoryLayout<Int16>.size * 2
                var offset = 0
                while offset < usableCount {
                    let upperBound = min(usableCount, offset + maximumScheduleBytes)
                    try await player.schedule(Data(joined[offset..<upperBound]))
                    try check(id: id)
                    offset = upperBound
                }
                receivedAudio = true

                // The start frame is immutable for this speech session. Retain
                // these values so malformed later state can never alter decoding.
                guard sampleRate == player.sampleRate, channels == player.channels else {
                    throw WorkspaceClientError.invalidResponse
                }

            @unknown default:
                throw WorkspaceClientError.invalidResponse
            }
        }
    }

    private func checkTransportOwner() throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw WorkspaceClientError.ownerChanged }
    }

    private func check(id: UUID) throws {
        try checkTransportOwner()
        guard operationID == id else { throw WorkspaceClientError.ownerChanged }
    }

    private func validateUpgrade(
        _ socket: URLSessionWebSocketTask,
        expectedURL: URL?
    ) throws {
        guard let response = socket.response as? HTTPURLResponse else { return }
        guard response.url == expectedURL else { throw DirectHermesError.redirectRefused }
        if (300...399).contains(response.statusCode) {
            throw DirectHermesError.redirectRefused
        }
        guard response.statusCode == 101 else {
            switch response.statusCode {
            case 401, 403: throw DirectHermesError.invalidCredentials
            case 429: throw DirectHermesError.rateLimited
            case 500...599: throw DirectHermesError.serverUnavailable
            default: throw DirectHermesError.invalidResponse
            }
        }
    }

    private func throwSocketError(
        _ error: any Error,
        socket: URLSessionWebSocketTask,
        expectedURL: URL?
    ) throws -> Never {
        if let response = socket.response as? HTTPURLResponse {
            guard response.url == expectedURL else { throw DirectHermesError.redirectRefused }
            if (300...399).contains(response.statusCode) {
                throw DirectHermesError.redirectRefused
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                throw DirectHermesError.invalidCredentials
            }
        }
        throw DirectHermesHTTP.safeError(error)
    }

    private func finishOperation(id: UUID, failed: Bool) {
        guard operationID == id else { return }
        operationID = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pcmPlayer?.stop(notifyFailure: failed)
        pcmPlayer = nil
    }

    enum ControlFrame: Equatable {
        case start(sampleRate: Int, channels: Int)
        case fallback
        case end
    }

    static func controlFrame(_ text: String) throws -> ControlFrame {
        guard text.utf8.count <= maximumControlFrameBytes else {
            throw WorkspaceClientError.capacityExceeded
        }
        let data = Data(text.utf8)
        try DirectHermesWire.validateNesting(data)
        guard let value = try? JSONDecoder().decode(LoopdyJSONValue.self, from: data),
              let object = value.object,
              let type = object["type"]?.string else {
            throw WorkspaceClientError.invalidResponse
        }
        switch type {
        case "start":
            guard Set(object.keys) == Set(["type", "sample_rate", "channels"]),
                  let rawRate = object["sample_rate"]?.number,
                  let rawChannels = object["channels"]?.number,
                  rawRate.isFinite, rawChannels.isFinite,
                  rawRate.rounded() == rawRate, rawChannels.rounded() == rawChannels,
                  rawRate >= 8_000, rawRate <= 96_000,
                  rawChannels == 1 else {
                throw WorkspaceClientError.invalidResponse
            }
            return .start(sampleRate: Int(rawRate), channels: Int(rawChannels))
        case "fallback":
            guard Set(object.keys) == Set(["type"]) else {
                throw WorkspaceClientError.invalidResponse
            }
            return .fallback
        case "end":
            guard Set(object.keys) == Set(["type"]) else {
                throw WorkspaceClientError.invalidResponse
            }
            return .end
        default:
            throw WorkspaceClientError.invalidResponse
        }
    }
}

/// A short, bounded schedule over AVAudioEngine. It accepts little-endian,
/// interleaved Int16 PCM, converts into native non-interleaved buffers, and
/// never retains more than six seconds of not-yet-played audio.
@MainActor
final class DirectHermesPCMStreamingPlayer {
    private static let maximumBufferedSeconds = 6
    private static let maximumFrameSeconds = 2

    let sampleRate: Int
    let channels: Int

    private let sessionCoordinator: VoiceAudioSessionCoordinator
    private let operationID: UUID
    private let onPlayback: @MainActor (VoicePlaybackEvent) -> Void
    private var sessionClaim: VoiceAudioSessionClaim?
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var queuedBytes = 0
    private var startedPlayback = false
    private var isStopped = false

    init(
        sessionCoordinator: VoiceAudioSessionCoordinator,
        operationID: UUID,
        sampleRate: Int,
        channels: Int,
        onPlayback: @escaping @MainActor (VoicePlaybackEvent) -> Void
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.operationID = operationID
        self.sampleRate = sampleRate
        self.channels = channels
        self.onPlayback = onPlayback
    }

    func start() throws {
        guard (8_000...96_000).contains(sampleRate), (1...2).contains(channels),
              let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(sampleRate),
                channels: AVAudioChannelCount(channels),
                interleaved: false
              ) else {
            throw WorkspaceClientError.invalidResponse
        }
        let claim = try sessionCoordinator.acquire()
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        do {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            node.play()
        } catch {
            claim.release()
            engine.stop()
            throw error
        }
        sessionClaim = claim
        self.engine = engine
        self.node = node
        self.format = format
    }

    func schedule(_ data: Data) async throws {
        guard !isStopped, let format, let node, !data.isEmpty else {
            throw WorkspaceClientError.ownerChanged
        }
        let bytesPerFrame = channels * MemoryLayout<Int16>.size
        guard data.count.isMultiple(of: bytesPerFrame) else {
            throw WorkspaceClientError.invalidResponse
        }
        let frameCount = data.count / bytesPerFrame
        guard frameCount > 0,
              frameCount <= sampleRate * Self.maximumFrameSeconds,
              frameCount <= Int(UInt32.max) else {
            throw WorkspaceClientError.capacityExceeded
        }
        let maximumQueuedBytes = sampleRate * channels * MemoryLayout<Int16>.size
            * Self.maximumBufferedSeconds
        let capacityClock = ContinuousClock()
        let capacityDeadline = capacityClock.now.advanced(by: .seconds(8))
        while queuedBytes > maximumQueuedBytes - data.count {
            try Task.checkCancellation()
            guard !isStopped else { throw WorkspaceClientError.ownerChanged }
            guard capacityClock.now < capacityDeadline else {
                throw DirectHermesError.timedOut(outcomeUnknown: false)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let channelData = buffer.int16ChannelData else {
            throw WorkspaceClientError.invalidResponse
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        var squareSum = 0.0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let source = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    let offset = (frame * channels + channel) * MemoryLayout<Int16>.size
                    let bits = UInt16(source[offset]) | UInt16(source[offset + 1]) << 8
                    let sample = Int16(bitPattern: bits)
                    channelData[channel][frame] = sample
                    let normalized = Double(sample) / 32_768
                    squareSum += normalized * normalized
                }
            }
        }
        queuedBytes += data.count
        let byteCount = data.count
        let id = operationID
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.didPlay(operationID: id, byteCount: byteCount)
            }
        }

        if !startedPlayback {
            startedPlayback = true
            onPlayback(.started)
        }
        let sampleCount = frameCount * channels
        let rms = sampleCount > 0 ? sqrt(squareSum / Double(sampleCount)) : 0
        onPlayback(.level(min(max(sqrt(rms), 0), 1)))
    }

    func finish() async throws {
        guard startedPlayback else { throw WorkspaceClientError.invalidResponse }
        let drainClock = ContinuousClock()
        let drainDeadline = drainClock.now.advanced(by: .seconds(8))
        while queuedBytes > 0 {
            try Task.checkCancellation()
            guard !isStopped else { throw WorkspaceClientError.ownerChanged }
            guard drainClock.now < drainDeadline else {
                throw DirectHermesError.timedOut(outcomeUnknown: false)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !isStopped else { throw WorkspaceClientError.ownerChanged }
        onPlayback(.finished)
        stop(notifyFailure: false)
    }

    func stop(notifyFailure: Bool) {
        guard !isStopped else { return }
        isStopped = true
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
        format = nil
        queuedBytes = 0
        if notifyFailure, startedPlayback { onPlayback(.failed) }
        sessionClaim?.release()
        sessionClaim = nil
    }

    private func didPlay(operationID: UUID, byteCount: Int) {
        guard !isStopped, self.operationID == operationID else { return }
        queuedBytes = max(0, queuedBytes - byteCount)
    }
}
