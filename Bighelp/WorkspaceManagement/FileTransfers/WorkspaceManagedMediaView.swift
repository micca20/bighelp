import AVKit
import SwiftUI

@MainActor
struct WorkspaceManagedMediaView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var playback: DirectHermesManagedMediaPlayback

    init(playback: DirectHermesManagedMediaPlayback) {
        _playback = State(initialValue: playback)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    mediaSurface
                }
                .listRowBackground(Color.clear)
                .listRowInsets(.init())

                Section("Now playing") {
                    LabeledContent("File", value: playback.file.name)
                    if let mimeType = playback.file.mimeType {
                        LabeledContent("Type", value: mimeType)
                    }
                    if let byteCount = playback.file.byteCount {
                        LabeledContent(
                            "Size",
                            value: ByteCountFormatter.string(
                                fromByteCount: Int64(byteCount),
                                countStyle: .file
                            )
                        )
                    }
                    LabeledContent("Playback", value: "Workspace streaming")
                }

                if let errorMessage = playback.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(playback.isVideo ? "Video Preview" : "Audio Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
        .task { await playback.start() }
        .task { await playback.monitorOwnership() }
        .onDisappear { playback.retire() }
        .accessibilityIdentifier("workspace.managed-media")
    }

    @ViewBuilder
    private var mediaSurface: some View {
        if playback.isReady {
            VideoPlayer(player: playback.player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(.black)
                .accessibilityLabel(playback.isVideo ? "Video preview" : "Audio player")
                .accessibilityIdentifier("workspace.managed-media.player")
        } else if playback.isPreparing {
            VStack(spacing: BighelpTokens.space12) {
                ProgressView()
                Text("Preparing secure playback…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            ContentUnavailableView(
                "Playback unavailable",
                systemImage: playback.isVideo ? "film" : "waveform",
                description: Text(playback.errorMessage ?? "This file is not ready to play.")
            )
            .frame(minHeight: 220)
        }
    }
}
