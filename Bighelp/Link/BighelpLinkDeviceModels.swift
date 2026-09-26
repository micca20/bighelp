import Foundation

enum BighelpLinkDeviceKind: String, Codable, CaseIterable, Sendable {
    case phone
    case tablet
    case computer
    case hermesHost
}

enum BighelpLinkConnectionState: String, Codable, Sendable {
    case online
    case recent
    case offline
}

enum BighelpLinkPushState: String, Codable, Sendable {
    case permissionRequired
    case registering
    case ready
    case denied
    case retrying
    case unavailable
    case revoked
}

struct BighelpLinkDevice: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    let kind: BighelpLinkDeviceKind
    let isCurrentDevice: Bool
    var connection: BighelpLinkConnectionState
    /// Legacy catalog compatibility only. Production decoding accepts only nil.
    var pushState: BighelpLinkPushState?
    /// Legacy catalog compatibility only. Production decoding accepts only zero.
    var pushRevision: Int
    var lastSeenAt: Date?
    var revision: Int
    /// Server authorization epoch; nil in older cached records. Never infer from revision.
    var authorizationEpoch: Int?

    init(
        id: String,
        name: String,
        kind: BighelpLinkDeviceKind,
        isCurrentDevice: Bool,
        connection: BighelpLinkConnectionState,
        pushState: BighelpLinkPushState?,
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

struct BighelpLinkDeviceSummary: Equatable, Sendable {
    let title: String
    let detail: String
    let deviceCountText: String
    let accessibilitySummary: String

    init(devices: [BighelpLinkDevice]) {
        deviceCountText = switch devices.count {
        case 0: "No paired devices"
        case 1: "1 paired device"
        default: "\(devices.count) paired devices"
        }

        if devices.isEmpty {
            title = "Not paired"
            detail = "Pair this device with bighelp Link to get started."
        } else if devices.contains(where: { $0.connection == .online }) {
            title = "Connected"
            detail = "bighelp Link is ready."
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

struct BighelpLinkDeviceSections: Equatable, Sendable {
    let connectedDevices: [BighelpLinkDevice]
    let hosts: [BighelpLinkDevice]

    init(devices: [BighelpLinkDevice]) {
        connectedDevices = devices.filter(\.isCurrentDevice)
            + devices.filter { !$0.isCurrentDevice && $0.kind != .hermesHost }
        hosts = devices.filter { $0.kind == .hermesHost }
    }
}

private extension BighelpLinkConnectionState {
    var accessibilityLabel: String {
        switch self {
        case .online: "online"
        case .recent: "recently connected"
        case .offline: "offline"
        }
    }
}


enum BighelpLinkLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed
}

enum BighelpLinkPendingAction: Equatable, Sendable {
    case rename(deviceID: String)
    case unpair(deviceID: String)
}

@MainActor
protocol BighelpLinkDeviceClient: AnyObject {
    func listDevices() async throws -> [BighelpLinkDevice]
    func renameDevice(
        id: String,
        name: String,
        expectedRevision: Int
    ) async throws -> BighelpLinkDevice
    func unpairDevice(id: String, expectedRevision: Int) async throws
    func beginPairing() async throws -> BighelpLinkPairingChallenge
    func completePairing(
        reference: BighelpLinkPairingReference
    ) async throws -> BighelpLinkDevice
}
