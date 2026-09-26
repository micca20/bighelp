import Foundation
import Testing
@testable import Loopdy

struct LoopdyCardNetworkPolicyTests {
    @Test func acceptsOnlyPublicCredentialFreeHTTPSGetDestinations() throws {
        let accepted = try LoopdyCardNetworkPolicy.validate(
            #require(URL(string: "https://api.example.com/data?symbol=BTC"))
        )
        #expect(accepted.url.scheme == "https")
        #expect(accepted.url.host == "api.example.com")

        let rejected = [
            "http://api.example.com/data",
            "ftp://api.example.com/data",
            "https://user:pass@api.example.com/data",
            "https://api.example.com:8443/data",
            "https://api.example.com/data#fragment",
            "https://localhost/data",
            "https://service.local/data",
            "https://127.0.0.1/data",
            "https://[::1]/data",
            "https://example.com./data",
        ]
        for raw in rejected {
            let url = try #require(URL(string: raw))
            #expect(throws: LoopdyCardNetworkPolicyError.self) {
                try LoopdyCardNetworkPolicy.validate(url)
            }
        }
    }
}
