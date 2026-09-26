import Foundation
import Testing
@testable import Bighelp

struct DirectHermesEndpointTests {
    @Test func bareHostnameDefaultsToHTTPS() throws {
        let endpoint = try DirectHermesEndpoint(address: "hermes.example.ts.net:9119")
        #expect(endpoint.baseURL.scheme == "https")
        #expect(endpoint.baseURL.host == "hermes.example.ts.net")
        #expect(endpoint.baseURL.port == 9119)
    }

    @Test(arguments: ["http://100.64.0.1:9119", "http://100.127.255.254:9119", "http://127.0.0.1:9119", "http://[::1]:9119", "http://[fd7a:115c:a1e0::1]:9119"])
    func privateHTTPRequiresExplicitOptIn(address: String) throws {
        #expect(throws: (any Error).self) { _ = try DirectHermesEndpoint(address: address) }
        let endpoint = try DirectHermesEndpoint(address: address, allowPrivateHTTP: true)
        #expect(endpoint.baseURL.scheme == "http")
    }

    @Test(arguments: ["http://100.63.255.255:9119", "http://100.128.0.1:9119", "http://example.com", "http://192.0.2.1", "http://[fd7a:115c:a1e1::1]:9119", "http://127.0.0.1.example.com"])
    func explicitOptInNeverAllowsPublicPlaintext(address: String) {
        #expect(throws: (any Error).self) { _ = try DirectHermesEndpoint(address: address, allowPrivateHTTP: true) }
    }

    @Test(arguments: ["https://user:password@example.com", "https://example.com?token=fixture", "https://example.com#fragment", "file:///tmp/host", "ftp://example.com", "https://example.com:70000", "https://example.com:0", "", "https://"])
    func invalidAddressesAreRejected(address: String) {
        #expect(throws: (any Error).self) { _ = try DirectHermesEndpoint(address: address) }
    }

    @Test func distinctHostsCannotShareIdentity() throws {
        let first = try DirectHermesEndpoint(address: "https://first.example.ts.net")
        let second = try DirectHermesEndpoint(address: "https://second.example.ts.net")
        #expect(first.identity != second.identity)
        #expect(first.identity == (try DirectHermesEndpoint(address: "https://first.example.ts.net")).identity)
    }
}
