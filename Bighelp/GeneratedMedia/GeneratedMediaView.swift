import AVFoundation
import AVKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct GeneratedMediaCard: View {
    let event: ChatActivityEvent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var statusIconSize = 24.0

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            if event.generatedMedia?.shownInReply != true {
                GeometryReader { geometry in
                    content
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .clipped()
            }
            // The picture speaks for itself, and the loader carries its own
            // words; the line explains only a problem, or a picture shown in
            // the reply instead. Keeping it out of the loader and the finished
            // picture alike means the card never changes height as it lands.
            if showsStatusLine {
                HStack(spacing: BighelpTokens.space8) {
                    Image(systemName: statusSymbol)
                        .frame(width: statusIconSize, height: statusIconSize)
                        .accessibilityHidden(true)
                    Text(statusLabel)
                        .bighelpFont(.body, weight: .semibold)
                        .foregroundStyle(.primary)
                    Spacer(minLength: BighelpTokens.space8)
                    Text(kind == .image ? "Image" : "Video")
                        .bighelpFont(.metadata, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(statusColor)
            }
            if event.generatedMedia?.omittedCount ?? 0 > 0,
               event.generatedMedia?.state == .ready {
                Text("Some generated media could not be displayed on this device.")
                    .bighelpFont(.metadata)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(BighelpTokens.space12)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: BighelpTokens.radius16))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                .stroke(Color(uiColor: .separator), lineWidth: BighelpTokens.hairline)
        }
        .clipShape(.rect(cornerRadius: BighelpTokens.radius16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(statusLabel)
        .accessibilityIdentifier("chat.generated-media.\(event.eventID)")
        .animation(
            reduceMotion ? nil : .easeInOut(duration: BighelpTokens.stateDuration),
            value: event.generatedMedia?.state
        )
    }

    @ViewBuilder
    private var content: some View {
        switch (event.lifecycle, event.generatedMedia?.state) {
        case (.succeeded, .ready):
            let attachments = event.generatedMedia?.attachments ?? []
            Group {
                if attachments.count == 1, let attachment = attachments.first {
                    GeneratedMediaArtifactView(attachment: attachment, kind: kind)
                } else {
                    TabView {
                        ForEach(attachments) { attachment in
                            GeneratedMediaArtifactView(attachment: attachment, kind: kind)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                }
            }
            .transition(.opacity)
        case (.succeeded, .unavailable), (.succeeded, .oversized), (.failed, _), (.cancelled, _), (.recorded, _):
            RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
                .fill(theme.incomingMessageBackground)
                .overlay {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(theme.tertiaryText)
                        .accessibilityHidden(true)
                }
        default:
            // Still being made, or made and still loading onto this device.
            // No progress bar or count: Hermes reports neither for a picture.
            BighelpImageGeneratingView(caption: loaderCaption, aspectRatio: 4.0 / 3.0)
        }
    }

    private var kind: GeneratedMediaKind {
        GeneratedMediaProjection.kind(for: event) ?? .image
    }

    private var showsStatusLine: Bool {
        if event.generatedMedia?.shownInReply == true { return true }
        switch (event.lifecycle, event.generatedMedia?.state) {
        case (.running, _), (.succeeded, nil), (.succeeded, .ready): return false
        default: return true
        }
    }

    private var loaderCaption: String {
        switch (event.lifecycle, kind) {
        case (.running, .image): "Making your image"
        case (.running, .video): "Making your video"
        case (_, .image): "Loading your image"
        case (_, .video): "Loading your video"
        }
    }

    private var statusLabel: String {
        switch event.lifecycle {
        case .running:
            return kind == .image ? "Making your image" : "Making your video"
        case .failed:
            return kind == .image ? "Image generation failed" : "Video generation failed"
        case .cancelled:
            return "Generation stopped"
        case .recorded:
            return "Generation recorded; outcome unavailable"
        case .succeeded:
            switch event.generatedMedia?.state {
            case .ready:
                return kind == .image ? "Generated image" : "Generated video"
            case .oversized:
                return "Generated media is too large to display"
            case .unavailable:
                // It was made; this phone just can't show it here.
                return kind == .image ? "Image made, but it can't show here" : "Video made, but it can't show here"
            case nil:
                return kind == .image ? "Loading your image" : "Loading your video"
            }
        }
    }

    private var statusSymbol: String {
        switch event.lifecycle {
        case .running: "sparkles"
        case .succeeded where event.generatedMedia?.state == .ready: "checkmark.circle.fill"
        case .succeeded where event.generatedMedia == nil: "arrow.triangle.2.circlepath"
        case .succeeded where event.generatedMedia?.state == .unavailable: kind == .image ? "photo" : "film"
        case .cancelled: "stop.circle.fill"
        case .recorded: "clock.arrow.circlepath"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch event.lifecycle {
        case .running: theme.action
        case .succeeded where event.generatedMedia?.state == .ready: theme.success
        case .succeeded where event.generatedMedia == nil: theme.action
        case .succeeded where event.generatedMedia?.state == .unavailable: theme.secondaryText
        case .cancelled: theme.secondaryText
        case .recorded: theme.secondaryText
        default: theme.danger
        }
    }

    @BighelpThemeReader private var theme
}

private struct GeneratedMediaArtifactView: View {
    let attachment: ChatAttachment
    let kind: GeneratedMediaKind

    var body: some View {
        switch kind {
        case .image:
            if attachment.mimeType.hasPrefix("image/"),
               let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 460)
                    .background(.black.opacity(0.04))
                    .clipShape(.rect(cornerRadius: BighelpTokens.radius12))
                    .contentShape(.contextMenuPreview, .rect(cornerRadius: BighelpTokens.radius12))
                    .chatPictureActions(attachment)
                    .accessibilityLabel("Generated image")
            } else {
                unavailable
            }
        case .video:
            if attachment.mimeType.hasPrefix("video/") {
                GeneratedMediaVideoView(attachment: attachment)
            } else {
                unavailable
            }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Media unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text("This generated item could not be displayed.")
        )
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

@MainActor
private struct GeneratedMediaVideoView: View {
    let attachment: ChatAttachment

    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var temporaryDirectory: URL?
    @State private var isUnavailable = false
    @State private var isPlaying = false
    @BighelpThemeReader private var theme

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(.black)
                    .clipShape(.rect(cornerRadius: BighelpTokens.radius12))
                    .accessibilityLabel("Generated video")
                    .accessibilityIdentifier("chat.generated-video.player.\(attachment.id)")
                    .accessibilityHint("Playback starts only when you press Play.")
                    .transition(.opacity)
                    .overlay(alignment: .bottomLeading) {
                        Button {
                            if player.timeControlStatus == .playing {
                                player.pause()
                            } else {
                                if let item = player.currentItem,
                                   player.currentTime() >= item.duration {
                                    player.seek(to: .zero)
                                }
                                player.play()
                            }
                        } label: {
                            Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                                .frame(minHeight: 44)
                        }
                        .bighelpProminentButtonStyle()
                        .accessibilityIdentifier("chat.generated-video.playback")
                        .padding(12)
                    }
                    .onReceive(player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main)) { status in
                        guard self.player === player else { return }
                        isPlaying = status == .playing
                    }
            } else if isUnavailable {
                ContentUnavailableView(
                    "Video unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This generated video could not be played.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                HStack(spacing: BighelpTokens.space8) {
                    BighelpSpinner(size: 14)
                        .foregroundStyle(theme.secondaryText)
                    Text("Preparing video…")
                        .bighelpFont(.metadata)
                        .bighelpShimmer(isActive: true)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .task(id: attachment.id) {
            await prepare()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player?.pause() }
        }
        .onDisappear {
            player?.pause()
            player = nil
            removeTemporaryFile()
        }
    }

    private func prepare() async {
        player?.pause()
        player = nil
        isUnavailable = false
        removeTemporaryFile()
        guard attachment.data.count <= ChatAttachment.maximumAgentBytes else {
            isUnavailable = true
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "loopdy-generated-media-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileExtension = UTType(mimeType: attachment.mimeType)?.preferredFilenameExtension ?? "mp4"
        let url = directory.appending(path: "generated.\(fileExtension)", directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try attachment.data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            temporaryDirectory = directory
            let asset = AVURLAsset(url: url)
            let isPlayable = try await asset.load(.isPlayable)
            try Task.checkCancellation()
            guard isPlayable else { throw CocoaError(.fileReadCorruptFile) }
            let preparedPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            preparedPlayer.actionAtItemEnd = .pause
            player = preparedPlayer
        } catch is CancellationError {
            removeTemporaryFile()
        } catch {
            removeTemporaryFile()
            isUnavailable = true
        }
    }

    private func removeTemporaryFile() {
        guard let temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
        self.temporaryDirectory = nil
    }
}

