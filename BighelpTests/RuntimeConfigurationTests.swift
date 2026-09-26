import Foundation
import Testing
@testable import Bighelp

struct RuntimeConfigurationTests {
    @Test func linkOriginComesFromTheSignedAppConfiguration() throws {
        let url = try BighelpRuntimeConfiguration.linkBaseURL(infoDictionary: [
            "BighelpLinkBaseURL": "https://link.loopdy.app",
        ])

        #expect(url.absoluteString == "https://link.loopdy.app")
    }

    @Test func linkOriginRejectsCredentialsPathsQueriesAndCleartext() {
        for value in [
            "http://link.loopdy.app",
            "https://secret@link.loopdy.app",
            "https://link.loopdy.app/v1",
            "https://link.loopdy.app?account=secret",
        ] {
            #expect(throws: BighelpRuntimeConfiguration.Error.self) {
                try BighelpRuntimeConfiguration.linkBaseURL(infoDictionary: [
                    "BighelpLinkBaseURL": value,
                ])
            }
        }
    }
}
