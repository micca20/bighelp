import Foundation

enum ReferenceCategory: String, CaseIterable, Sendable {
    case all, repos, issues, prs, wiki, skills, commands
}

enum ReferenceKind: String, CaseIterable, Sendable {
    case repository, issue, pullRequest, wiki
}

/// Provider resource IDs, never GitHub credentials or a local connection ID.
struct GitHubReferenceIdentity: Equatable, Sendable {
    let repositoryID: String
    let resourceID: String?
    let owner: String
    let repository: String
    let number: Int?

    init(repositoryID: String, resourceID: String? = nil, owner: String,
         repository: String, number: Int? = nil) {
        self.repositoryID = repositoryID
        self.resourceID = resourceID
        self.owner = owner
        self.repository = repository
        self.number = number
    }
}

/// An intentionally shareable logical namespace and relative path. Namespace
/// is NOT the host/grant/connection ID or the Wiki's absolute filesystem root.
struct WikiReferenceIdentity: Equatable, Sendable {
    let namespace: String
    let relativePath: String
    let section: String?

    init(namespace: String, relativePath: String, section: String? = nil) {
        self.namespace = namespace
        self.relativePath = relativePath
        self.section = section
    }
}

enum ReferenceSourceIdentity: Equatable, Sendable {
    case github(GitHubReferenceIdentity)
    case wiki(WikiReferenceIdentity)
}

/// Exact selected external data. No provider, network, permission, freshness,
/// routing or execution semantics are implied by creating/decoding this value.
struct ReferenceSnapshot: Equatable, Sendable {
    let kind: ReferenceKind
    let identity: ReferenceSourceIdentity
    let qualifiedLocation: String
    let anchor: String
    let title: String
    let selectedContent: String
    let sourceRevision: String
    let fetchedAt: Date
    let isTruncated: Bool

    /// Location and anchor are derived from validated source tokens, never a
    /// normalized/repaired URL or imported title. Title/content stay JSON data.
    init(kind: ReferenceKind, identity: ReferenceSourceIdentity, title: String,
         selectedContent: String, sourceRevision: String, fetchedAt: Date,
         isTruncated: Bool = false) throws {
        let location = try Self.location(kind: kind, identity: identity)
        guard title.utf8.count <= 2_048,
              selectedContent.utf8.count <= ReferenceCodec.maximumAppendixBytes,
              !sourceRevision.isEmpty, sourceRevision.utf8.count <= 512,
              !sourceRevision.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }),
              fetchedAt.timeIntervalSince1970.isFinite,
              (0...253_402_300_799).contains(fetchedAt.timeIntervalSince1970) else {
            throw ReferenceCodec.Failure.invalidSnapshot
        }
        self.kind = kind
        self.identity = identity
        self.qualifiedLocation = location.label
        self.anchor = "[\(Self.escapeLabel(location.label))](\(location.target))"
        self.title = title
        self.selectedContent = selectedContent
        self.sourceRevision = sourceRevision
        self.fetchedAt = fetchedAt
        self.isTruncated = isTruncated
    }

    /// Readable chip text is presentation only; canonical links remain unchanged.
    var displayLabel: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch identity {
        case .github(let source):
            if let number = source.number {
                let prefix = kind == .pullRequest ? "PR" : "Issue"
                return "\(prefix) #\(number)" + (name.isEmpty ? "" : ": \(name)")
            }
            return name.isEmpty ? "\(source.owner)/\(source.repository)" : name
        case .wiki(let source):
            return name.isEmpty ? source.relativePath : name
        }
    }

    /// Timestamp-only refreshes do not change reviewed content. Unicode is
    /// compared by exact UTF-8, not Swift's canonical-equivalence equality.
    func hasSameContent(as other: ReferenceSnapshot) -> Bool {
        guard kind == other.kind, isTruncated == other.isTruncated else { return false }
        return zip([identityKey, qualifiedLocation, anchor, title, selectedContent, sourceRevision],
                   [other.identityKey, other.qualifiedLocation, other.anchor, other.title,
                    other.selectedContent, other.sourceRevision]).allSatisfy {
            Data($0.0.utf8) == Data($0.1.utf8)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fetchedAt == rhs.fetchedAt && lhs.hasSameContent(as: rhs)
    }

    /// Stable deduplication identity; qualified names are descriptive, not IDs.
    var identityKey: String {
        switch identity {
        case .github(let source):
            return "github:\(kind.rawValue):\(source.repositoryID):\(source.resourceID ?? "")"
        case .wiki(let source):
            // Length-prefixed parts cannot collide via delimiter injection.
            return ["wiki", source.namespace, source.relativePath, source.section ?? ""].map {
                "\($0.utf8.count):\($0)"
            }.joined()
        }
    }

    private static func location(kind: ReferenceKind, identity: ReferenceSourceIdentity) throws
        -> (label: String, target: String) {
        switch identity {
        case .github(let value):
            guard kind != .wiki,
                  decimalID(value.repositoryID),
                  asciiToken(value.owner, maximum: 39, dots: false),
                  !value.owner.hasPrefix("-"), !value.owner.hasSuffix("-"), !value.owner.contains("--"),
                  asciiToken(value.repository, maximum: 100, dots: true),
                  value.repository != ".", value.repository != ".." else {
                throw ReferenceCodec.Failure.invalidIdentity
            }
            var label = "\(value.owner)/\(value.repository)"
            var target = "https://github.com/\(label)"
            if kind == .repository {
                guard value.resourceID == nil, value.number == nil else { throw ReferenceCodec.Failure.invalidIdentity }
            } else {
                guard let resourceID = value.resourceID, decimalID(resourceID),
                      let number = value.number, number > 0, number <= 9_007_199_254_740_991 else {
                    throw ReferenceCodec.Failure.invalidIdentity
                }
                let route = kind == .pullRequest ? "pull" : "issues"
                label += kind == .pullRequest ? " PR #\(number)" : " #\(number)"
                target += "/\(route)/\(number)"
            }
            return (label, target)
        case .wiki(let value):
            guard kind == .wiki, asciiToken(value.namespace, maximum: 80, dots: false),
                  !value.relativePath.isEmpty, value.relativePath.utf8.count <= 1_024,
                  !value.relativePath.hasPrefix("/"), !value.relativePath.contains("\\"),
                  !value.relativePath.contains(":"), !value.relativePath.contains("%"),
                  !value.relativePath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }),
                  value.relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                      !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix("~")
                  }) else { throw ReferenceCodec.Failure.invalidIdentity }
            if let section = value.section {
                guard !section.isEmpty, section.utf8.count <= 256,
                      !section.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
                    throw ReferenceCodec.Failure.invalidIdentity
                }
            }
            let suffix = value.section.map { "#\($0)" } ?? ""
            let label = "\(value.namespace):\(value.relativePath)\(suffix)"
            // Percent-encode validated path *components*, not an invalid URL.
            let path = value.relativePath.split(separator: "/").map { percentEncode(String($0)) }.joined(separator: "/")
            let target = "loopdy-wiki://reference/\(percentEncode(value.namespace))/\(path)"
                + (value.section.map { "#\(percentEncode($0))" } ?? "")
            return (label, target)
        }
    }

    private static func decimalID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 20 && value.first != "0"
            && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func asciiToken(_ value: String, maximum: Int, dots: Bool) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 45 || (dots && ($0 == 46 || $0 == 95))
        }
    }

    private static func escapeLabel(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            // Provider-supplied paths/sections cannot inject a raw recipient
            // token even into the readable link label.
            if scalar == "@" { result += "&#64;"; continue }
            if "\\[]`~*_<>!".unicodeScalars.contains(scalar) { result.append("\\") }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    private static func percentEncode(_ value: String) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || [45, 46, 95, 126].contains(byte) {
                return String(UnicodeScalar(UInt32(byte))!)
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}
