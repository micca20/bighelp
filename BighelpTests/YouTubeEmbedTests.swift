import Foundation
import Testing
import UIKit
@testable import Bighelp

/// YouTube links play right in the card, using YouTube's privacy-enhanced
/// player, and read their title from YouTube's own oEmbed answer.
@MainActor
struct YouTubeEmbedTests {
    @Test func everyKindOfYouTubeLinkIsAVideo() {
        func id(_ string: String) -> String? { YouTubeVideo(url: URL(string: string)!)?.id }
        #expect(id("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(id("https://youtube.com/watch?feature=share&v=dQw4w9WgXcQ&list=PL1") == "dQw4w9WgXcQ")
        #expect(id("https://m.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(id("https://music.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(id("https://youtu.be/dQw4w9WgXcQ?si=abc") == "dQw4w9WgXcQ")
        #expect(id("https://www.youtube.com/shorts/aqz-KE-bpKQ") == "aqz-KE-bpKQ")
        #expect(id("https://www.youtube.com/live/aqz-KE-bpKQ?feature=share") == "aqz-KE-bpKQ")
        #expect(id("https://www.youtube.com/embed/aqz-KE-bpKQ") == "aqz-KE-bpKQ")
        #expect(id("https://www.youtube-nocookie.com/embed/aqz-KE-bpKQ") == "aqz-KE-bpKQ")
        for other in ["https://www.youtube.com/@apple", "https://www.youtube.com/watch?v=short",
                      "https://www.youtube.com/watch?v=dQw4w9WgXc!", "https://example.com/watch?v=dQw4w9WgXcQ",
                      "https://notyoutube.com/watch?v=dQw4w9WgXcQ", "http://youtu.be/", "https://www.youtube.com/playlist?list=PL1"] {
            #expect(id(other) == nil, "\(other) isn't a video")
        }
    }

    @Test func aStartTimeIsKept() {
        func start(_ string: String) -> Int? { YouTubeVideo(url: URL(string: string)!)?.start }
        #expect(start("https://youtu.be/dQw4w9WgXcQ?t=90") == 90)
        #expect(start("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s") == 90)
        #expect(start("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1h2m3s") == 3_723)
        #expect(start("https://www.youtube.com/watch?v=dQw4w9WgXcQ&start=42") == 42)
        #expect(start("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(start("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=soon") == nil)
    }

    @Test func thePlayerIsYouTubesPrivacyEnhancedEmbed() throws {
        let video = try #require(YouTubeVideo(url: URL(string: "https://youtu.be/dQw4w9WgXcQ?t=90")!))
        let embed = video.embedURL
        #expect(embed.host() == "www.youtube-nocookie.com")
        #expect(embed.path() == "/embed/dQw4w9WgXcQ")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: embed, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["playsinline"] == "1", "Plays in the card, not straight to full screen")
        #expect(query["autoplay"] == "1", "You already tapped play")
        #expect(query["start"] == "90")
        #expect(query["origin"] == YouTubeVideo.playerOrigin.absoluteString)
        let page = video.playerPage
        #expect(page.contains(embed.absoluteString.replacingOccurrences(of: "&", with: "&amp;")))
        #expect(page.contains("referrerpolicy=\"strict-origin-when-cross-origin\""))
        #expect(video.watchURL == URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    @Test func titleAndChannelComeFromYouTubesOEmbed() async throws {
        let loader = LinkPreviewLoader { request, _, _ in
            let url = try #require(request.url)
            if url.host() == "www.youtube.com", url.path() == "/oembed" {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                #expect(query.first { $0.name == "url" }?.value == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
                let json = #"{"title":"Never Gonna Give You Up","author_name":"Rick Astley","provider_name":"YouTube","thumbnail_url":"https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"}"#
                return (Data(json.utf8), Self.response(url, type: "application/json"))
            }
            if url.host() == "i.ytimg.com" {
                #expect(url.path().hasPrefix("/vi/dQw4w9WgXcQ/"))
                return (Self.picture, Self.response(url, type: "image/jpeg"))
            }
            Issue.record("Unexpected request \(url)")
            throw URLError(.badURL)
        }
        let loaded = try await loader.load(URL(string: "https://youtu.be/dQw4w9WgXcQ")!)
        #expect(loaded.preview.title == "Never Gonna Give You Up")
        #expect(loaded.preview.summary == "Rick Astley")
        #expect(loaded.preview.siteName == "YouTube")
        #expect(loaded.imageData != nil)
    }

    /// A private or removed video: YouTube's page only has generic text
    /// ("- YouTube"), so the card stays a plain, playable video card.
    @Test func anUnknownVideoStillGetsAPlainVideoCard() async throws {
        let loader = LinkPreviewLoader { request, _, _ in
            let url = try #require(request.url)
            if url.path() == "/oembed" { return (Data(), Self.response(url, type: "text/html", status: 404)) }
            if url.host() == "i.ytimg.com" { return (Data(), Self.response(url, type: "text/html", status: 404)) }
            Issue.record("The page isn't read for videos: \(url)")
            let html = #"<meta property="og:title" content="- YouTube">"#
            return (Data(html.utf8), Self.response(url, type: "text/html"))
        }
        let loaded = try await loader.load(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        #expect(loaded.preview.title == nil)
        #expect(loaded.preview.siteName == "YouTube")
        #expect(loaded.imageData == nil)
    }

    private nonisolated static func response(_ url: URL, type: String, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
    }

    private nonisolated static let picture: Data = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 480, height: 360), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 360))
        }
    }()
}
