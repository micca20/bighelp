import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

enum LoopdyLinkPasskeyError: Error, Equatable {
    case invalidOptions
    case unavailable
    case prfUnavailable
    case unexpectedCredential
    case requestInProgress
}

struct LoopdyLinkPasskeyRequest: Equatable {
    let registration: Bool
    let relyingPartyID: String
    let challenge: Data
    let userID: Data?
    let userName: String?
    let displayName: String?
    let credentialIDs: [Data]

    static func parse(
        registration: Bool,
        options: [String: Any]
    ) throws -> LoopdyLinkPasskeyRequest {
        guard
            let encodedChallenge = options["challenge"] as? String,
            let challenge = try? LoopdyLinkBase64URL.decode(encodedChallenge)
        else { throw LoopdyLinkPasskeyError.invalidOptions }

        let relyingPartyID: String?
        if registration {
            relyingPartyID = (options["rp"] as? [String: Any])?["id"] as? String
        } else {
            relyingPartyID = options["rpId"] as? String
        }
        guard let relyingPartyID, validRelyingPartyID(relyingPartyID) else {
            throw LoopdyLinkPasskeyError.invalidOptions
        }

        var userID: Data?
        var userName: String?
        var displayName: String?
        if registration {
            guard
                let user = options["user"] as? [String: Any],
                let encodedUserID = user["id"] as? String,
                let decodedUserID = try? LoopdyLinkBase64URL.decode(encodedUserID),
                let parsedUserName = user["name"] as? String,
                !parsedUserName.isEmpty,
                let parsedDisplayName = user["displayName"] as? String,
                !parsedDisplayName.isEmpty
            else { throw LoopdyLinkPasskeyError.invalidOptions }
            userID = decodedUserID
            userName = parsedUserName
            displayName = parsedDisplayName
        }

        let descriptorKey = registration ? "excludeCredentials" : "allowCredentials"
        let rawDescriptors = options[descriptorKey] as? [Any] ?? []
        let credentialIDs = try rawDescriptors.map { raw -> Data in
            guard
                let descriptor = raw as? [String: Any],
                let encodedID = descriptor["id"] as? String,
                let credentialID = try? LoopdyLinkBase64URL.decode(encodedID)
            else { throw LoopdyLinkPasskeyError.invalidOptions }
            return credentialID
        }
        return LoopdyLinkPasskeyRequest(
            registration: registration,
            relyingPartyID: relyingPartyID,
            challenge: challenge,
            userID: userID,
            userName: userName,
            displayName: displayName,
            credentialIDs: credentialIDs
        )
    }

    private static func validRelyingPartyID(_ value: String) -> Bool {
        guard
            !value.isEmpty,
            value.count <= 253,
            value == value.lowercased(),
            !value.contains("/"),
            !value.contains(":"),
            !value.contains(where: \.isWhitespace),
            let components = URLComponents(string: "https://\(value)"),
            components.host == value,
            components.path.isEmpty
        else { return false }
        return true
    }
}

@available(iOS 18.0, *)
@MainActor
final class LoopdyLinkPasskeyCoordinator: NSObject, LoopdyLinkPasskeyAuthorizing {
    private static let prfSalt = Data(
        SHA256.hash(data: Data("loopdy-link-account-key-prf-v1".utf8))
    )

    private var continuation: CheckedContinuation<LoopdyLinkPasskeyAuthorization, Error>?
    private var pendingRegistration = false

    func authorize(
        registration: Bool,
        options: [String: Any]
    ) async throws -> LoopdyLinkPasskeyAuthorization {
        guard continuation == nil else { throw LoopdyLinkPasskeyError.requestInProgress }
        let parsed = try LoopdyLinkPasskeyRequest.parse(
            registration: registration,
            options: options
        )
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: parsed.relyingPartyID
        )
        let request: ASAuthorizationRequest
        if registration {
            guard let userID = parsed.userID, let userName = parsed.userName else {
                throw LoopdyLinkPasskeyError.invalidOptions
            }
            let registrationRequest = provider.createCredentialRegistrationRequest(
                challenge: parsed.challenge,
                name: userName,
                userID: userID
            )
            registrationRequest.displayName = parsed.displayName
            registrationRequest.userVerificationPreference = .required
            registrationRequest.attestationPreference = .none
            registrationRequest.excludedCredentials = parsed.credentialIDs.map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
            }
            registrationRequest.prf = .inputValues(.init(saltInput1: Self.prfSalt))
            request = registrationRequest
        } else {
            let assertionRequest = provider.createCredentialAssertionRequest(
                challenge: parsed.challenge
            )
            assertionRequest.userVerificationPreference = .required
            assertionRequest.allowedCredentials = parsed.credentialIDs.map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
            }
            assertionRequest.prf = .inputValues(.init(saltInput1: Self.prfSalt))
            request = assertionRequest
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.pendingRegistration = registration
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func complete(
        _ result: Result<LoopdyLinkPasskeyAuthorization, Error>
    ) {
        let pending = continuation
        continuation = nil
        pendingRegistration = false
        pending?.resume(with: result)
    }

    private static func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}

@available(iOS 18.0, *)
extension LoopdyLinkPasskeyCoordinator: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        do {
            if pendingRegistration,
               let credential = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
                guard
                    let attestation = credential.rawAttestationObject,
                    credential.prf?.isSupported == true,
                    let first = credential.prf?.first
                else { throw LoopdyLinkPasskeyError.prfUnavailable }
                complete(.success(LoopdyLinkPasskeyAuthorization(
                    response: [
                        "id": LoopdyLinkBase64URL.encode(credential.credentialID),
                        "rawId": LoopdyLinkBase64URL.encode(credential.credentialID),
                        "response": [
                            "attestationObject": LoopdyLinkBase64URL.encode(attestation),
                            "clientDataJSON": LoopdyLinkBase64URL.encode(
                                credential.rawClientDataJSON
                            ),
                            "transports": ["internal"],
                        ],
                        "clientExtensionResults": [:],
                        "type": "public-key",
                        "authenticatorAttachment": "platform",
                    ],
                    wrappingKey: Self.keyData(first)
                )))
                return
            }
            if !pendingRegistration,
               let credential = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialAssertion,
               let first = credential.prf?.first {
                complete(.success(LoopdyLinkPasskeyAuthorization(
                    response: [
                        "id": LoopdyLinkBase64URL.encode(credential.credentialID),
                        "rawId": LoopdyLinkBase64URL.encode(credential.credentialID),
                        "response": [
                            "authenticatorData": LoopdyLinkBase64URL.encode(
                                credential.rawAuthenticatorData
                            ),
                            "clientDataJSON": LoopdyLinkBase64URL.encode(
                                credential.rawClientDataJSON
                            ),
                            "signature": LoopdyLinkBase64URL.encode(credential.signature),
                            "userHandle": LoopdyLinkBase64URL.encode(credential.userID),
                        ],
                        "clientExtensionResults": [:],
                        "type": "public-key",
                        "authenticatorAttachment": "platform",
                    ],
                    wrappingKey: Self.keyData(first)
                )))
                return
            }
            throw LoopdyLinkPasskeyError.unexpectedCredential
        } catch {
            complete(.failure(error))
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        complete(.failure(error))
    }
}

@available(iOS 18.0, *)
extension LoopdyLinkPasskeyCoordinator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? ASPresentationAnchor()
    }
}

@MainActor
final class LoopdyLinkUnavailablePasskeyAuthorizer: LoopdyLinkPasskeyAuthorizing {
    func authorize(
        registration: Bool,
        options: [String: Any]
    ) async throws -> LoopdyLinkPasskeyAuthorization {
        throw LoopdyLinkPasskeyError.unavailable
    }
}
