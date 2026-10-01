import SwiftUI
import UIKit

@MainActor
struct BighelpLinkPairingView: View {
    let store: BighelpLinkDeviceStore
    let permissionCenter: PermissionCenter
    let initialReference: BighelpLinkPairingReference?
    let allowsDismiss: Bool

    @State private var code = ""
    @State private var verificationCode = ""
    @State private var isScannerPresented = false
    @State private var didCopyInstallPrompt = false
    @State private var didConsumeInitialReference = false

    init(
        store: BighelpLinkDeviceStore,
        permissionCenter: PermissionCenter,
        initialReference: BighelpLinkPairingReference? = nil,
        allowsDismiss: Bool = true
    ) {
        self.store = store
        self.permissionCenter = permissionCenter
        self.initialReference = initialReference
        self.allowsDismiss = allowsDismiss
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space24) {
                introduction
                pairingContent
            }
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.vertical, BighelpTokens.space24)
        }
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Pair a Device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if allowsDismiss {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                        .bighelpToolbarText()
                }
            }
        }
        .sheet(isPresented: $isScannerPresented) {
            NavigationStack {
                BighelpLinkQRScannerView(permissionCenter: permissionCenter) { payload in
                    guard let reference = BighelpLinkPairingReference.fromQRPayload(payload) else {
                        code = ""
                        isScannerPresented = false
                        return
                    }
                    code = reference.code
                    isScannerPresented = false
                    Task { await store.completePairing(reference: reference) }
                }
            }
            .bighelpSheetSize(.standard)
        }
        .task(id: initialReference) {
            if initialReference != nil {
                await store.beginPairing()
            } else if store.pairingState == .idle {
                await store.beginPairing()
            } else if case .paired = store.pairingState {
                await store.beginPairing()
            }
            if let initialReference, !didConsumeInitialReference {
                didConsumeInitialReference = true
                await store.completePairing(reference: initialReference)
            }
        }
        .accessibilityIdentifier("link.pairing")
    }

    private var introduction: some View {
        BighelpCard {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(theme.action)
                    .accessibilityHidden(true)
                Text("Connect with bighelp Link")
                    .bighelpFont(.screenTitle)
                    .foregroundStyle(theme.primaryText)
                Text("Scan the short-lived QR code shown by your Hermes host, or enter its six-character pairing code and verification code. Never paste a reusable host credential here. Notification access is handled separately after the secure connection is ready.")
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                    .overlay(theme.border)
                Text("Need to set up the Hermes host?")
                    .bighelpFont(.body, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                Text("Copy a ready-to-send prompt that first asks whether you want bighelp’s managed relay or a self-hosted relay, then installs the current plugin and starts pairing.")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    UIPasteboard.general.string = BighelpLinkInstallPrompt.text
                    didCopyInstallPrompt = true
                } label: {
                    Label(
                        didCopyInstallPrompt ? "Prompt Copied" : "Copy Setup Prompt",
                        systemImage: didCopyInstallPrompt ? "checkmark" : "doc.on.doc"
                    )
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                }
                .buttonStyle(.bordered)
                .tint(didCopyInstallPrompt ? theme.success : theme.action)
                .accessibilityIdentifier("link.pairing.copy-prompt")
            }
        }
    }

    @ViewBuilder
    private var pairingContent: some View {
        switch store.pairingState {
        case .idle, .requesting:
            HStack(spacing: BighelpTokens.space12) {
                BighelpThinkingOrb(scenario: .connecting, scale: .inline)
                Text("Starting a secure pairing session…")
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)

        case .ready(let challenge):
            entryForm(challenge: challenge)

        case .pairing:
            HStack(spacing: BighelpTokens.space12) {
                BighelpThinkingOrb(scenario: .connecting, scale: .inline)
                Text("Confirming with bighelp Link…")
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)

        case .paired(let deviceID):
            pairedConfirmation(deviceID: deviceID)

        case .expired:
            recoverableState(
                title: "Pairing code expired",
                message: "Start a new pairing session and use the new code shown by your Hermes host."
            )

        case .failed(let message):
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .bighelpFont(.body)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if store.pairingState != .failed("Enter the six-character pairing code.") {
                    Button("Start New Pairing Session") {
                        Task { await store.beginPairing() }
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: BighelpTokens.hitTarget)
                } else {
                    entryForm(challenge: nil)
                }
            }
        }
    }

    private func entryForm(challenge: BighelpLinkPairingChallenge?) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            Button {
                isScannerPresented = true
            } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.controlHeight)
            }
            .bighelpProminentButtonStyle()
            .tint(theme.action)
            .accessibilityIdentifier("link.pairing.scan")

            HStack(spacing: BighelpTokens.space12) {
                Rectangle().fill(theme.border).frame(height: BighelpTokens.hairline)
                Text("or enter the code")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize()
                Rectangle().fill(theme.border).frame(height: BighelpTokens.hairline)
            }

            TextField("ABC 123", text: $code)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .bighelpFont(.code, weight: .semibold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, BighelpTokens.space16)
                .frame(minHeight: BighelpTokens.controlHeight)
                .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius12))
                .overlay {
                    RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                        .stroke(theme.border, lineWidth: BighelpTokens.hairline)
                }
                .onSubmit(completePairing)
                .accessibilityIdentifier("link.pairing.code")

            TextField("1234 5678 9ABC DEF0", text: $verificationCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .bighelpFont(.code, weight: .semibold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, BighelpTokens.space16)
                .frame(minHeight: BighelpTokens.controlHeight)
                .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius12))
                .overlay {
                    RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                        .stroke(theme.border, lineWidth: BighelpTokens.hairline)
                }
                .onSubmit(completePairing)
                .accessibilityLabel("Host verification code")
                .accessibilityIdentifier("link.pairing.verification-code")

            Text("Match this 16-character code to the one shown by your Hermes host. It prevents the relay from substituting another host’s keys.")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button("Pair with bighelp Link", action: completePairing)
                .bighelpProminentButtonStyle()
                .tint(theme.action)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.controlHeight)
                .disabled(store.pairingState == .pairing)
                .accessibilityIdentifier("link.pairing.submit")

            if let challenge {
                ForEach(BighelpLinkPairingPresentation(challenge: challenge).details, id: \.self) {
                    Text($0)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.tertiaryText)
                }
            }
        }
    }

    private func pairedConfirmation(deviceID: String) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            Label("Paired securely", systemImage: "checkmark.seal.fill")
                .bighelpFont(.sectionTitle)
                .foregroundStyle(theme.success)
            Text(store.device(id: deviceID)?.name ?? "Your Hermes host")
                .bighelpFont(.screenTitle)
                .foregroundStyle(theme.primaryText)
            Text("This host is now authorized for your bighelp account. bighelp will explain notification and optional location access after the live connection is ready.")
                .bighelpFont(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if allowsDismiss {
                Button("Finish") { dismiss() }
                    .bighelpProminentButtonStyle()
                    .tint(theme.action)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.controlHeight)
            } else {
                HStack(spacing: BighelpTokens.space12) {
                    BighelpThinkingOrb(scenario: .connecting, scale: .inline)
                    Text("Validating the live connection…")
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: BighelpTokens.controlHeight,
                    alignment: .leading
                )
            }
        }
        .accessibilityIdentifier("link.pairing.success")
    }

    private func recoverableState(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            Label(title, systemImage: "clock.badge.exclamationmark")
                .bighelpFont(.sectionTitle)
                .foregroundStyle(theme.warning)
            Text(message)
                .bighelpFont(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Start New Pairing Session") {
                Task { await store.beginPairing() }
            }
            .bighelpProminentButtonStyle()
            .tint(theme.action)
            .frame(minHeight: BighelpTokens.hitTarget)
        }
    }

    private func completePairing() {
        Task {
            await store.completePairing(
                code: code,
                verificationCode: verificationCode
            )
        }
    }

    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme
}
