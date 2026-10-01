import Foundation
import Testing
import UIKit
@testable import Bighelp

/// Link previews: the page's own preview tags, only for public web pages, kept
/// so a card doesn't load or change size twice.
@MainActor
struct LinkPreviewTests {
    private let page = URL(string: "https://news.example.com/2026/09/story")!

    // MARK: Reading a page

    @Test func openGraphTagsWin() throws {
        let html = """
        <html><head>
        <title>Fallback title</title>
        <meta name="description" content="Fallback summary">
        <meta property="og:title" content="Rivers are &quot;back&quot; &amp; thriving">
        <meta content="Salmon returned to 40 rivers this year.&#10;Here&#39;s how." property="og:description">
        <meta property='og:site_name' content='Example News'>
        <meta property="og:image" content="/images/salmon.jpg">
        </head><body>ignored</body></html>
        """
        let preview = try #require(LinkPreviewParser.preview(html: html, pageURL: page))
        #expect(preview.title == "Rivers are \"back\" & thriving")
        #expect(preview.summary == "Salmon returned to 40 rivers this year. Here's how.")
        #expect(preview.siteName == "Example News")
        #expect(preview.imageURL == URL(string: "https://news.example.com/images/salmon.jpg"))
    }

    @Test func twitterAndPlainTagsFillIn() throws {
        let html = """
        <HEAD><TITLE>
          A plain   page
        </TITLE>
        <meta name="twitter:description" content="From the card.">
        <meta name="twitter:image" content="http://cdn.example.com/card.png">
        </HEAD>
        """
        let preview = try #require(LinkPreviewParser.preview(html: html, pageURL: page))
        #expect(preview.title == "A plain page")
        #expect(preview.summary == "From the card.")
        // Pictures load over HTTPS only.
        #expect(preview.imageURL == URL(string: "https://cdn.example.com/card.png"))
        #expect(preview.displaySite == "news.example.com")
    }

    @Test func aPageWithNothingToShowHasNoPreview() {
        #expect(LinkPreviewParser.preview(html: "<html><body>Hi</body></html>", pageURL: page) == nil)
    }

    @Test func longTextIsCut() throws {
        let long = String(repeating: "word ", count: 200)
        let html = "<meta property=\"og:title\" content=\"\(long)\"><meta property=\"og:description\" content=\"\(long)\">"
        let preview = try #require(LinkPreviewParser.preview(html: html, pageURL: page))
        #expect(try #require(preview.title).count <= LinkPreviewParser.maximumTitle)
        #expect(try #require(preview.summary).count <= LinkPreviewParser.maximumSummary)
        #expect(preview.summary?.hasSuffix("…") == true)
    }

    // MARK: Which links load

    @Test func onlyPublicWebPagesLoad() {
        func loads(_ string: String) -> Bool { LinkPreviewPolicy.loadableURL(URL(string: string)!) != nil }
        #expect(loads("https://www.example.com/a?b=c"))
        #expect(loads("https://8.8.8.8/"))
        // Plain http is fetched over https.
        #expect(LinkPreviewPolicy.loadableURL(URL(string: "http://example.com/a#part")!)
                == URL(string: "https://example.com/a"))
        for blocked in ["ftp://example.com/file", "mailto:someone@example.com", "https://localhost:9119/",
                        "http://192.168.1.20/", "https://10.0.0.5/", "https://172.20.1.1/", "https://127.0.0.1/",
                        "https://169.254.1.1/", "https://100.101.102.103/", "https://[::1]/", "https://[fd7a::1]/",
                        "https://printer.local/", "https://my-mac.tail1234.ts.net/", "https://router.lan/",
                        "https://intranet/", "https://box.home.arpa/"] {
            #expect(!loads(blocked), "\(blocked) must not load")
        }
    }

    @Test func theFirstWebLinkInAMessage() {
        #expect(LinkPreviewCandidate.firstURL(inMarkdown: "Read [this story](https://example.com/story) and https://other.example.org")
                == URL(string: "https://example.com/story"))
        #expect(LinkPreviewCandidate.firstURL(inMarkdown: "See https://example.com/a, then reply.")
                == URL(string: "https://example.com/a"))
        #expect(LinkPreviewCandidate.firstURL(inMarkdown: "```\ncurl https://example.com/api\n```\nNo links here.") == nil)
        #expect(LinkPreviewCandidate.firstURL(inMarkdown: "Email me at someone@example.com") == nil)
        #expect(LinkPreviewCandidate.firstURL(inMarkdown: "My dashboard is http://192.168.1.4:9119") == nil)
        #expect(LinkPreviewCandidate.firstURL(inMarkdown: "Nothing to see") == nil)
    }

    // MARK: Loading

    @Test func theLoaderReadsThePageAndItsPicture() async throws {
        let picture = Self.png(width: 1200, height: 600)
        let loader = LinkPreviewLoader { request, _, _ in
            if request.url?.path == "/card.png" {
                return (picture, Self.response(request.url!, type: "image/png"))
            }
            let html = "<meta property=\"og:title\" content=\"Hello\"><meta property=\"og:image\" content=\"/card.png\">"
            // Redirects land on the final page, which relative pictures follow.
            let final = URL(string: "https://www.example.com/landing")!
            return (Data(html.utf8), Self.response(final, type: "text/html; charset=utf-8"))
        }
        let loaded = try await loader.load(URL(string: "https://example.com/start")!)
        #expect(loaded.preview.title == "Hello")
        #expect(loaded.preview.url == URL(string: "https://www.example.com/landing"))
        #expect(loaded.preview.imageURL == URL(string: "https://www.example.com/card.png"))
        let aspect = try #require(loaded.preview.imageAspect)
        #expect(abs(aspect - 2) < 0.01)
        #expect(loaded.imageData.flatMap(UIImage.init(data:)) != nil)
    }

    @Test func aLinkStraightToAPictureShowsThePicture() async throws {
        let picture = Self.png(width: 800, height: 800)
        let loader = LinkPreviewLoader { request, _, _ in (picture, Self.response(request.url!, type: "image/png")) }
        let loaded = try await loader.load(URL(string: "https://example.com/photo.png")!)
        #expect(loaded.preview.imageURL == URL(string: "https://example.com/photo.png"))
        #expect(loaded.imageData != nil)
    }

    @Test func tinyPicturesAreLeftOut() async throws {
        let icon = Self.png(width: 32, height: 32)
        let loader = LinkPreviewLoader { request, _, _ in
            if request.url?.path == "/icon.png" { return (icon, Self.response(request.url!, type: "image/png")) }
            let html = "<meta property=\"og:title\" content=\"Hi\"><meta property=\"og:image\" content=\"/icon.png\">"
            return (Data(html.utf8), Self.response(request.url!, type: "text/html"))
        }
        let loaded = try await loader.load(URL(string: "https://example.com/")!)
        #expect(loaded.preview.imageAspect == nil && loaded.imageData == nil)
        #expect(loaded.preview.title == "Hi")
    }

    @Test func pagesThatArentWebPagesHaveNoPreview() async {
        let loader = LinkPreviewLoader { request, _, _ in
            (Data("%PDF".utf8), Self.response(request.url!, type: "application/pdf"))
        }
        await #expect(throws: (any Error).self) { try await loader.load(URL(string: "https://example.com/a.pdf")!) }
        let missing = LinkPreviewLoader { request, _, _ in
            (Data(), Self.response(request.url!, type: "text/html", status: 404))
        }
        await #expect(throws: (any Error).self) { try await missing.load(URL(string: "https://example.com/gone")!) }
    }

    // MARK: Keeping previews

    @Test func eachLinkLoadsOnceAndIsKeptOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "link-previews-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = LoadCounter()
        let loader = LinkPreviewLoader { request, _, _ in
            await counter.add()
            let html = "<meta property=\"og:title\" content=\"Kept\">"
            return (Data(html.utf8), Self.response(request.url!, type: "text/html"))
        }
        let url = URL(string: "https://example.com/kept")!
        let store = LinkPreviewStore(loader: loader, directory: directory)
        #expect(store.cached(url) == nil)
        async let first = store.load(url)
        async let second = store.load(url)
        let results = await [first, second]
        #expect(results.allSatisfy { $0.preview?.title == "Kept" })
        #expect(await counter.count == 1, "Two cards for one link share one load")
        #expect(store.cached(url)?.preview?.title == "Kept")

        // A new launch reads it from disk without loading the page again.
        let relaunched = LinkPreviewStore(loader: loader, directory: directory)
        #expect(relaunched.cached(url)?.preview?.title == "Kept")
        #expect(await counter.count == 1)
    }

    @Test func aFailedLinkShowsJustTheSiteAndIsNotRetriedRightAway() async {
        let counter = LoadCounter()
        let loader = LinkPreviewLoader { request, _, _ in
            await counter.add()
            throw URLError(.cannotFindHost)
        }
        let store = LinkPreviewStore(loader: loader, directory: nil)
        let url = URL(string: "https://example.com/down")!
        #expect(await store.load(url) == .unavailable)
        #expect(await store.load(url) == .unavailable)
        #expect(await counter.count == 1)
    }

    @Test func privateLinksNeverLoad() async {
        let counter = LoadCounter()
        let loader = LinkPreviewLoader { request, _, _ in
            await counter.add()
            return (Data(), Self.response(request.url!, type: "text/html"))
        }
        let store = LinkPreviewStore(loader: loader, directory: nil)
        #expect(await store.load(URL(string: "http://192.168.1.4:9119/")!) == .unavailable)
        #expect(await counter.count == 0)
    }

    // MARK: Helpers

    private nonisolated static func response(_ url: URL, type: String, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
    }

    private nonisolated static func png(width: Int, height: Int) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}

private actor LoadCounter {
    private(set) var count = 0
    func add() { count += 1 }
}
