import Foundation
import Testing
@testable import Bighelp

struct BighelpMacUpdateFeedTests {
    @Test func testFeedMustBeHTTPSOrThisMac() {
        for value in [
            "https://updates.example.com/appcast.xml",
            "http://127.0.0.1:8471/appcast.xml",
            "http://localhost:8471/appcast.xml",
            "http://[::1]:8471/appcast.xml",
            "  https://updates.example.com/appcast.xml\n",
        ] {
            #expect(BighelpMacUpdateFeed.overrideURL(value) != nil, "\(value)")
        }
        for value in [
            nil, "", "   ", "appcast.xml", "/tmp/appcast.xml", "file:///tmp/appcast.xml",
            "http://192.168.1.20/appcast.xml", "http://updates.example.com/appcast.xml",
            "http://127.0.0.1.example.com/appcast.xml", "ftp://127.0.0.1/appcast.xml",
            "https://user:secret@updates.example.com/appcast.xml",
            "https://updates.example.com/" + String(repeating: "a", count: 2100),
        ] as [String?] {
            #expect(BighelpMacUpdateFeed.overrideURL(value) == nil, "\(value ?? "nil")")
        }
    }

    @Test func settingsShowTheVersionWithItsBuild() {
        let label = BighelpMacUpdateFeed.versionLabel
        #expect(label(["CFBundleShortVersionString": "2.3.0", "CFBundleVersion": "61"]) == "2.3.0 (61)")
        #expect(label(["CFBundleShortVersionString": "2.3.0"]) == "2.3.0")
        #expect(label(["CFBundleShortVersionString": "2.3.0", "CFBundleVersion": "2.3.0"]) == "2.3.0")
        #expect(label(nil) == "")
    }
}
