import Foundation

struct GitHubDeviceCode: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresIn: Int
    let interval: Int

    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri"
        case expiresIn = "expires_in", interval
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            deviceCode: values.decode(String.self, forKey: .deviceCode),
            userCode: values.decode(String.self, forKey: .userCode),
            verificationURI: values.decode(URL.self, forKey: .verificationURI),
            expiresIn: values.decode(Int.self, forKey: .expiresIn),
            interval: values.decode(Int.self, forKey: .interval)
        )
    }

    private init(deviceCode: String, userCode: String, verificationURI: URL, expiresIn: Int, interval: Int) throws {
        guard Self.validCode(deviceCode), Self.validCode(userCode),
              GitHubURLPolicy.verification(verificationURI),
              (1...86_400).contains(expiresIn), (1...86_400).contains(interval), interval <= expiresIn
        else { throw GitHubError.invalidResponse }
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresIn = expiresIn
        self.interval = interval
    }

    static func decode(data: Data) throws -> GitHubDeviceCode {
        let object = try GitHubJSON.parse(data, limit: 16_384).object()
        let rawURL = try object.required("verification_uri").string()
        guard let url = URL(string: rawURL) else { throw GitHubError.invalidResponse }
        return try GitHubDeviceCode(
            deviceCode: object.required("device_code").string(max: 1024),
            userCode: object.required("user_code").string(max: 128),
            verificationURI: url,
            expiresIn: object.required("expires_in").integer(min: 1, max: 86_400),
            interval: object.required("interval").integer(min: 1, max: 86_400)
        )
    }

    private static func validCode(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && value.unicodeScalars.allSatisfy {
            (33...126).contains($0.value)
        }
    }

    var description: String { "GitHubDeviceCode(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["authorization": "<redacted>"]) }
}

/// Only this presentation projection belongs in observable UI state.
struct GitHubDevicePrompt: Equatable, Sendable {
    let userCode: String
    let verificationURI: URL
    let expiresAt: Date
}
