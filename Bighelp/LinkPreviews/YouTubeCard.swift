import SwiftUI
import UIKit
import WebKit

/// A YouTube link's card: the video's picture with a play button, then its
/// title and channel. Play loads YouTube's player right in the card; nothing
/// loads from YouTube until then. The title opens the video in YouTube.
struct YouTubeCard: View {
    let video: YouTubeVideo
    let url: URL
    let preview: LinkPreview?
    let picture: UIImage?

    @Environment(\.openURL) private var openURL
    @State private var isPlaying = false

    private var title: String { preview?.title ?? "YouTube video" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A fixed 16:9 frame; the picture and player fill it without resizing the card.
            Color.black
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if isPlaying {
                        YouTubePlayerView(video: video)
                            .transition(.opacity)
                    } else {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { isPlaying = true }
                        } label: {
                            Color.clear
                                .overlay {
                                    if let picture {
                                        Image(uiImage: picture)
                                            .resizable()
                                            .scaledToFill()
                                    }
                                }
                                .clipped()
                                .overlay {
                                    Image(systemName: "play.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                        .frame(width: 58, height: 58)
                                        .background(.black.opacity(0.55), in: .circle)
                                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                                }
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play \(title)")
                        .accessibilityIdentifier("youtube.play")
                    }
                }
                .clipped()

            Button {
                openURL(url)
            } label: {
                HStack(spacing: BighelpTokens.space12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(2)
                        Text([preview?.summary, "YouTube"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(theme.tertiaryText)
                            .lineLimit(1)
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, BighelpTokens.space12)
                .padding(.vertical, 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the video in YouTube")
            .accessibilityIdentifier("youtube.open")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.incomingMessageBackground)
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .contextMenu {
            Button {
                UIPasteboard.general.url = url
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("link-preview.youtube")
    }

    @BighelpThemeReader private var theme
}

/// YouTube's embedded player in a web view. It keeps no cookies or storage,
/// plays in place, and sends taps that leave the player (YouTube's logo or
/// title) to the chosen browser or the YouTube app.
struct YouTubePlayerView: UIViewRepresentable {
    let video: YouTubeVideo

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.accessibilityIdentifier = "youtube.player"
        context.coordinator.openURL = context.environment.openURL
        webView.loadHTMLString(video.playerPage, baseURL: YouTubeVideo.playerOrigin)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
    }

    /// A card scrolled away or reused stops its video.
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var openURL: OpenURLAction?

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The player page and everything inside the player's own frame load here.
            guard navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url,
                  url.host() != YouTubeVideo.playerOrigin.host(), url.scheme != "about" else { return .allow }
            openURL?(url)
            return .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { openURL?(url) }
            return nil
        }
    }
}
