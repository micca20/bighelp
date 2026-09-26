import SwiftUI

@MainActor
struct VoiceConfigurationRecordingControls: View {
    @Bindable var controller: VoiceConfigurationRecordingController
    let canPrepareRecording: Bool
    let canTranscribe: Bool
    let onImport: () -> Void
    let onTranscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            status
            controls

            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("voice.configuration.recording-error")
            }

            let microphone = controller.permissionCenter.status(for: .microphone).authorization
            if microphone == .denied || microphone == .restricted {
                ContextualPermissionRecoveryView(
                    center: controller.permissionCenter,
                    kind: .microphone
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice.configuration.native-recording")
    }

    @ViewBuilder
    private var status: some View {
        switch controller.state {
        case .idle:
            Label("No recording prepared", systemImage: "waveform")
                .foregroundStyle(.secondary)
        case .requestingPermission:
            ProgressView("Requesting microphone access…")
        case .recording(let startedAt):
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = min(
                    VoiceConfigurationRecordingController.maximumDuration,
                    max(0, context.date.timeIntervalSince(startedAt))
                )
                Label(
                    "Recording · \(Int(elapsed.rounded(.down)))s of 120s",
                    systemImage: "record.circle.fill"
                )
                .foregroundStyle(.red)
                .accessibilityIdentifier("voice.configuration.recording-active")
            }
        case .importing:
            ProgressView("Validating audio…")
        case .finalized:
            Label(
                controller.finalizedSummary ?? "Audio ready",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("voice.configuration.recording-ready")
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch controller.state {
        case .recording:
            HStack {
                Button {
                    controller.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .bighelpProminentButtonStyle()
                .frame(minWidth: 96, minHeight: 44)
                .accessibilityIdentifier("voice.configuration.recording-stop")

                Spacer()

                Button("Cancel", role: .cancel) {
                    controller.cancel()
                }
                .frame(minWidth: 96, minHeight: 44)
                .accessibilityIdentifier("voice.configuration.recording-cancel")
            }
        case .requestingPermission, .importing:
            Button("Cancel", role: .cancel) {
                controller.cancel()
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("voice.configuration.recording-cancel")
        case .idle, .finalized:
            HStack {
                Button {
                    Task { await controller.startRecording() }
                } label: {
                    Label("Record", systemImage: "mic.fill")
                }
                .disabled(!canPrepareRecording)
                .frame(minWidth: 96, minHeight: 44)
                .accessibilityIdentifier("voice.configuration.recording-start")

                Spacer()

                Button {
                    onImport()
                } label: {
                    Label("Import Audio", systemImage: "folder")
                }
                .disabled(!canPrepareRecording)
                .frame(minHeight: 44)
                .accessibilityIdentifier("voice.configuration.recording-import")
            }

            if controller.hasFinalizedRecording {
                HStack {
                    Button {
                        onTranscribe()
                    } label: {
                        Label("Transcribe Recording", systemImage: "waveform.badge.mic")
                    }
                    .bighelpProminentButtonStyle()
                    .disabled(!canTranscribe)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("voice.configuration.transcribe")

                    Spacer()

                    Button("Discard", role: .destructive) {
                        controller.cancel()
                    }
                    .disabled(!canPrepareRecording)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("voice.configuration.recording-discard")
                }
            }
        }
    }
}
