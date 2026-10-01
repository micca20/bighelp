import Foundation

/// A web page's own preview, as Messages and social apps show it: its title,
/// summary, site and picture.
struct LinkPreview: Codable, Equatable, Sendable {
    /// The page after redirects.
    var url: URL
    var title: String?
    var summary: String?
    var siteName: String?
    var imageURL: URL?
    /// Width over height of the kept picture, so a card keeps its size before
    /// the picture draws. Nil when there's no picture to show.
    var imageAspect: Double?

    var displaySite: String {
        if let siteName, !siteName.isEmpty { return siteName }
        return Self.host(of: url)
    }

    static func host(of url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Which links bighelp loads a preview for: public web pages only. Addresses on
/// your home network, Tailscale or this device are never loaded, so a message
/// can't make the phone reach into them.
enum LinkPreviewPolicy {
    private static let privateSuffixes = [".local", ".localhost", ".internal", ".lan", ".home", ".home.arpa",
                                          ".ts.net", ".corp", ".intranet", ".localdomain"]

    /// The page to load for `url` (always HTTPS, without the #fragment), or nil.
    static func loadableURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), isPublic(host) else { return nil }
        if scheme == "http", components.port == 80 { components.port = nil }
        components.scheme = "https"
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    static func isPublic(_ rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[].")).lowercased()
        guard !host.isEmpty, !host.contains(":") else { return false } // IPv6 literals stay out.
        if let octets = ipv4(host) { return isPublic(octets) }
        guard host.contains("."), host != "localhost", !host.hasSuffix(".") else { return false }
        return !privateSuffixes.contains { host.hasSuffix($0) }
    }

    private static func ipv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }

    private static func isPublic(_ octets: [UInt8]) -> Bool {
        switch (octets[0], octets[1]) {
        case (0, _), (10, _), (127, _): false
        case (100, 64...127): false // Carrier NAT, which Tailscale uses.
        case (169, 254): false
        case (172, 16...31): false
        case (192, 168): false
        case (198, 18...19): false
        case (224..., _): false
        default: !(octets[0] == 192 && octets[1] == 0 && octets[2] == 0)
        }
    }
}

/// The link a message's preview is for: its first web link, skipping code.
enum LinkPreviewCandidate {
    static func firstURL(inMarkdown text: String) -> URL? {
        firstURL(in: MarkdownDocument(text))
    }

    static func firstURL(in document: MarkdownDocument) -> URL? {
        for block in document.blocks {
            for markdown in inlineMarkdown(block) {
                for run in ChatInlineMarkdown.attributedText(markdown).runs {
                    guard let link = run.link, run.inlinePresentationIntent?.contains(.code) != true,
                          LinkPreviewPolicy.loadableURL(link) != nil else { continue }
                    return link
                }
            }
        }
        return nil
    }

    private static func inlineMarkdown(_ block: MarkdownBlock) -> [String] {
        switch block {
        case .heading(_, let markdown), .paragraph(let markdown), .quote(let markdown): [markdown]
        case .unorderedList(let items), .orderedList(_, let items): items
        case .table(let table): table.header + table.rows.flatMap { $0 }
        case .code, .rule: []
        }
    }
}

/// Reads a page's preview tags: Open Graph first, then Twitter cards, then the
/// plain title and description.
enum LinkPreviewParser {
    static let maximumTitle = 160
    static let maximumSummary = 280
    static let maximumSite = 60
    /// Preview tags live in the page's head; nothing past this is read.
    static let maximumHeadCharacters = 300_000

    /// Nil when the page has no title, summary or picture to show.
    static func preview(html: String, pageURL: URL) -> LinkPreview? {
        let head = headSection(html)
        var meta: [String: String] = [:]
        for tag in tags(named: "meta", in: head) {
            let attributes = attributes(of: tag)
            guard let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"])?.lowercased(),
                  let content = attributes["content"], meta[key] == nil else { continue }
            meta[key] = content
        }
        let title = clean(meta["og:title"] ?? meta["twitter:title"] ?? titleTag(head), limit: maximumTitle)
        let summary = clean(meta["og:description"] ?? meta["twitter:description"] ?? meta["description"],
                            limit: maximumSummary)
        let site = clean(meta["og:site_name"] ?? meta["application-name"], limit: maximumSite)
        let pictures = [meta["og:image:secure_url"], meta["og:image"], meta["og:image:url"],
                        meta["twitter:image"], meta["twitter:image:src"], imageSourceLink(head)]
        let image = pictures.compactMap { $0 }.lazy.compactMap { pictureURL($0, page: pageURL) }.first
        guard title != nil || summary != nil || image != nil else { return nil }
        return LinkPreview(url: pageURL, title: title, summary: summary, siteName: site, imageURL: image)
    }

    private static func headSection(_ html: String) -> Substring {
        let end = html.range(of: "</head", options: .caseInsensitive)?.lowerBound ?? html.endIndex
        let capped = html.index(html.startIndex, offsetBy: maximumHeadCharacters, limitedBy: end) ?? end
        return html[html.startIndex..<capped]
    }

    private static func tags(named name: String, in text: Substring) -> [String] {
        matches("<\(name)\\b[^>]*>", in: text).map { String($0[0]) }
    }

    private static func attributes(of tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
        for groups in matches(pattern, in: Substring(tag)) {
            let key = String(groups[1]).lowercased()
            let value = groups.dropFirst(2).first { !$0.isEmpty } ?? ""
            if result[key] == nil { result[key] = String(value) }
        }
        return result
    }

    private static func titleTag(_ head: Substring) -> String? {
        matches(#"<title\b[^>]*>([\s\S]*?)</title\s*>"#, in: head).first.map { String($0[1]) }
    }

    private static func imageSourceLink(_ head: Substring) -> String? {
        for tag in tags(named: "link", in: head) {
            let attributes = attributes(of: tag)
            if attributes["rel"]?.lowercased().split(separator: " ").contains("image_src") == true {
                return attributes["href"]
            }
        }
        return nil
    }

    /// Each match's capture groups (group 0 is the whole match; missing groups are empty).
    private static func matches(_ pattern: String, in text: Substring) -> [[Substring]] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let string = String(text)
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return expression.matches(in: string, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: string).map { string[$0] } ?? ""
            }
        }
    }

    private static func pictureURL(_ raw: String, page: URL) -> URL? {
        let value = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let url = URL(string: value, relativeTo: page)
            ?? value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
                .flatMap { URL(string: $0, relativeTo: page) }
        return url.flatMap { LinkPreviewPolicy.loadableURL($0.absoluteURL) }
    }

    /// Entities decoded, runs of spaces and line breaks made one space, and cut
    /// to `limit` characters with "…".
    static func clean(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let words = decodeEntities(raw).unicodeScalars
            .map { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                ? " " : Character($0) }
        let collapsed = String(words).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return collapsed.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "hellip": "…",
        "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "copy": "©", "reg": "®", "trade": "™", "middot": "·", "bull": "•",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[rest.startIndex..<ampersand]
            let afterAmpersand = rest.index(after: ampersand)
            guard let semicolon = rest[afterAmpersand...].prefix(12).firstIndex(of: ";") else {
                result += "&"
                rest = rest[afterAmpersand...]
                continue
            }
            let name = rest[afterAmpersand..<semicolon]
            if let decoded = decodeEntity(name) {
                result += decoded
                rest = rest[rest.index(after: semicolon)...]
            } else {
                result += "&"
                rest = rest[afterAmpersand...]
            }
        }
        return result + rest
    }

    private static func decodeEntity(_ name: Substring) -> String? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if name.hasPrefix("#") {
            return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return namedEntities[name.lowercased()]
    }
}
