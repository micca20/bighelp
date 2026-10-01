import Foundation

/// A YouTube video link: which video, where it starts, and how to play it
/// inside bighelp with YouTube's privacy-enhanced player.
struct YouTubeVideo: Equatable, Sendable {
    let id: String
    /// Seconds into the video, from `t=` or `start=`.
    let start: Int?

    /// The page the player says it's embedded in. YouTube's player needs to
    /// know which app shows it; this is bighelp's app ID as a web origin.
    static let playerOrigin = URL(string: "https://app.loopdy.mobile")!

    private static let youTubeHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com",
                                                    "music.youtube.com", "youtube-nocookie.com",
                                                    "www.youtube-nocookie.com"]

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased() else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let path = url.pathComponents.filter { $0 != "/" }
        let candidate: String?
        if host == "youtu.be" || host == "www.youtu.be" {
            candidate = path.first
        } else if Self.youTubeHosts.contains(host) {
            if path.first == "watch" {
                candidate = query.first { $0.name == "v" }?.value
            } else if let kind = path.first, ["shorts", "live", "embed", "v"].contains(kind), path.count >= 2 {
                candidate = path[1]
            } else {
                candidate = nil
            }
        } else {
            candidate = nil
        }
        guard let candidate, Self.isVideoID(candidate) else { return nil }
        id = candidate
        start = (query.first { $0.name == "t" } ?? query.first { $0.name == "start" })?.value.flatMap(Self.seconds)
    }

    static func isVideoID(_ value: String) -> Bool {
        value.count == 11 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// "90", "90s", "1m30s" or "1h2m3s" as seconds.
    static func seconds(_ value: String) -> Int? {
        if let plain = Int(value) { return plain >= 0 ? plain : nil }
        var total = 0
        var digits = ""
        for character in value.lowercased() {
            if character.isASCII, character.isNumber {
                digits.append(character)
                continue
            }
            guard let amount = Int(digits) else { return nil }
            switch character {
            case "h": total += amount * 3_600
            case "m": total += amount * 60
            case "s": total += amount
            default: return nil
            }
            digits = ""
        }
        return digits.isEmpty && total >= 0 && !value.isEmpty ? total : nil
    }

    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }

    /// The privacy-enhanced player, playing in place as soon as it loads (you
    /// already tapped play), without other channels' videos at the end.
    var embedURL: URL {
        var components = URLComponents(string: "https://www.youtube-nocookie.com/embed/\(id)")!
        var items = [URLQueryItem(name: "playsinline", value: "1"), URLQueryItem(name: "autoplay", value: "1"),
                     URLQueryItem(name: "rel", value: "0")]
        if let start { items.append(URLQueryItem(name: "start", value: String(start))) }
        items.append(URLQueryItem(name: "origin", value: Self.playerOrigin.absoluteString))
        components.queryItems = items
        return components.url!
    }

    /// YouTube's picture for the video: "maxresdefault" (16:9, not always made)
    /// or "hqdefault" (always there).
    func thumbnailURL(_ size: String) -> URL {
        URL(string: "https://i.ytimg.com/vi/\(id)/\(size).jpg")!
    }

    /// A page holding just the player, filling the card.
    var playerPage: String {
        let source = embedURL.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
        return """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;padding:0;height:100%;background:#000;overflow:hidden}
        iframe{position:absolute;top:0;left:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="\(source)" allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen
         referrerpolicy="strict-origin-when-cross-origin" title="YouTube video"></iframe>
        </body></html>
        """
    }
}
