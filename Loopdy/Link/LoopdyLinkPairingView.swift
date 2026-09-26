import SwiftUI
import UIKit

@MainActor
struct LoopdyLinkPairingView: View {
    let store: LoopdyLinkDeviceStore
    let permissionCenter: PermissionCenter
    let initialReference: LoopdyLinkPairingReference?
    let allowsDismiss: Bool

    @State private var code = ""
    @State private var verificationCode = ""
    @State private var isScannerPresented = false
    @State private var didCopyInstallPrompt = false
    @State private var didConsumeInitialReference = false

    init(
        store: LoopdyLinkDeviceStore,
        permissionCenter: PermissionCenter,
        initialReference: LoopdyLinkPairingReference? = nil,
        allowsDismiss: Bool = true
    ) {
        self.store = store
        self.permissionCenter = permissionCenter
        self.initialReference = initialReference
        self.allowsDismiss = allowsDismiss
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LoopdyTokens.space24) {
                introduction
                pairingContent
            }
            .padding(.horizontal, LoopdyTokens.space20)
            .padding(.vertical, LoopdyTokens.space24)
        }
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Pair a Device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if allowsDismiss {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $isScannerPresented) {
            NavigationStack {
                LoopdyLinkQRScannerView(permissionCenter: permissionCenter) { payload in
                    guard let reference = LoopdyLinkPairingReference.fromQRPayload(payload) else {
                        code = ""
                        isScannerPresented = false
                        return
                    }
                    code = reference.code
                    isScannerPresented = false
                    Task { await store.completePairing(reference: reference) }
                }
            }
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
        LoopdyCard {
            VStack(alignment: .leading, spacing: LoopdyTokens.space12) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(theme.action)
                    .accessibilityHidden(true)
                Text("Connect with Loopdy Link")
                    .loopdyFont(.screenTitle)
                    .foregroundStyle(theme.primaryText)
                Text("Scan the short-lived QR code shown by your Hermes host, or enter its six-character pairing code and verification code. Never paste a reusable host credential here. Notification access is handled separately after the secure connection is ready.")
                    .loopdyFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                    .overlay(theme.border)
                Text("Need to set up the Hermes host?")
                    .loopdyFont(.body, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                Text("Copy a ready-to-send prompt that first asks whether you want bighelp’s managed relay or a self-hosted relay, then installs the current plugin and starts pairing.")
                    .loopdyFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    UIPasteboard.general.string = LoopdyLinkInstallPrompt.text
                    didCopyInstallPrompt = true
                } label: {
                    Label(
                        didCopyInstallPrompt ? "Prompt Copied" : "Copy Setup Prompt",
                        systemImage: didCopyInstallPrompt ? "checkmark" : "doc.on.doc"
                    )
                    .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
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
            HStack(spacing: LoopdyTokens.space12) {
                LoopdyThinkingOrb(scenario: .connecting, scale: .inline)
                Text("Starting a secure pairing session…")
                    .loopdyFont(.body)
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget, alignment: .leading)

        case .ready(let challenge):
            entryForm(challenge: challenge)

        case .pairing:
            HStack(spacing: LoopdyTokens.space12) {
                LoopdyThinkingOrb(scenario: .connecting, scale: .inline)
                Text("Confirming with Loopdy Link…")
                    .loopdyFont(.body)
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget, alignment: .leading)

        case .paired(let deviceID):
            pairedConfirmation(deviceID: deviceID)

        case .expired:
            recoverableState(
                title: "Pairing code expired",
                message: "Start a new pairing session and use the new code shown by your Hermes host."
            )

        case .failed(let message):
            VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .loopdyFont(.body)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if store.pairingState != .failed("Enter the six-character pairing code.") {
                    Button("Start New Pairing Session") {
                        Task { await store.beginPairing() }
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: LoopdyTokens.hitTarget)
                } else {
                    entryForm(challenge: nil)
                }
            }
        }
    }

    private func entryForm(challenge: LoopdyLinkPairingChallenge?) -> some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
            Button {
                isScannerPresented = true
            } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity, minHeight: LoopdyTokens.controlHeight)
            }
            .loopdyProminentButtonStyle()
            .tint(theme.action)
            .accessibilityIdentifier("link.pairing.scan")

            HStack(spacing: LoopdyTokens.space12) {
                Rectangle().fill(theme.border).frame(height: LoopdyTokens.hairline)
                Text("or enter the code")
                    .loopdyFont(.metadata)
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize()
                Rectangle().fill(theme.border).frame(height: LoopdyTokens.hairline)
            }

            TextField("ABC 123", text: $code)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .loopdyFont(.code, weight: .semibold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, LoopdyTokens.space16)
                .frame(minHeight: LoopdyTokens.controlHeight)
                .background(theme.surface, in: .rect(cornerRadius: LoopdyTokens.radius12))
                .overlay {
                    RoundedRectangle(cornerRadius: LoopdyTokens.radius12)
                        .stroke(theme.border, lineWidth: LoopdyTokens.hairline)
                }
                .onSubmit(completePairing)
                .accessibilityIdentifier("link.pairing.code")

            TextField("1234 5678 9ABC DEF0", text: $verificationCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .loopdyFont(.code, weight: .semibold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, LoopdyTokens.space16)
                .frame(minHeight: LoopdyTokens.controlHeight)
                .background(theme.surface, in: .rect(cornerRadius: LoopdyTokens.radius12))
                .overlay {
                    RoundedRectangle(cornerRadius: LoopdyTokens.radius12)
                        .stroke(theme.border, lineWidth: LoopdyTokens.hairline)
                }
                .onSubmit(completePairing)
                .accessibilityLabel("Host verification code")
                .accessibilityIdentifier("link.pairing.verification-code")

            Text("Match this 16-character code to the one shown by your Hermes host. It prevents the relay from substituting another host’s keys.")
                .loopdyFont(.metadata)
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button("Pair with Loopdy Link", action: completePairing)
                .loopdyProminentButtonStyle()
                .tint(theme.action)
                .frame(maxWidth: .infinity, minHeight: LoopdyTokens.controlHeight)
                .disabled(store.pairingState == .pairing)
                .accessibilityIdentifier("link.pairing.submit")

            if let challenge {
                ForEach(LoopdyLinkPairingPresentation(challenge: challenge).details, id: \.self) {
                    Text($0)
                        .loopdyFont(.metadata)
                        .foregroundStyle(theme.tertiaryText)
                }
            }
        }
    }

    private func pairedConfirmation(deviceID: String) -> some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
            Label("Paired securely", systemImage: "checkmark.seal.fill")
                .loopdyFont(.sectionTitle)
                .foregroundStyle(theme.success)
            Text(store.device(id: deviceID)?.name ?? "Your Hermes host")
                .loopdyFont(.screenTitle)
                .foregroundStyle(theme.primaryText)
            Text("This host is now authorized for your bighelp account. bighelp will explain notification and optional location access after the live connection is ready.")
                .loopdyFont(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if allowsDismiss {
                Button("Finish") { dismiss() }
                    .loopdyProminentButtonStyle()
                    .tint(theme.action)
                    .frame(maxWidth: .infinity, minHeight: LoopdyTokens.controlHeight)
            } else {
                HStack(spacing: LoopdyTokens.space12) {
                    LoopdyThinkingOrb(scenario: .connecting, scale: .inline)
                    Text("Validating the live connection…")
                        .loopdyFont(.body)
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: LoopdyTokens.controlHeight,
                    alignment: .leading
                )
            }
        }
        .accessibilityIdentifier("link.pairing.success")
    }

    private func recoverableState(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space16) {
            Label(title, systemImage: "clock.badge.exclamationmark")
                .loopdyFont(.sectionTitle)
                .foregroundStyle(theme.warning)
            Text(message)
                .loopdyFont(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Start New Pairing Session") {
                Task { await store.beginPairing() }
            }
            .loopdyProminentButtonStyle()
            .tint(theme.action)
            .frame(minHeight: LoopdyTokens.hitTarget)
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
    @LoopdyThemeReader private var theme
}
