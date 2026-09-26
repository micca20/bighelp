import Foundation

enum BotModeRoomCacheSchema {
    static let currentVersion = 2
    static let repositoryName = "bot-mode-rooms-native-v2"
    static let legacyRepositoryName = "bot-mode-rooms"

    static var migrations: [DemoRepositoryMigration] {
        [DemoRepositoryMigration(fromVersion: 1) { $0 }]
    }
}
