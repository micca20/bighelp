import Foundation

enum LoopdyLinkInstallPrompt {
    static let text = """
    Before changing anything: Ask me whether I want the Loopdy managed relay or a self-hosted relay. Wait for my answer.

    For either choice, install the current official Loopdy plugin for Hermes by running:

    hermes plugins install promptclickrun/loopdy-ios/plugins/loopdy --enable --force

    If I choose the Loopdy managed relay, initiate secure Loopdy Link pairing by running:

    hermes loopdy link pair

    If I choose a self-hosted relay, ask me for its HTTPS Loopdy Link base URL. Do not guess it. Then run:

    hermes loopdy link pair --base-url <self-hosted-https-base-url>

    Give me the short-lived six-character pairing code and 16-character host verification code (and the pairing QR or URL if available) so I can approve this Hermes host in the Loopdy app. Do not expose reusable credentials or private keys. After I confirm that pairing succeeded, restart the Hermes gateway and verify the connection with `hermes loopdy link status`.
    """
}

struct LoopdyLinkPairingChallenge: Equatable, Sendable {
    let id: String
    let code: String
    let expiresAt: Date
}

struct LoopdyLinkPairingPresentation: Equatable, Sendable {
    let challenge: LoopdyLinkPairingChallenge

    var details: [String] {
        [
            "This pairing session expires at \(challenge.expiresAt.formatted(date: .omitted, time: .shortened))."
        ]
    }
}

enum LoopdyLinkPairingState: Equatable, Sendable {
    case idle
    case requesting
    case ready(LoopdyLinkPairingChallenge)
    case pairing
    case paired(deviceID: String)
    case expired
    case failed(String)
}

enum LoopdyLinkPushEnvironment: String, Equatable, Sendable {
    case sandbox
    case production
}

enum LoopdyLinkPairingCode {
    static func normalized(_ proposedCode: String) -> String? {
        let normalized = proposedCode
            .uppercased()
            .filter { $0 != "-" && !$0.isWhitespace }
        guard normalized.count == 6 else { return nil }
        guard normalized.unicodeScalars.allSatisfy({ scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
        }) else { return nil }
        return normalized
    }

    static func fromQRPayload(_ payload: String) -> String? {
        LoopdyLinkPairingReference.fromQRPayload(payload)?.code
    }
}
