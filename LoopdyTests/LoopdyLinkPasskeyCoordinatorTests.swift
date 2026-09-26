import Foundation
import Testing
@testable import Loopdy

struct LoopdyLinkPasskeyCoordinatorTests {
    @Test func registrationOptionsAreParsedWithoutInventingProfileData() throws {
        let request = try LoopdyLinkPasskeyRequest.parse(
            registration: true,
            options: [
                "challenge": LoopdyLinkBase64URL.encode(Data("challenge".utf8)),
                "rp": ["id": "link.loopdy.example", "name": "Loopdy"],
                "user": [
                    "id": LoopdyLinkBase64URL.encode(Data("opaque-user".utf8)),
                    "name": "loopdy-opaque",
                    "displayName": "bighelp account",
                ],
                "excludeCredentials": [
                    ["id": LoopdyLinkBase64URL.encode(Data("credential".utf8))],
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
        #expect(throws: LoopdyLinkPasskeyError.invalidOptions) {
            try LoopdyLinkPasskeyRequest.parse(
                registration: false,
                options: ["challenge": "bad=", "rpId": "https://link.loopdy.example/path"]
            )
        }
    }
}
