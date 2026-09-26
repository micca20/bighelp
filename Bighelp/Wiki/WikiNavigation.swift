import Foundation

enum WikiLinkDestination: Equatable, Sendable {
    case anchor(String)
    case pages(paths: [String], anchor: String?, shortName: String?)
    case external(URL)
}

enum WikiNavigation {
    static func newFilePath(folder: String, filename: String) throws -> String {
        try validatePath(folder, allowRoot: true)
        guard !filename.contains("/"), isMarkdownPath(filename) else { throw WikiError.invalidPath }
        try validatePath(filename)
        let path = folder.isEmpty ? filename : folder + "/" + filename
        try validatePath(path)
        return path
    }

    static func validatePath(_ path: String, allowRoot: Bool = false) throws {
        if path.isEmpty && allowRoot { return }
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
              }) else { throw WikiError.invalidPath }
    }

    static func parent(of path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return path.split(separator: "/").dropLast().joined(separator: "/")
    }

    static func isMarkdownPath(_ path: String) -> Bool {
        ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }

    static func isImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains((path as NSString).pathExtension.lowercased())
    }

    static func safeExternalURL(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return components.url
    }

    static func destination(_ raw: String, from path: String) throws -> WikiLinkDestination {
        guard raw.utf8.count <= 4_096,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WikiError.invalidPath
        }
        if let external = safeExternalURL(raw) { return .external(external) }
        var input = raw
        if input.hasPrefix("wiki-link:") { input = String(input.dropFirst("wiki-link:".count)) }
        guard let decoded = input.removingPercentEncoding, !decoded.contains("\\"),
              !decoded.contains(":"), !decoded.hasPrefix("//"), !decoded.contains("?"),
              !decoded.contains("%"),
              !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WikiError.invalidPath
        }
        let parts = decoded.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let target = String(parts[0])
        let anchor = parts.count > 1 ? String(parts[1]) : nil
        if target.isEmpty { return .anchor(anchor ?? "") }
        let short = !target.contains("/")
        let names = (target as NSString).pathExtension.isEmpty ? [target + ".md", target + ".markdown"] : [target]
        var paths: [String] = []
        for (index, base) in [parent(of: path) ?? "", ""].enumerated() {
            for name in names {
                let candidate: String
                do { candidate = try confined(name, relativeTo: base) }
                catch {
                    // A valid parent-relative link need not also be valid from root.
                    if index == 0 { throw error }
                    continue
                }
                guard isMarkdownPath(candidate) else { throw WikiError.invalidPath }
                if !paths.contains(candidate) { paths.append(candidate) }
            }
        }
        return .pages(paths: paths, anchor: anchor, shortName: short ? target : nil)
    }

    static func imagePath(_ raw: String, from documentPath: String) throws -> String {
        guard let decoded = raw.removingPercentEncoding, !decoded.contains("%"),
              !decoded.contains(":"), !decoded.contains("?"), !decoded.contains("#") else { throw WikiError.invalidPath }
        let path = try confined(decoded, relativeTo: parent(of: documentPath) ?? "")
        guard isImagePath(path) else { throw WikiError.unsafeImage }
        return path
    }

    private static func confined(_ target: String, relativeTo base: String) throws -> String {
        guard !target.hasPrefix("//"), !target.contains("\\") else { throw WikiError.invalidPath }
        var components = target.hasPrefix("/") ? [] : base.split(separator: "/").map(String.init)
        for component in target.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".": continue
            case "..":
                guard !components.isEmpty else { throw WikiError.invalidPath }
                components.removeLast()
            default: components.append(String(component))
            }
        }
        let path = components.joined(separator: "/")
        try validatePath(path)
        return path
    }

    static func headingAnchor(_ heading: String) -> String {
        let plain = MarkdownDocument(heading).visiblePlainText.lowercased()
        return plain.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) || $0 == "-" || $0 == "_"
        }.map(String.init).joined().split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }
}
