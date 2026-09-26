import Foundation
import Darwin

struct HostAuthenticationDiscovery: Equatable {
    struct Provider: Equatable, Identifiable {
        let id: String
        let name: String
        let supportsPassword: Bool
    }
    let endpoint: DirectHermesEndpoint
    let requiresAuthentication: Bool
    let nativePKCE: Bool
    let providers: [Provider]
    var supportsToken: Bool { true }
    var supportsDashboard: Bool { !requiresAuthentication }
    var supportsPassword: Bool { nativePKCE && !providers.filter(\.supportsPassword).isEmpty }
    var supportsBrowser: Bool { nativePKCE && !providers.isEmpty }

    @MainActor
    static func discover(endpoint: DirectHermesEndpoint) async throws -> Self {
        let authenticator = DirectHermesAuthenticator(endpoint: endpoint)
        defer { authenticator.http.invalidate() }
        let discovery = try await authenticator.discoverAuthentication()
        return Self(endpoint: endpoint, requiresAuthentication: discovery.authRequired,
            nativePKCE: discovery.supportsNativePKCE,
            providers: discovery.providers.map { Provider(id: $0.name, name: $0.displayName, supportsPassword: $0.supportsPassword) })
    }
}

/// Keep the port a separate explicit input. Reject conflicting URL/port values
/// rather than silently changing the endpoint after credentials were entered.
enum HostAddressInput {
    static func endpoint(address: String, port: String, allowPrivateHTTP: Bool) throws -> DirectHermesEndpoint {
        var input = address
        if !input.contains("://") {
            var ipv6 = in6_addr()
            if inet_pton(AF_INET6, input, &ipv6) == 1 { input = "[\(input)]" }
            input = "https://" + input
        }
        // Validate the original address too: URLComponents must not repair tokens.
        let original = try DirectHermesEndpoint(address: address, allowPrivateHTTP: allowPrivateHTTP)
        guard !port.isEmpty else { return original }
        guard port.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(port), (1...65535).contains(number),
              var components = URLComponents(string: input), components.port == nil || components.port == number else {
            throw DirectHermesError.invalidEndpoint
        }
        components.port = number
        guard let url = components.url else { throw DirectHermesError.invalidEndpoint }
        return try DirectHermesEndpoint(address: url.absoluteString, allowPrivateHTTP: allowPrivateHTTP)
    }
}
