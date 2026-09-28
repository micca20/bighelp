import BuzzKit
import CryptoKit
import Foundation
import Testing
@testable import Bighelp

struct NotificationPresentationTests {
    @Test func buzzKitPushesNameTheirChatForTheOnScreenCheck() {
        let thread = "Kq3v0x_chat-reference"
        #expect(BighelpBuzzKitPresentation.thread(["loopdy": .object(["sessionReference": .string(thread)])]) == thread)
        #expect(BighelpBuzzKitPresentation.thread(["loopdy": .object(["eventId": .string("e")])]) == nil)
        #expect(BighelpBuzzKitPresentation.thread(["loopdy": .object(["sessionReference": .string("")])]) == nil)
        #expect(BighelpBuzzKitPresentation.thread([:]) == nil)
    }

    @Test func avatarsAreCachedByHashAndCheckedOnRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = BighelpNotificationAvatarCache(directory: directory)
        let image = Data("fixture avatar".utf8)
        let hash = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()

        #expect(cache.image(sha256: hash) == nil)
        cache.store(image, sha256: hash)
        #expect(cache.image(sha256: hash) == image)
        #expect(cache.image(sha256: hash.uppercased()) == image)

        // A picture that doesn't match its hash is never stored, and a changed file is dropped.
        let other = SHA256.hash(data: Data("other".utf8)).map { String(format: "%02x", $0) }.joined()
        cache.store(image, sha256: other)
        #expect(cache.image(sha256: other) == nil)
        try Data("tampered".utf8).write(to: directory.appendingPathComponent(hash))
        #expect(cache.image(sha256: hash) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(hash).path))
        #expect(cache.image(sha256: "../../etc/passwd") == nil)
    }

    @Test func theAvatarCacheKeepsTheNewestPictures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = BighelpNotificationAvatarCache(directory: directory)
        for index in 0..<(BighelpNotificationAvatarCache.limit + 3) {
            let image = Data("avatar \(index)".utf8)
            cache.store(image, sha256: SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined())
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == BighelpNotificationAvatarCache.limit)
    }
}
