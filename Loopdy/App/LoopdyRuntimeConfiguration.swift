import Foundation

enum LoopdyRuntimeConfiguration {
    static func nativeAcceptanceStorageID(
        arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UUID? {
        #if DEBUG && targetEnvironment(simulator)
        guard arguments.contains("-native-workspace-acceptance"),
              let value = environment["LOOPDY_UI_TEST_RUN_ID"] else { return nil }
        return UUID(uuidString: value)
        #else
        return nil
        #endif
    }

    static func nativeAcceptanceLinkOrigin(
        arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL? {
        guard nativeAcceptanceStorageID(arguments: arguments, environment: environment) != nil else { return nil }
        guard let raw = environment["LOOPDY_TEST_LINK_ORIGIN"], raw.utf8.count <= 2_048,
              let url = URL(string: raw), url.host == "127.0.0.1", let port = url.port,
              (1...65_535).contains(port) else { throw Error.invalidLinkOrigin }
        return try linkBaseURL(infoDictionary: ["LoopdyLinkBaseURL": raw])
    }

    enum Error: Swift.Error, Equatable {
        case missingLinkOrigin
        case invalidLinkOrigin
    }

    static func linkBaseURL(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) throws -> URL {
        guard let rawValue = infoDictionary["LoopdyLinkBaseURL"] as? String else {
            throw Error.missingLinkOrigin
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty || components.path == "/"
        else { throw Error.invalidLinkOrigin }

        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        origin.port = components.port
        guard let url = origin.url else { throw Error.invalidLinkOrigin }
        return url
    }
}
