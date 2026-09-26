import Foundation

enum ProjectGitCodec {}

// Compatibility name for existing native consumers. No transport initializer.
typealias BighelpLinkProjectGitClient = ProjectGitCodec

extension ProjectGitCodec {
    static func decodeCapabilities(_ value: [String: BighelpJSONValue]) throws -> ProjectGitCapabilities {
        try capabilities(value)
    }

    static func decodeStatus(_ value: [String: BighelpJSONValue]) throws -> ProjectGitStatus {
        try status(value)
    }

    static func decodeDiffPage(_ value: [String: BighelpJSONValue]) throws -> ProjectGitDiffPage {
        try diffPage(value)
    }
}

private extension ProjectGitCodec {
    static var invalid: BighelpLinkWorkspaceClientError { .invalidResponse }

    static func capabilities(_ value: [String: BighelpJSONValue]) throws -> ProjectGitCapabilities {
        try keys(value, ["schemaVersion", "capabilities", "workspaces"])
        guard value["schemaVersion"]?.integer == 1,
              let flags = value["capabilities"]?.object,
              let rows = value["workspaces"]?.array, rows.count <= 256 else { throw invalid }
        try keys(flags, ["status", "stage", "commit", "push", "fetch", "pull", "arbitraryCommand"])
        guard let status = flags["status"]?.boolean, let stage = flags["stage"]?.boolean,
              let commit = flags["commit"]?.boolean, let push = flags["push"]?.boolean,
              let fetch = flags["fetch"]?.boolean, let pull = flags["pull"]?.boolean,
              flags["arbitraryCommand"]?.boolean == false else { throw invalid }
        var seen = Set<String>()
        let workspaces = try rows.map { raw -> ProjectGitWorkspaceCapabilities in
            guard let row = raw.object else { throw invalid }
            try keys(row, ["workspaceId", "label", "visibility", "operations", "remotes", "branches", "mutationsEnabled"])
            let id = try identifier(requiredString(row, "workspaceId"), maximum: 160)
            guard seen.insert(id).inserted,
                  let visibility = row["visibility"]?.string, ["public", "private"].contains(visibility),
                  let mutations = row["mutationsEnabled"]?.boolean else { throw invalid }
            let operations = try uniqueEnums(row["operations"], ProjectGitCapabilityOperation.self, maximum: 6)
            return .init(workspaceID: id, label: try text(requiredString(row, "label"), maximum: 120), visibility: visibility, operations: operations, remotes: try uniqueIdentifiers(row["remotes"], maximumCount: 64), branches: try uniqueIdentifiers(row["branches"], maximumCount: 256), mutationsEnabled: mutations)
        }
        return .init(schemaVersion: 1, capabilities: .init(status: status, stage: stage, commit: commit, push: push, fetch: fetch, pull: pull, arbitraryCommand: false), workspaces: workspaces)
    }

    static func status(_ value: [String: BighelpJSONValue]) throws -> ProjectGitStatus {
        try keys(value, ["workspaceId", "statusToken", "head", "files", "filesPage", "staged", "changes", "conflicts", "conflictsPage", "dirty"])
        guard let headValue = value["head"]?.object, let fileValues = value["files"]?.array,
              fileValues.count <= 500, let conflictValues = value["conflicts"]?.array,
              conflictValues.count <= 500, let dirty = value["dirty"]?.boolean else { throw invalid }
        try keys(headValue, ["oid", "branch", "detached", "upstream", "ahead", "behind"])
        guard let detached = headValue["detached"]?.boolean else { throw invalid }
        let head = ProjectGitHead(
            oid: try optionalOID(headValue["oid"]),
            branch: try optionalIdentifier(headValue["branch"], maximum: 180),
            isDetached: detached,
            upstream: try optionalIdentifier(headValue["upstream"], maximum: 360),
            ahead: try count(headValue["ahead"]), behind: try count(headValue["behind"])
        )
        guard detached == (head.branch == nil) else { throw invalid }
        var paths = Set<String>()
        let files = try fileValues.map { raw -> ProjectGitFileChange in
            guard let row = raw.object else { throw invalid }
            try keys(row, ["path", "originalPath", "index", "worktree", "kind", "insertions", "deletions", "isBinary"])
            let path = try path(requiredString(row, "path"))
            guard paths.insert(path).inserted, let rawKind = row["kind"]?.string,
                  let kind = ProjectGitFileKind(rawValue: rawKind),
                  let isBinary = row["isBinary"]?.boolean else { throw invalid }
            return .init(path: path, originalPath: try optionalPath(row["originalPath"]), indexStatus: try gitStatus(requiredString(row, "index")), worktreeStatus: try gitStatus(requiredString(row, "worktree")), kind: kind, insertions: try count(row["insertions"]), deletions: try count(row["deletions"]), isBinary: isBinary)
        }
        let conflicts = try conflictValues.map { raw -> String in guard let raw = raw.string else { throw invalid }; return try path(raw) }
        guard Set(conflicts).count == conflicts.count else { throw invalid }
        let filesPage = try page(value["filesPage"], returnedCount: files.count)
        let conflictsPage = try page(value["conflictsPage"], returnedCount: conflicts.count)
        let changes = try counts(value["changes"])
        guard changes.files == filesPage.total, conflictsPage.total <= changes.files else { throw invalid }
        return .init(workspaceID: try identifier(requiredString(value, "workspaceId"), maximum: 160), statusToken: try digest(requiredString(value, "statusToken")), head: head, files: files, filesPage: filesPage, staged: try counts(value["staged"]), changes: changes, conflicts: conflicts, conflictsPage: conflictsPage, isDirty: dirty)
    }

    static func diffPage(_ value: [String: BighelpJSONValue]) throws -> ProjectGitDiffPage {
        let actualKeys = Set(value.keys)
        let legacyKeys: Set<String> = ["path", "side", "availability", "offset", "lines", "nextOffset"]
        // Older hosts emitted this one preview field without wire-name projection.
        // Accept either spelling, never both or any other unrecognized field.
        guard actualKeys == legacyKeys
            || actualKeys == legacyKeys.union(["previewContent"])
            || actualKeys == legacyKeys.union(["preview_content"]) else { throw invalid }
        guard let rawSide = value["side"]?.string, let side = ProjectGitDiffSide(rawValue: rawSide),
              let rawAvailability = value["availability"]?.string,
              let availability = ProjectGitDiffAvailability(rawValue: rawAvailability),
              let rows = value["lines"]?.array, rows.count <= 500 else { throw invalid }
        let offset = try count(value["offset"], maximum: 100_000)
        let nextOffset = try optionalCount(value["nextOffset"], maximum: 100_000)
        let lines = try rows.enumerated().map { index, raw -> ProjectGitDiffLine in
            guard let row = raw.object else { throw invalid }
            try keys(row, ["kind", "oldLine", "newLine", "content"])
            guard let rawKind = row["kind"]?.string, let kind = ProjectGitDiffLineKind(rawValue: rawKind) else { throw invalid }
            let oldLine = try optionalCount(row["oldLine"], minimum: 1, maximum: 10_000_000)
            let newLine = try optionalCount(row["newLine"], minimum: 1, maximum: 10_000_000)
            switch kind {
            case .header, .hunk, .noNewline: guard oldLine == nil, newLine == nil else { throw invalid }
            case .context: guard oldLine != nil, newLine != nil else { throw invalid }
            case .addition: guard oldLine == nil, newLine != nil else { throw invalid }
            case .deletion: guard oldLine != nil, newLine == nil else { throw invalid }
            }
            return ProjectGitDiffLine(
                offset: offset + index,
                kind: kind,
                oldLine: oldLine,
                newLine: newLine,
                content: try text(
                    requiredString(row, "content", allowsEmpty: true),
                    maximum: 16_384,
                    allowsEmpty: true,
                    allowsTab: true,
                    preservesWhitespace: true,
                    allowsUnicodeFormatting: true
                )
            )
        }
        guard availability == .available || (lines.isEmpty && nextOffset == nil),
              nextOffset == nil || nextOffset == offset + lines.count else { throw invalid }
        let previewContent = try (value["previewContent"] ?? value["preview_content"]).map {
            try text(
                requiredString(["previewContent": $0], "previewContent", allowsEmpty: true),
                maximum: 65_536,
                allowsEmpty: true,
                allowsNewline: true,
                allowsTab: true,
                preservesWhitespace: true,
                allowsUnicodeFormatting: true
            )
        }
        return .init(
            path: try path(requiredString(value, "path")),
            side: side,
            availability: availability,
            offset: offset,
            lines: lines,
            nextOffset: nextOffset,
            previewContent: previewContent
        )
    }

    static func counts(_ value: BighelpJSONValue?) throws -> ProjectGitChangeCounts {
        guard let row = value?.object else { throw invalid }; try keys(row, ["files", "insertions", "deletions"])
        return .init(files: try count(row["files"]), insertions: try count(row["insertions"]), deletions: try count(row["deletions"]))
    }

    static func page(_ value: BighelpJSONValue?, returnedCount: Int) throws -> ProjectGitPageMetadata {
        guard let row = value?.object else { throw invalid }; try keys(row, ["offset", "limit", "returned", "total", "nextOffset", "complete"])
        let offset = try count(row["offset"], maximum: 100_000), limit = try count(row["limit"], minimum: 1, maximum: 500), returned = try count(row["returned"], maximum: 500), total = try count(row["total"]), next = try optionalCount(row["nextOffset"], maximum: 100_000)
        guard let complete = row["complete"]?.boolean, returned == returnedCount, returned <= total, complete == (returned == total), next == (complete ? nil : offset + returned) else { throw invalid }
        return .init(offset: offset, limit: limit, returned: returned, total: total, nextOffset: next, isComplete: complete)
    }

    static func keys(_ value: [String: BighelpJSONValue], _ expected: Set<String>) throws { guard Set(value.keys) == expected else { throw invalid } }
    static func requiredString(_ value: [String: BighelpJSONValue], _ key: String, allowsEmpty: Bool = false) throws -> String { guard let raw = value[key]?.string, allowsEmpty || !raw.isEmpty else { throw invalid }; return raw }
    static func text(_ value: String, maximum: Int, allowsEmpty: Bool = false, allowsNewline: Bool = false, allowsTab: Bool = false, preservesWhitespace: Bool = false, allowsUnicodeFormatting: Bool = false) throws -> String {
        guard (allowsEmpty || !value.isEmpty), value.utf8.count <= maximum, preservesWhitespace || value == value.trimmingCharacters(in: .whitespacesAndNewlines) || allowsNewline,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      && !(allowsUnicodeFormatting && $0.properties.generalCategory == .format)
                      && !(allowsNewline && ($0.value == 10 || $0.value == 13))
                      && !(allowsTab && $0.value == 9)
              }) else { throw invalid }
        return value
    }
    static func identifier(_ value: String, maximum: Int) throws -> String { let value = try text(value, maximum: maximum); guard !value.hasPrefix("-") && !value.contains(where: \.isWhitespace) else { throw invalid }; return value }
    static func optionalIdentifier(_ value: BighelpJSONValue?, maximum: Int) throws -> String? { if value == nil || value == .null { return nil }; guard let raw = value?.string else { throw invalid }; return try identifier(raw, maximum: maximum) }
    static func path(_ value: String) throws -> String { let value = try text(value, maximum: 4_096); let parts = value.split(separator: "/", omittingEmptySubsequences: false); guard !value.hasPrefix("/"), !value.hasPrefix("\\"), !value.hasPrefix("-"), !value.contains("\\"), !value.contains("://"), !parts.isEmpty, !parts.contains(".."), !parts.contains("."), !parts.contains("") else { throw invalid }; return value }
    static func optionalPath(_ value: BighelpJSONValue?) throws -> String? { if value == nil || value == .null { return nil }; guard let raw = value?.string else { throw invalid }; return try path(raw) }
    static func uniqueIdentifiers(_ value: BighelpJSONValue?, maximumCount: Int) throws -> [String] { guard let rows = value?.array, rows.count <= maximumCount else { throw invalid }; let values = try rows.map { guard let raw = $0.string else { throw invalid }; return try identifier(raw, maximum: 360) }; guard Set(values).count == values.count else { throw invalid }; return values }
    static func uniqueEnums<T: RawRepresentable>(_ value: BighelpJSONValue?, _ type: T.Type, maximum: Int) throws -> [T] where T.RawValue == String, T: Hashable { guard let rows = value?.array, rows.count <= maximum else { throw invalid }; let result = try rows.map { guard let raw = $0.string, let item = T(rawValue: raw) else { throw invalid }; return item }; guard Set(result).count == result.count else { throw invalid }; return result }
    static func count(_ value: BighelpJSONValue?, minimum: Int = 0, maximum: Int = 100_000_000) throws -> Int { guard let value = value?.integer, (minimum...maximum).contains(value) else { throw invalid }; return value }
    static func optionalCount(_ value: BighelpJSONValue?, minimum: Int = 0, maximum: Int) throws -> Int? { if value == nil || value == .null { return nil }; return try count(value, minimum: minimum, maximum: maximum) }
    static func digest(_ value: String) throws -> String { guard value.count == 71, value.hasPrefix("sha256:"), value.dropFirst(7).allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else { throw invalid }; return value }
    static func oid(_ value: String) throws -> String { guard [40, 64].contains(value.count), value.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else { throw invalid }; return value }
    static func optionalOID(_ value: BighelpJSONValue?) throws -> String? { if value == nil || value == .null { return nil }; guard let raw = value?.string else { throw invalid }; return try oid(raw) }
    static func gitStatus(_ value: String) throws -> String { guard value.count == 1, ".?MADRCUT".contains(value) else { throw invalid }; return value }
}
