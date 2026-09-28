import Foundation
import Testing
@testable import Bighelp

struct HermesFolderPathTests {
    @Test func typedPathsListTheRightFolder() {
        #expect(HermesFolderPath.query(for: "")! == ("~", ""))
        #expect(HermesFolderPath.query(for: "~/")! == ("~", ""))
        #expect(HermesFolderPath.query(for: "~/pro")! == ("~", "pro"))
        #expect(HermesFolderPath.query(for: "~/Projects/")! == ("~/Projects", ""))
        #expect(HermesFolderPath.query(for: "/")! == ("/", ""))
        #expect(HermesFolderPath.query(for: "/srv/work")! == ("/srv", "work"))
        #expect(HermesFolderPath.query(for: "projects") == nil)
    }

    @Test func homePathsExpandAndShorten() {
        #expect(HermesFolderPath.expanded("~/Projects/app/", home: "/Users/demo") == "/Users/demo/Projects/app")
        #expect(HermesFolderPath.expanded("~", home: "/Users/demo") == "/Users/demo")
        #expect(HermesFolderPath.expanded("~/x", home: nil) == nil)
        #expect(HermesFolderPath.expanded("/srv/app/", home: nil) == "/srv/app")
        #expect(HermesFolderPath.abbreviated("/Users/demo/Projects", home: "/Users/demo") == "~/Projects")
        #expect(HermesFolderPath.abbreviated("/Users/demolition", home: "/Users/demo") == "/Users/demolition")
        #expect(HermesFolderPath.home(listed: "~/Projects", fullPath: "/Users/demo/Projects") == "/Users/demo")
        #expect(HermesFolderPath.home(listed: "~", fullPath: "/Users/demo") == "/Users/demo")
        #expect(HermesFolderPath.parent(of: "/Users") == "/")
        #expect(HermesFolderPath.parent(of: "/") == nil)
        #expect(HermesFolderPath.isAccepted("~/a") && HermesFolderPath.isAccepted("/a") && !HermesFolderPath.isAccepted("a"))
    }

    @Test func hostListingKeepsMatchingFoldersOnly() throws {
        func entry(_ name: String, directory: Bool = true) -> BighelpJSONValue {
            .object(["name": .string(name), "path": .string("/Users/demo/\(name)"), "isDirectory": .boolean(directory)])
        }
        let response = BighelpJSONValue.object(["entries": .array([
            entry("my-project"), entry("Projects"), entry(".config"), entry("project.txt", directory: false), entry("Music"),
        ])])
        let page = try HermesFolderListing.page(response, requestedPath: "~", prefix: "proj", offset: 0, limit: 10)
        #expect(page.parentPath == "/Users/demo")
        #expect(page.folders.map(\.name) == ["Projects", "my-project"])
        let hidden = try HermesFolderListing.page(response, requestedPath: "~", prefix: ".", offset: 0, limit: 10)
        #expect(hidden.folders.map(\.name) == [".config"])
        let all = try HermesFolderListing.page(response, requestedPath: "~", prefix: "", offset: 0, limit: 2)
        #expect(all.folders.map(\.name) == ["Music", "my-project"])
        #expect(all.nextOffset == 2)
        let missing = BighelpJSONValue.object(["entries": .array([]), "error": .string("ENOENT")])
        #expect(throws: WorkspaceClientError.self) {
            try HermesFolderListing.page(missing, requestedPath: "/nope", prefix: "", offset: 0, limit: 10)
        }
    }
}
