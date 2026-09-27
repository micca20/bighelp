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

    @Test(arguments: ["http://100.64.0.1:9119", "http://100.127.255.254:9119", "http://127.0.0.1:9119", "http://[::1]:9119",
                      "http://[fd7a:115c:a1e0::1]:9119",
                      // Regular VPNs, home and office networks.
                      "http://10.8.0.5:9119", "http://172.16.0.1", "http://172.31.255.254:9119", "http://192.168.1.20:9119",
                      "http://[fd12:3456::1]:9119", "http://hermes.local:9119", "http://hermes.lan", "http://hermes.internal:9119",
                      "http://nas.home.arpa", "http://hermes:9119"])
    func privateHTTPRequiresExplicitOptIn(address: String) throws {
        #expect(throws: (any Error).self) { _ = try DirectHermesEndpoint(address: address) }
        let endpoint = try DirectHermesEndpoint(address: address, allowPrivateHTTP: true)
        #expect(endpoint.baseURL.scheme == "http")
    }

    @Test(arguments: ["http://100.63.255.255:9119", "http://100.128.0.1:9119", "http://example.com", "http://192.0.2.1",
                      "http://[2001:db8::1]:9119", "http://127.0.0.1.example.com", "http://172.32.0.1", "http://11.0.0.1",
                      "http://local.example.com", "http://internal.com", "http://hermes.lan.example.com"])
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

    /// iOS must also let plain HTTP through to the same private addresses the
    /// app allows, or the connection fails before reaching the network.
    @Test(arguments: ["http://10.255.255.1:9/", "http://192.168.255.254:9/", "http://172.20.0.1:9/",
                      "http://bighelp-probe.internal/", "http://bighelp-probe.lan/", "http://bighelp-probe.home.arpa/",
                      "http://bighelp-probe.local/", "http://bighelp-probe/"])
    func privateHTTPPassesAppTransportSecurity(address: String) async {
        #expect(await Self.transportSecurityBlocks(address) == false)
    }

    @Test func publicHTTPIsStillBlockedByAppTransportSecurity() async {
        #expect(await Self.transportSecurityBlocks("http://example.com/") == true)
    }

    private static func transportSecurityBlocks(_ address: String) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: URL(string: address)!)
            return false
        } catch {
            return (error as NSError).code == NSURLErrorAppTransportSecurityRequiresSecureConnection
        }
    }
}
