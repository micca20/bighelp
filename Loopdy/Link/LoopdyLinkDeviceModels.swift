import Foundation

enum LoopdyLinkDeviceKind: String, Codable, CaseIterable, Sendable {
    case phone
    case tablet
    case computer
    case hermesHost
}

enum LoopdyLinkConnectionState: String, Codable, Sendable {
    case online
    case recent
    case offline
}

enum LoopdyLinkPushState: String, Codable, Sendable {
    case permissionRequired
    case registering
    case ready
    case denied
    case retrying
    case unavailable
    case revoked
}

struct LoopdyLinkDevice: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    let kind: LoopdyLinkDeviceKind
    let isCurrentDevice: Bool
    var connection: LoopdyLinkConnectionState
    /// Legacy catalog compatibility only. Production decoding accepts only nil.
    var pushState: LoopdyLinkPushState?
    /// Legacy catalog compatibility only. Production decoding accepts only zero.
    var pushRevision: Int
    var lastSeenAt: Date?
    var revision: Int
    /// Server authorization epoch; nil in older cached records. Never infer from revision.
    var authorizationEpoch: Int?

    init(
        id: String,
        name: String,
        kind: LoopdyLinkDeviceKind,
        isCurrentDevice: Bool,
        connection: LoopdyLinkConnectionState,
        pushState: LoopdyLinkPushState?,
        pushRevision: Int = 0,
        lastSeenAt: Date?,
        revision: Int,
        authorizationEpoch: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isCurrentDevice = isCurrentDevice
        self.connection = connection
        self.pushState = pushState
        self.pushRevision = pushRevision
        self.lastSeenAt = lastSeenAt
        self.revision = revision
        self.authorizationEpoch = authorizationEpoch
    }
}

struct LoopdyLinkDeviceSummary: Equatable, Sendable {
    let title: String
    let detail: String
    let deviceCountText: String
    let accessibilitySummary: String

    init(devices: [LoopdyLinkDevice]) {
        deviceCountText = switch devices.count {
        case 0: "No paired devices"
        case 1: "1 paired device"
        default: "\(devices.count) paired devices"
        }

        if devices.isEmpty {
            title = "Not paired"
            detail = "Pair this device with Loopdy Link to get started."
        } else if devices.contains(where: { $0.connection == .online }) {
            title = "Connected"
            detail = "Loopdy Link is ready."
        } else {
            title = "Offline"
            detail = "Your paired devices are currently offline."
        }

        let deviceStatuses = devices.map { device in
            "\(device.name), \(device.connection.accessibilityLabel)"
        }.joined(separator: "; ")
        accessibilitySummary = [title, deviceCountText, detail, deviceStatuses]
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }
}

struct LoopdyLinkDeviceSections: Equatable, Sendable {
    let connectedDevices: [LoopdyLinkDevice]
    let hosts: [LoopdyLinkDevice]

    init(devices: [LoopdyLinkDevice]) {
        connectedDevices = devices.filter(\.isCurrentDevice)
            + devices.filter { !$0.isCurrentDevice && $0.kind != .hermesHost }
        hosts = devices.filter { $0.kind == .hermesHost }
    }
}

private extension LoopdyLinkConnectionState {
    var accessibilityLabel: String {
        switch self {
        case .online: "online"
        case .recent: "recently connected"
        case .offline: "offline"
        }
    }
}


enum LoopdyLinkLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed
}

enum LoopdyLinkPendingAction: Equatable, Sendable {
    case rename(deviceID: String)
    case unpair(deviceID: String)
}

@MainActor
protocol LoopdyLinkDeviceClient: AnyObject {
    func listDevices() async throws -> [LoopdyLinkDevice]
    func renameDevice(
        id: String,
        name: String,
        expectedRevision: Int
    ) async throws -> LoopdyLinkDevice
    func unpairDevice(id: String, expectedRevision: Int) async throws
    func beginPairing() async throws -> LoopdyLinkPairingChallenge
    func completePairing(
        reference: LoopdyLinkPairingReference
    ) async throws -> LoopdyLinkDevice
}
