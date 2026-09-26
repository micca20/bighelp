import Foundation
import Security

/// The retired paired-Direct runtime is gone. Account erasure still removes its
/// device-only credentials using the original Keychain service, and only then.
@MainActor
final class LoopdyDirectProtectedStore {
    private let service: String
    init(service: String = "app.loopdy.mobile.direct.v1") { self.service = service }

    func eraseAll() throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    private enum StoreError: Error { case keychain(OSStatus) }
}
