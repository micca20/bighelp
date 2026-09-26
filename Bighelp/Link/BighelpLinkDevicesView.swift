import Foundation
import SwiftUI

@MainActor
struct BighelpLinkDevicesView: View {
    let store: BighelpLinkDeviceStore
    let onOpenDevice: (BighelpLinkDevice) -> Void
    let onPairDevice: () -> Void
    @Environment(\.bighelpHostRegistry) private var hostRegistry

    var body: some View {
        Group {
            if hostRegistry?.isAccountReady == true {
                deviceList
            } else {
            switch store.loadState {
            case .idle where store.devices.isEmpty,
                 .loading where store.devices.isEmpty:
                BighelpThinkingOrb(
                    scenario: .searching,
                    visibleLabel: "Loading paired devices…"
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("link.devices.loading")
            case .failed where store.devices.isEmpty:
                ContentUnavailableView {
                    Label("Devices unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(store.loadError ?? "Paired devices could not be loaded.")
                } actions: {
                    Button("Try Again") { Task { await store.load() } }
                        .bighelpProminentButtonStyle()
                }
                .accessibilityIdentifier("link.devices.failure")
            default:
                deviceList
            }
            }
        }
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Hosts & Devices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Add", systemImage: "plus") {
                    if let hostRegistry, hostRegistry.isAccountReady {
                        Button("Add Host") { hostRegistry.beginSetup() }
                            .accessibilityIdentifier("hosts.add-host.toolbar")
                    }
                    Button("Pair a Link device", action: onPairDevice)
                }
                .accessibilityIdentifier("link.pair-device")
            }
        }
        .task {
            if store.loadState == .idle {
                await store.load()
            }
        }
        .accessibilityIdentifier("link.devices")
    }

    private var deviceList: some View {
        let sections = BighelpLinkDeviceSections(devices: store.devices)
        return List {
            if let hostRegistry, hostRegistry.isAccountReady { BighelpConfiguredHostsSection(registry: hostRegistry) }
            if store.loadState == .failed {
                Section { Text("Link devices could not be refreshed. Configured native hosts remain available.") }
            }
            if !sections.hosts.isEmpty {
                Section("Hosts") {
                    ForEach(sections.hosts) { device in
                        deviceRow(device)
                    }
                }
            }

            if !sections.connectedDevices.isEmpty {
                Section("Connected Devices") {
                    ForEach(sections.connectedDevices) { device in
                        deviceRow(device)
                    }
                }
            }

            if store.devices.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No paired devices",
                        systemImage: "link.badge.plus",
                        description: Text("Pair this iPhone with a Hermes host to begin using bighelp Link.")
                    )
                }
            }

            Section {
                Button(action: onPairDevice) {
                    Label("Pair a Device", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                }
                .accessibilityIdentifier("link.pair-device.list")
            } footer: {
                Text("Pairing authorizes this bighelp account and automatically sets up notifications for this Apple device when iOS permission is granted.")
                    .bighelpFont(.metadata)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await store.load() }
    }

    private func deviceRow(_ device: BighelpLinkDevice) -> some View {
        let presentation = BighelpLinkDevicePresentation(device: device)
        let authority = device.kind == .hermesHost
            ? BighelpLinkHostAuthorityPresentation(
                hostID: device.id,
                selectedHostID: store.selectedHostID,
                primaryHostID: store.primaryHostID
            )
            : nil
        return Button {
            onOpenDevice(device)
        } label: {
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: presentation.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.action)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .background(theme.action.opacity(0.1), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text(device.name)
                        .bighelpFont(.body, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(2)
                    Text(presentation.subtitle)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let authority {
                        ForEach(authority.statusLabels, id: \.self) { status in
                            Text(status)
                                .bighelpFont(.metadata, weight: .semibold)
                                .foregroundStyle(theme.action)
                        }
                    }
                    if let pushLabel = presentation.pushLabel {
                        Text(pushLabel)
                            .bighelpFont(.metadata)
                            .foregroundStyle(presentation.pushNeedsAttention ? theme.warning : theme.success)
                    }
                }
                Spacer(minLength: BighelpTokens.space8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ([presentation.accessibilityLabel] + (authority?.statusLabels ?? []))
                .joined(separator: ", ")
        )
        .accessibilityHint("Opens device details")
    }

    @BighelpThemeReader private var theme
}

/// A compact instance switcher for side panels and other persistent chrome.
/// Selecting an item switches the live host immediately through the caller's
/// existing `BighelpLinkDeviceStore.selectHost(_:)` contract. It never changes
/// the persisted primary-host preference.
@MainActor
struct BighelpLinkHostPicker: View {
    let hosts: [BighelpLinkDevice]
    let selectedHostID: String?
    let primaryHostID: String?
    let onSelectHost: (String) -> Void

    var body: some View {
        Section("Switch instance") {
            if hosts.isEmpty {
                Text("No hosts paired")
            } else {
                ForEach(hosts) { host in
                    Button {
                        onSelectHost(host.id)
                    } label: {
                        let status = BighelpLinkHostAuthorityPresentation(
                            hostID: host.id, selectedHostID: selectedHostID, primaryHostID: primaryHostID
                        ).statusLabels
                        Label(
                            ([host.name] + status).joined(separator: " · "),
                            systemImage: host.id == selectedHostID ? "checkmark" : "server.rack"
                        )
                    }
                    .accessibilityIdentifier("link.host-picker.\(host.id)")
                }
            }
        }
    }

}

struct BighelpLinkHostAuthorityPresentation: Equatable, Sendable {
    let hostID: String
    let selectedHostID: String?
    let primaryHostID: String?

    var isSelected: Bool { selectedHostID == hostID }
    var isPrimary: Bool { primaryHostID == hostID }
    var canSelect: Bool { !isSelected }
    var canSetPrimary: Bool { !isPrimary }

    var statusLabels: [String] {
        var labels: [String] = []
        if isSelected { labels.append("Selected instance") }
        if isPrimary { labels.append("Primary") }
        return labels
    }
}

struct BighelpLinkDevicePresentation {
    let device: BighelpLinkDevice

    var systemImage: String {
        switch device.kind {
        case .phone: "iphone"
        case .tablet: "ipad"
        case .computer: "laptopcomputer"
        case .hermesHost: "server.rack"
        }
    }

    var kindTitle: String {
        switch device.kind {
        case .phone: "iPhone"
        case .tablet: "iPad"
        case .computer: "Computer"
        case .hermesHost: "Hermes host"
        }
    }

    var connectionTitle: String {
        switch device.connection {
        case .online: "Online"
        case .recent: "Recently connected"
        case .offline: "Offline"
        }
    }

    var subtitle: String {
        [kindTitle, connectionTitle, lastSeenLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var lastSeenLabel: String? {
        guard device.connection != .online, let lastSeenAt = device.lastSeenAt else { return nil }
        let seconds = max(0, Date().timeIntervalSince(lastSeenAt))
        if seconds < 60 { return "Seen just now" }
        if seconds < 3_600 { return "Seen \(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "Seen \(Int(seconds / 3_600))h ago" }
        return "Seen \(Int(seconds / 86_400))d ago"
    }

    var pushLabel: String? {
        guard let pushState = device.pushState else { return nil }
        return switch pushState {
        case .permissionRequired: "Notifications need setup"
        case .registering: "Setting up notifications"
        case .ready: "Notifications ready"
        case .denied: "Notifications off"
        case .retrying: "Retrying notification setup"
        case .unavailable: "Notifications unavailable"
        case .revoked: "Notification access revoked"
        }
    }

    var pushNeedsAttention: Bool {
        switch device.pushState {
        case .permissionRequired, .denied, .retrying, .unavailable, .revoked: true
        case .registering, .ready, nil: false
        }
    }

    var accessibilityLabel: String {
        [device.name, kindTitle, connectionTitle, lastSeenLabel, pushLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
