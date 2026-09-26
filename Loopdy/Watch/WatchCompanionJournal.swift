import Foundation

/// A durable at-most-once submission fence, not a claim of backend exactly-once execution.
/// Interrupted pending work becomes unconfirmed on relaunch; it is NEVER submitted again.
struct WatchCompanionJournal: Codable {
    var authorityID = UUID()
    var scopeDigest = ""
    var revision: UInt64 = 0
    var receipts: [WatchCompanionReceipt] = []

    mutating func recover() {
        receipts = receipts.filter { Date().timeIntervalSince($0.completedAt) < 86_400 }.map {
            guard $0.phase == .pending else { return $0 }
            return WatchCompanionReceipt(
                id: $0.id, authorityID: $0.authorityID, targetID: $0.targetID,
                phase: .unconfirmed,
                message: "iPhone restarted before confirmation. Check the session on iPhone; do not resend blindly.",
                completedAt: .now
            )
        }
    }

    mutating func record(_ receipt: WatchCompanionReceipt) throws {
        receipts.removeAll { Date().timeIntervalSince($0.completedAt) >= 86_400 }
        if let index = receipts.firstIndex(where: { $0.id == receipt.id }) {
            receipts[index] = receipt
        } else {
            guard receipts.count < 128 else { throw WatchCompanionValidationError.tooManyItems }
            receipts.append(receipt)
        }
        try save()
    }

    func save() throws {
        try WatchCompanionPersistence.save(self, name: "phone-journal-v2")
    }
}

/// The composition supplies current authenticated account + selected host as an opaque LOCAL scope.
/// Only a random authority ID and coarse Link state are transmitted to Watch.
struct WatchPhoneAuthority {
    let scope: String?
    let link: WatchPhoneLinkState
    static let unavailable = Self(scope: nil, link: .unavailable)
}
