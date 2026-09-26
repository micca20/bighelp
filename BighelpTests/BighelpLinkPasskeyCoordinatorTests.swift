import Foundation
import Testing
@testable import Bighelp

struct BighelpLinkPasskeyCoordinatorTests {
    @Test func registrationOptionsAreParsedWithoutInventingProfileData() throws {
        let request = try BighelpLinkPasskeyRequest.parse(
            registration: true,
            options: [
                "challenge": BighelpLinkBase64URL.encode(Data("challenge".utf8)),
                "rp": ["id": "link.loopdy.example", "name": "bighelp"],
                "user": [
                    "id": BighelpLinkBase64URL.encode(Data("opaque-user".utf8)),
                    "name": "loopdy-opaque",
                    "displayName": "bighelp account",
                ],
                "excludeCredentials": [
                    ["id": BighelpLinkBase64URL.encode(Data("credential".utf8))],
                ],
            ]
        )

        #expect(request.relyingPartyID == "link.loopdy.example")
        #expect(request.challenge == Data("challenge".utf8))
        #expect(request.userID == Data("opaque-user".utf8))
        #expect(request.userName == "loopdy-opaque")
        #expect(request.displayName == "bighelp account")
        #expect(request.credentialIDs == [Data("credential".utf8)])
    }

    @Test func malformedOrInsecureRelyingPartyOptionsAreRejected() {
        #expect(throws: BighelpLinkPasskeyError.invalidOptions) {
            try BighelpLinkPasskeyRequest.parse(
                registration: false,
                options: ["challenge": "bad=", "rpId": "https://link.loopdy.example/path"]
            )
        }
    }
}
