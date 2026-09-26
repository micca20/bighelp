import Foundation
import Testing
@testable import Loopdy

@MainActor
struct ProjectGitCodecTests {

    @Test(arguments: ["README.md", "notes.txt", "GUIDE.MARKDOWN"])
    func diffAcceptsInstalledHostPreviewField(_ path: String) throws {
        let content = "# Full file\n\n  Unchanged context\tkept.  \nFinal preview marker\n"
        let payload: [String: LoopdyJSONValue] = [
            "path": .string(path), "side": .string("worktree"),
            "availability": .string("available"), "offset": .integer(0),
            "lines": .array([.object([
                "kind": .string("addition"), "oldLine": .null, "newLine": .integer(3),
                "content": .string("  Unchanged context\tkept.  "),
            ])]),
            "nextOffset": .null, "preview_content": .string(content),
        ]
        let page = try ProjectGitCodec.decodeDiffPage(payload)
        #expect(page.previewContent == content)
        let file = ProjectGitFileChange(
            path: path, originalPath: nil, indexStatus: ".", worktreeStatus: "M",
            kind: .ordinary, insertions: 1, deletions: 1, isBinary: false
        )
        #expect(ProjectChangesMarkdownPreviewBuilder.preview(for: page, file: file) == .content(content))
    }

    @Test(arguments: ["previewContent", "preview_content"])
    func diffPreviewPreservesEmptyAndWhitespaceContent(_ field: String) throws {
        for content in ["", "  text\t \r\n", "# Heading\n\nLast line\n"] {
            let payload: [String: LoopdyJSONValue] = [
                "path": .string("notes.txt"), "side": .string("staged"),
                "availability": .string("available"), "offset": .integer(0),
                "lines": .array([]), "nextOffset": .null, field: .string(content),
            ]
            let page = try ProjectGitCodec.decodeDiffPage(payload)
            #expect(page.previewContent == content)
        }
    }

    @Test func diffRejectsAmbiguousOrUnsafePreviewFields() {
        let invalidFields: [[String: LoopdyJSONValue]] = [
            ["previewContent": .string("one"), "preview_content": .string("two")],
            ["preview_content": .null],
            ["previewContent": .integer(1)],
            ["preview_content": .string("bad\u{0000}text")],
            ["previewContent": .string("bad\u{0085}text")],
            ["preview_content": .string(String(repeating: "é", count: 32_769))],
            ["unexpectedPreview": .string("text")],
        ]
        for fields in invalidFields {
            var payload: [String: LoopdyJSONValue] = [
                "path": .string("README.md"), "side": .string("worktree"),
                "availability": .string("available"), "offset": .integer(0),
                "lines": .array([]), "nextOffset": .null,
            ]
            payload.merge(fields) { _, new in new }
            #expect(throws: LoopdyLinkWorkspaceClientError.invalidResponse) {
                _ = try ProjectGitCodec.decodeDiffPage(payload)
            }
        }
    }

    @Test func diffPreservesUnicodeFormattingFromTextFiles() throws {
        let content = "\u{FEFF}# Family 👨‍👩‍👧‍👦\n\u{200E}Document text\n"
        for field in ["previewContent", "preview_content"] {
            let payload: [String: LoopdyJSONValue] = [
                "path": .string("README.md"), "side": .string("worktree"),
                "availability": .string("available"), "offset": .integer(0),
                "lines": .array([.object([
                    "kind": .string("addition"), "oldLine": .null, "newLine": .integer(1),
                    "content": .string("\u{FEFF}# Family 👨‍👩‍👧‍👦"),
                ])]), "nextOffset": .null, field: .string(content),
            ]
            let page = try ProjectGitCodec.decodeDiffPage(payload)
            #expect(page.previewContent == content)
            #expect(page.lines.first?.content == "\u{FEFF}# Family 👨‍👩‍👧‍👦")
        }
    }

    @Test func fixedOperationsUseTheStandardBoundedEnvelope() {
        let expected: [(LoopdyLinkWorkspaceOperation, String)] = [
            (.projectsGitCapabilities, "projects.git.capabilities"),
            (.projectsGitStatus, "projects.git.status"),
            (.projectsGitDiff, "projects.git.diff"),
            (.projectsGitPrepare, "projects.git.prepare"),
            (.projectsGitExecute, "projects.git.execute"),
        ]
        for (operation, rawValue) in expected {
            #expect(operation.rawValue == rawValue)
            #expect(LoopdyLinkWorkspacePayloadLimits.requestBytes(for: operation) == 196_608)
            #expect(LoopdyLinkWorkspacePayloadLimits.resultBytes(for: operation) == 196_608)
        }
    }

    @Test func statusDecodesBoundedProjection() throws {
        let status = try ProjectGitCodec.decodeStatus(Self.statusPayload)
        #expect(status.workspaceID == "project-loopdy")
        #expect(status.changes == .init(files: 2, insertions: 14, deletions: 3))
        #expect(status.files.map(\.path) == ["Loopdy/App.swift", "Loopdy/New.swift"])
    }

    @Test func capabilitiesDecodeOnlyTheSelectedBoundedWorkspace() throws {
        let payload: [String: LoopdyJSONValue] = [
            "schemaVersion": .integer(1),
            "capabilities": .object([
                "status": .boolean(true), "stage": .boolean(true),
                "commit": .boolean(true), "push": .boolean(true),
                "fetch": .boolean(true), "pull": .boolean(true),
                "arbitraryCommand": .boolean(false),
            ]),
            "workspaces": .array([.object([
                "workspaceId": .string("project-loopdy"), "label": .string("Loopdy"),
                "visibility": .string("private"),
                "operations": .array(["commit", "fetch", "pull", "push", "stage", "status"].map(LoopdyJSONValue.string)),
                "remotes": .array([.string("origin")]), "branches": .array([.string("main")]),
                "mutationsEnabled": .boolean(true),
            ])]),
        ]

        let capabilities = try ProjectGitCodec.decodeCapabilities(payload)

        #expect(capabilities.workspaces.first?.operations.contains(.status) == true)
    }

    @Test func diffDecodesBoundedPage() throws {
        let payload: [String: LoopdyJSONValue] = [
            "path": .string("Loopdy/App.swift"),
            "side": .string("worktree"),
            "availability": .string("available"),
            "offset": .integer(0),
            "lines": .array([
                .object(["kind": .string("header"), "oldLine": .null, "newLine": .null, "content": .string("@@ -1 +1 @@")]),
                .object(["kind": .string("deletion"), "oldLine": .integer(1), "newLine": .null, "content": .string("old")]),
                .object(["kind": .string("addition"), "oldLine": .null, "newLine": .integer(1), "content": .string("    value: true  ")]),
            ]),
            "nextOffset": .null,
        ]

        let page = try ProjectGitCodec.decodeDiffPage(payload)

        #expect(page.lines.map(\.kind) == [.header, .deletion, .addition])
        #expect(page.lines.last?.content == "    value: true  ")
    }

    @Test func diffAcceptsRepeatedNoNewlineMarkersWithOffsetStableIdentity() throws {
        let repeated = LoopdyJSONValue.object([
            "kind": .string("no_newline"),
            "oldLine": .null,
            "newLine": .null,
            "content": .string("No newline at end of file"),
        ])
        let payload: [String: LoopdyJSONValue] = [
            "path": .string("Loopdy/App.swift"),
            "side": .string("worktree"),
            "availability": .string("available"),
            "offset": .integer(40),
            "lines": .array([repeated, repeated]),
            "nextOffset": .null,
        ]

        let page = try ProjectGitCodec.decodeDiffPage(payload)

        #expect(page.lines.map(\.id) == ["40", "41"])
        #expect(page.lines.map(\.kind) == [.noNewline, .noNewline])
    }

    @Test(arguments: [
        InvalidStatusFixture.duplicatePaths,
        .invalidStatusToken,
        .negativeCounts,
        .absolutePath,
        .controlCharacter,
    ])
    func statusRejectsUnsafeOrAmbiguousResults(_ fixture: InvalidStatusFixture) {
        var payload = Self.statusPayload
        fixture.mutate(&payload)
        #expect(throws: LoopdyLinkWorkspaceClientError.invalidResponse) {
            _ = try ProjectGitCodec.decodeStatus(payload)
        }
    }

    @Test func diffRejectsUnknownLineKindsAndMoreThanFiveHundredRows() {
        for lines in [
            [LoopdyJSONValue.object(["kind": .string("mystery"), "oldLine": .null, "newLine": .null, "content": .string("x")])],
            Array(repeating: .object(["kind": .string("context"), "oldLine": .integer(1), "newLine": .integer(1), "content": .string("x")]), count: 501),
        ] {
            let payload: [String: LoopdyJSONValue] = [
                "path": .string("Loopdy/App.swift"), "side": .string("worktree"),
                "availability": .string("available"), "offset": .integer(0),
                "lines": .array(lines), "nextOffset": .null,
            ]
            #expect(throws: LoopdyLinkWorkspaceClientError.invalidResponse) {
                _ = try ProjectGitCodec.decodeDiffPage(payload)
            }
        }
    }

    @Test func diffRejectsControlCharactersInsideIndentedCode() {
        let payload: [String: LoopdyJSONValue] = [
            "path": .string("plugin.yaml"), "side": .string("worktree"),
            "availability": .string("available"), "offset": .integer(0),
            "lines": .array([.object([
                "kind": .string("addition"), "oldLine": .null, "newLine": .integer(1),
                "content": .string("    value:\u{0000} true"),
            ])]),
            "nextOffset": .null,
        ]

        #expect(throws: LoopdyLinkWorkspaceClientError.invalidResponse) {
            _ = try ProjectGitCodec.decodeDiffPage(payload)
        }
    }

    enum InvalidStatusFixture: CaseIterable, CustomTestStringConvertible {
        case duplicatePaths, invalidStatusToken, negativeCounts, absolutePath, controlCharacter
        var testDescription: String {
            switch self {
            case .duplicatePaths: "duplicate paths"
            case .invalidStatusToken: "invalid status token"
            case .negativeCounts: "negative counts"
            case .absolutePath: "absolute path"
            case .controlCharacter: "control character"
            }
        }
        func mutate(_ payload: inout [String: LoopdyJSONValue]) {
            switch self {
            case .duplicatePaths:
                payload["files"] = .array([Self.firstFile, Self.firstFile])
            case .invalidStatusToken:
                payload["statusToken"] = .string("md5:not-allowed")
            case .negativeCounts:
                payload["changes"] = .object(["files": .integer(-1), "insertions": .integer(14), "deletions": .integer(3)])
            case .absolutePath:
                payload["files"] = .array([.object(Self.file(path: "/private/secret"))])
            case .controlCharacter:
                payload["files"] = .array([.object(Self.file(path: "Loopdy/Bad\u{0007}.swift"))])
            }
        }
        static var firstFile: LoopdyJSONValue { .object(file(path: "Loopdy/App.swift")) }
        static func file(path: String) -> [String: LoopdyJSONValue] {
            ["path": .string(path), "originalPath": .null, "index": .string("M"), "worktree": .string("M"), "kind": .string("ordinary"), "insertions": .integer(10), "deletions": .integer(3), "isBinary": .boolean(false)]
        }
    }

    private static var statusPayload: [String: LoopdyJSONValue] {
        [
            "workspaceId": .string("project-loopdy"),
            "statusToken": .string("sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
            "head": .object(["oid": .string(String(repeating: "a", count: 40)), "branch": .string("main"), "detached": .boolean(false), "upstream": .string("origin/main"), "ahead": .integer(1), "behind": .integer(0)]),
            "files": .array([
                .object(InvalidStatusFixture.file(path: "Loopdy/App.swift")),
                .object(["path": .string("Loopdy/New.swift"), "originalPath": .null, "index": .string("."), "worktree": .string("?"), "kind": .string("untracked"), "insertions": .integer(4), "deletions": .integer(0), "isBinary": .boolean(false)]),
            ]),
            "filesPage": .object(["offset": .integer(0), "limit": .integer(500), "returned": .integer(2), "total": .integer(2), "nextOffset": .null, "complete": .boolean(true)]),
            "staged": .object(["files": .integer(1), "insertions": .integer(10), "deletions": .integer(3)]),
            "changes": .object(["files": .integer(2), "insertions": .integer(14), "deletions": .integer(3)]),
            "conflicts": .array([]),
            "conflictsPage": .object(["offset": .integer(0), "limit": .integer(500), "returned": .integer(0), "total": .integer(0), "nextOffset": .null, "complete": .boolean(true)]),
            "dirty": .boolean(true),
        ]
    }

}
