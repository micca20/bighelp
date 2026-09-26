import Foundation
import Network

struct LoopdyCardValidatedPublicGET: Sendable, Equatable {
    let url: URL
}

enum LoopdyCardNetworkPolicyError: Error, Equatable { case invalidURL }

enum LoopdyCardNetworkPolicy {
    private static let deniedSuffixes = ["localhost", "local", "internal", "home", "lan", "arpa"]

    static func validate(_ url: URL) throws -> LoopdyCardValidatedPublicGET {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.fragment == nil,
              components.port == nil || components.port == 443,
              let rawHost = components.host?.lowercased(),
              rawHost == rawHost.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !rawHost.isEmpty, rawHost.utf8.count <= 253,
              rawHost.contains("."),
              !rawHost.split(separator: ".").contains(where: { $0.isEmpty }),
              !rawHost.contains(":") else { throw LoopdyCardNetworkPolicyError.invalidURL }
        let labels = rawHost.split(separator: ".")
        if IPv4Address(rawHost) != nil || IPv6Address(rawHost) != nil {
            throw LoopdyCardNetworkPolicyError.invalidURL
        }
        guard labels.allSatisfy({ label in
            label.count <= 63
                && label.first != "-"
                && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else { throw LoopdyCardNetworkPolicyError.invalidURL }
        guard !deniedSuffixes.contains(where: { rawHost == $0 || rawHost.hasSuffix("." + $0) }) else {
            throw LoopdyCardNetworkPolicyError.invalidURL
        }
        if let host = components.host, (host.contains("%") || host.rangeOfCharacter(from: CharacterSet(charactersIn: "[]")) != nil) {
            throw LoopdyCardNetworkPolicyError.invalidURL
        }
        return LoopdyCardValidatedPublicGET(url: components.url ?? url)
    }
}
