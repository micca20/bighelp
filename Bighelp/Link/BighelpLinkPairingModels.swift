import Foundation

enum BighelpLinkInstallPrompt {
    static let text = """
    Before changing anything: Ask me whether I want the bighelp managed relay or a self-hosted relay. Wait for my answer.

    For either choice, install the current official bighelp plugin for Hermes by running:

    hermes plugins install promptclickrun/bighelp-plugin --enable --force

    If I choose the bighelp managed relay, initiate secure bighelp Link pairing by running:

    hermes loopdy link pair

    If I choose a self-hosted relay, ask me for its HTTPS bighelp Link base URL. Do not guess it. Then run:

    hermes loopdy link pair --base-url <self-hosted-https-base-url>

    Give me the short-lived six-character pairing code and 16-character host verification code (and the pairing QR or URL if available) so I can approve this Hermes host in the bighelp app. Do not expose reusable credentials or private keys. After I confirm that pairing succeeded, restart the Hermes gateway and verify the connection with `hermes loopdy link status`.
    """
}

struct BighelpLinkPairingChallenge: Equatable, Sendable {
    let id: String
    let code: String
    let expiresAt: Date
}

struct BighelpLinkPairingPresentation: Equatable, Sendable {
    let challenge: BighelpLinkPairingChallenge

    var details: [String] {
        [
            "This pairing session expires at \(challenge.expiresAt.formatted(date: .omitted, time: .shortened))."
        ]
    }
}

enum BighelpLinkPairingState: Equatable, Sendable {
    case idle
    case requesting
    case ready(BighelpLinkPairingChallenge)
    case pairing
    case paired(deviceID: String)
    case expired
    case failed(String)
}

enum BighelpLinkPushEnvironment: String, Equatable, Sendable {
    case sandbox
    case production
}

enum BighelpLinkPairingCode {
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
        BighelpLinkPairingReference.fromQRPayload(payload)?.code
    }
}
