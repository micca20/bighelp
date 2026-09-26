import Foundation
import Observation
import WatchConnectivity
import WatchKit

private struct WatchPendingAction: Codable, Equatable {
    let id: UUID
    let authorityID: UUID
    let targetID: String
    let startedAt: Date
    let isVoice: Bool
}

private struct WatchRecoveryState: Codable {
    var revision: UInt64 = 0
    var authorityID: UUID?
    var pending: WatchPendingAction?
    var retiredAuthorities: [UUID] = []
    var lastReceipt: WatchCompanionReceipt?
}

@MainActor
@Observable
final class WatchCompanionStore: NSObject {
    private(set) var state: WatchCompanionState?
    private(set) var isReachable = false
    private(set) var isActivated = false
    private(set) var companionInstalled = false
    private(set) var isRefreshing = false
    private(set) var isWaiting = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var lastReceipt: WatchCompanionReceipt?
    private(set) var voiceResponse: WatchVoiceResult?
    private(set) var voiceSessionID: String?
    private(set) var clock = Date()
    var voiceDraft = ""
    private(set) var draftSessionID: String?
    private(set) var isDictating = false
    let speech = WatchReplySpeech()

    private let session: WCSession
    private var recovery = WatchRecoveryState()
    private var storageAvailable = true
    private var refreshID: UUID?
    private var timeoutTask: Task<Void, Never>?
    private var refreshTimeout: Task<Void, Never>?
    private var foregroundTask: Task<Void, Never>?
    private var isForeground = false
    private var dictationGeneration = UUID()

    init(session: WCSession = .default, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.session = session
        super.init()
        do {
            recovery = try WatchCompanionPersistence.load(WatchRecoveryState.self, name: "watch-recovery-v2") ?? WatchRecoveryState()
            if let receipt = recovery.lastReceipt, Date().timeIntervalSince(receipt.completedAt) < 86_400 {
                lastReceipt = receipt
                statusMessage = receipt.message
                voiceResponse = receipt.voice
                voiceSessionID = receipt.voice == nil ? nil : receipt.targetID
            } else { recovery.lastReceipt = nil }
            if recovery.pending != nil {
                statusMessage = "A previous request needs confirmation. Connect to iPhone to check its status."
            }
        } catch {
            storageAvailable = false
            errorMessage = "Request recovery storage is unavailable. Open Loopdy on iPhone."
        }
        // Legacy Watch Keychain credentials and pending enrollment keys remain untouched.
        // They are neither read nor used: there is no independent auth/network startup path.
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        } else { errorMessage = "This Watch cannot activate the iPhone companion connection." }
    }

    isolated deinit {
        timeoutTask?.cancel()
        refreshTimeout?.cancel()
        foregroundTask?.cancel()
    }

    var snapshot: WatchCompanionSnapshot {
        state?.content ?? WatchCompanionSnapshot(
            generatedAt: .distantPast, weather: nil, inbox: [], approvals: [],
            sessions: [], selectedSessionID: nil, transcript: []
        )
    }
    var hasPendingRequest: Bool { recovery.pending != nil }
    var pendingTargetID: String? { recovery.pending?.targetID }
    var isFresh: Bool {
        guard let state else { return false }
        let age = clock.timeIntervalSince(state.content.generatedAt)
        return age >= -30 && age < 120
    }
    var canSend: Bool {
        storageAvailable && isActivated && isReachable && isFresh
            && state?.phoneLink == .connected && !hasPendingRequest
    }
    var connectionLabel: String {
        if !isActivated { return "Connecting to iPhone" }
        if !companionInstalled { return "Install Loopdy on iPhone" }
        return isReachable ? "iPhone reachable" : "iPhone not reachable"
    }
    var phoneLinkLabel: String {
        guard isFresh else { return "Phone Link status is stale" }
        switch state?.phoneLink {
        case .connected: return "Phone Link connected"
        case .connecting: return "Phone Link reconnecting"
        case .signedOut: return "Sign in on iPhone"
        default: return "Open Loopdy on iPhone"
        }
    }

    func foreground(_ active: Bool) {
        isForeground = active
        foregroundTask?.cancel()
        if !active {
            cancelDictation()
            speech.stop()
            return
        }
        updateConnection()
        refresh()
        foregroundTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.updateConnection()
                self?.checkStatus()
                if self?.isFresh == false { self?.refresh() }
            }
        }
    }

    func refresh(reconnect: Bool = false) {
        updateConnection()
        guard isActivated else { session.activate(); statusMessage = "Activating the companion connection…"; return }
        guard isReachable else {
            statusMessage = "Open Loopdy on your paired iPhone. Cached items may be out of date."
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        let id = UUID()
        refreshID = id
        transmit(.refresh(id, reconnect: reconnect)) { [weak self] packet in
            guard let self, refreshID == id else { return }
            isRefreshing = false
            refreshTimeout?.cancel()
            if let packet { receive(packet, authoritativeRefresh: true) }
            else { errorMessage = "Could not refresh. Open Loopdy on iPhone, then reconnect." }
            checkStatus()
        }
        refreshTimeout?.cancel()
        refreshTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, refreshID == id else { return }
            isRefreshing = false
            refreshID = nil
            errorMessage = "iPhone did not answer. Reconnect when Loopdy is available."
        }
    }

    func submit(_ action: WatchCompanionAction, offeredState: WatchCompanionState? = nil) {
        clock = .now
        guard canSend, let state, let offer = offeredState ?? self.state,
              offer.authorityID == state.authorityID, offer.isFresh,
              (try? action.validate()) != nil else {
            errorMessage = "Not sent. Refresh Watch and check the connection on iPhone."
            return
        }
        let request = WatchCompanionActionRequest(
            id: UUID(), authorityID: state.authorityID, offerID: offer.offerID,
            createdAt: .now, action: action
        )
        let isVoice: Bool
        if case .voice = action { isVoice = true } else { isVoice = false }
        recovery.pending = WatchPendingAction(
            id: request.id, authorityID: state.authorityID, targetID: action.targetID,
            startedAt: .now, isVoice: isVoice
        )
        recovery.lastReceipt = nil
        do { try persist() } catch {
            recovery.pending = nil
            storageAvailable = false
            errorMessage = "Not sent. Watch could not save the request for recovery."
            return
        }
        lastReceipt = nil
        errorMessage = nil
        isWaiting = true
        statusMessage = "Sending to iPhone…"
        if isVoice { voiceResponse = nil; voiceSessionID = action.targetID; speech.stop() }
        transmit(.action(request)) { [weak self] packet in
            guard let self, recovery.pending?.id == request.id else { return }
            if let packet { receive(packet) }
            else { deliveryUncertain() }
        }
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(100))
            guard !Task.isCancelled, let self, recovery.pending?.id == request.id else { return }
            deliveryUncertain()
            checkStatus()
        }
    }

    /// This is cancellation of local waiting, NOT cancellation/rollback of a submitted remote action.
    func stopWaiting() {
        timeoutTask?.cancel()
        isWaiting = false
        speech.stop()
        statusMessage = "Stopped waiting. iPhone may still finish; check status before sending another request."
    }

    func checkStatus() {
        guard isActivated, isReachable, let pending = recovery.pending else { return }
        transmit(.status(requestID: pending.id, authorityID: pending.authorityID)) { [weak self] packet in
            guard let self, recovery.pending?.id == pending.id else { return }
            if let packet { receive(packet) }
        }
    }

    private func deliveryUncertain() {
        isWaiting = false
        statusMessage = "Confirmation is delayed. This request may have reached iPhone. Check status; do not send it again."
    }

    func clearNotice() { errorMessage = nil }

    func selectSession(_ id: String) {
        guard snapshot.selectedSessionID != id else { return }
        submit(.selectSession(id))
    }

    func prepareDraft(for id: String) {
        if draftSessionID != id { cancelDictation(); voiceDraft = "" }
        draftSessionID = id
    }

    func dictate(to id: String) {
        guard canSend, isForeground, !isDictating else { return }
        prepareDraft(for: id)
        guard let controller = WKExtension.shared().visibleInterfaceController else {
            errorMessage = "Dictation is not available here. Use the Reply text field or your iPhone."
            return
        }
        speech.stop()
        let generation = UUID()
        dictationGeneration = generation
        isDictating = true
        // The system input controller offers genuine Watch dictation/Scribble/keyboard.
        // Its privacy and language availability are controlled by watchOS. Review before Send.
        controller.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain,
            completion: WatchCompanionCallbacks.textInput { [weak self] text in
                guard let self, self.dictationGeneration == generation, self.draftSessionID == id else { return }
                self.isDictating = false
                guard let text else { return } // System Cancel has no side effect.
                guard text.utf8.count <= 10_000 else { self.errorMessage = "Please use a shorter reply."; return }
                self.voiceDraft = text
            })
    }

    func cancelDictation() {
        dictationGeneration = UUID()
        if isDictating { WKExtension.shared().visibleInterfaceController?.dismissTextInputController() }
        isDictating = false
    }

    func sendDraft(to id: String, offeredState: WatchCompanionState?) {
        guard draftSessionID == id else { return }
        let text = voiceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        submit(.voice(sessionID: id, text: text), offeredState: offeredState)
        // Keep the draft if submission never began; never automatically resubmit it.
        if hasPendingRequest { voiceDraft = "" }
    }

    func readReplyAloud() {
        guard isForeground, let voiceResponse else { return }
        if !speech.speak(voiceResponse.text) {
            errorMessage = "No system voice is available on this Watch. You can still read the reply."
        }
    }

    private func persist() throws { try WatchCompanionPersistence.save(recovery, name: "watch-recovery-v2") }

    private func updateConnection() {
        clock = .now
        isActivated = session.activationState == .activated
        isReachable = isActivated && session.isReachable
        companionInstalled = session.isCompanionAppInstalled
    }

    private func transmit(_ packet: WatchCompanionPacket, completion: @escaping @MainActor @Sendable (WatchCompanionPacket?) -> Void) {
        guard isActivated, isReachable, let encoded = try? WatchCompanionWire.encode(packet) else {
            completion(nil)
            return
        }
        session.sendMessage(encoded,
            replyHandler: WatchCompanionCallbacks.reply(completion),
            errorHandler: WatchCompanionCallbacks.failure(completion))
    }

    private func receive(_ packet: WatchCompanionPacket, authoritativeRefresh: Bool = false) {
        switch packet {
        case .snapshot(let incoming):
            let newPhone = authoritativeRefresh && incoming.authorityID != recovery.authorityID && incoming.isFresh
            guard !recovery.retiredAuthorities.contains(incoming.authorityID),
                  newPhone || (incoming.revision >= recovery.revision && (state == nil || incoming.revision > recovery.revision)),
                  incoming.content.generatedAt <= Date().addingTimeInterval(30) else { return }
            if let old = recovery.authorityID, old != incoming.authorityID {
                recovery.retiredAuthorities.append(old)
                recovery.retiredAuthorities = Array(recovery.retiredAuthorities.suffix(16))
                // Sign out, host switch or phone reset invalidates every old draft and action.
                recovery.pending = nil
                recovery.lastReceipt = nil
                lastReceipt = nil
                voiceResponse = nil
                voiceSessionID = nil
                voiceDraft = ""
                draftSessionID = nil
                cancelDictation()
                speech.stop()
                isWaiting = false
                timeoutTask?.cancel()
                statusMessage = "Phone connection changed. Review the latest items before acting."
            }
            state = incoming
            recovery.revision = incoming.revision
            recovery.authorityID = incoming.authorityID
            clock = .now
            do { try persist() } catch { storageAvailable = false }
        case .receipt(let receipt):
            guard let pending = recovery.pending,
                  receipt.id == pending.id, receipt.authorityID == pending.authorityID,
                  receipt.authorityID == recovery.authorityID,
                  receipt.targetID == pending.targetID || receipt.targetID == "unknown" else { return }
            lastReceipt = WatchCompanionReceipt(
                id: receipt.id, authorityID: receipt.authorityID, targetID: pending.targetID,
                phase: receipt.phase, message: receipt.message, completedAt: receipt.completedAt,
                voice: receipt.voice
            )
            statusMessage = receipt.message
            if receipt.phase == .pending { return }
            timeoutTask?.cancel()
            isWaiting = false
            if receipt.phase == .committed, pending.isVoice, let voice = receipt.voice {
                voiceResponse = voice
                voiceSessionID = pending.targetID
                // Never auto-play, especially on relaunch/background durable delivery.
            }
            recovery.pending = nil
            recovery.lastReceipt = lastReceipt
            do { try persist() } catch { storageAvailable = false }
            refresh()
        default: break
        }
    }
}

extension WatchCompanionStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
        let context = try? WatchCompanionWire.decode(session.receivedApplicationContext)
        let succeeded = error == nil && state == .activated
        Task { @MainActor [weak self] in
            guard let self else { return }
            updateConnection()
            if let context { receive(context) }
            if succeeded { refresh(); checkStatus() }
            else { errorMessage = "Watch connection could not activate. Open Loopdy on iPhone and reconnect." }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            updateConnection()
            if isReachable { refresh(); checkStatus() }
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        accept(applicationContext)
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) { accept(userInfo) }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { accept(message) }
    private nonisolated func accept(_ dictionary: [String: Any]) {
        guard let packet = try? WatchCompanionWire.decode(dictionary) else { return }
        Task { @MainActor [weak self] in self?.receive(packet) }
    }
}
