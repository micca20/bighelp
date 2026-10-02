// Prints the Sparkle public key (SUPublicEDKey) for the private key on standard input:
// the base64 EdDSA seed that Sparkle's generate_keys -x writes. Scripts/release-mac.sh
// uses it to check the Keychain's key against the app before signing an update.
//     security find-generic-password -s bighelp-sparkle-ed25519 -a bighelp -w | xcrun swift Scripts/sparkle-public-key.swift
import CryptoKit
import Foundation

let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
guard let seed = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
else {
    FileHandle.standardError.write(Data("That isn't a Sparkle EdDSA private key.\n".utf8))
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
