import Foundation

enum CustomThemeSaveOutcome: Equatable, Sendable {
    case created
    case updated
}

enum CustomThemeStoreError: Error, Equatable, Sendable {
    case limitReached(maximum: Int)
    case persistenceFailed
}

enum CustomThemeImportTransactionError: Error, Equatable, Sendable {
    case identifierAlreadyExists
    case invalidStagedTheme
    case persistenceReadbackFailed
}

enum CustomThemePersistenceError: Error, Equatable, Sendable {
    case malformedData
    case invalidCatalog
    case unsupportedSchemaVersion(found: Int, current: Int)
}

struct CustomThemeCatalog: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let themes: [CustomTheme]

    init(themes: [CustomTheme]) {
        schemaVersion = Self.currentSchemaVersion
        self.themes = themes
    }
}

struct CustomThemePersistenceLoadResult {
    let themes: [CustomTheme]
    let error: CustomThemePersistenceError?
    let requiresMigration: Bool
}

enum CustomThemePersistence {
    static let currentSchemaVersion = CustomThemeCatalog.currentSchemaVersion

    private struct Version: Decodable {
        let schemaVersion: Int
    }

    private struct LegacyEnvelope: Decodable {
        let schemaVersion: Int
        let items: [CustomTheme]
    }

    static func load(
        _ data: Data?,
        maximumThemeCount: Int
    ) -> CustomThemePersistenceLoadResult {
        guard let data else {
            return CustomThemePersistenceLoadResult(
                themes: [],
                error: nil,
                requiresMigration: false
            )
        }

        let decoder = JSONDecoder()
        let version: Int
        do {
            version = try decoder.decode(Version.self, from: data).schemaVersion
        } catch {
            return failure(.malformedData)
        }

        guard version >= 0 else { return failure(.malformedData) }
        guard version <= currentSchemaVersion else {
            return failure(.unsupportedSchemaVersion(
                found: version,
                current: currentSchemaVersion
            ))
        }

        let themes: [CustomTheme]
        let requiresMigration: Bool
        do {
            switch version {
            case 0:
                themes = try decoder.decode(LegacyEnvelope.self, from: data).items
                requiresMigration = true
            case currentSchemaVersion:
                themes = try decoder.decode(CustomThemeCatalog.self, from: data).themes
                requiresMigration = false
            default:
                return failure(.malformedData)
            }
        } catch {
            return failure(.malformedData)
        }

        guard themes.count <= maximumThemeCount,
              Set(themes.map(\.id)).count == themes.count
        else {
            return failure(.invalidCatalog)
        }
        return CustomThemePersistenceLoadResult(
            themes: themes,
            error: nil,
            requiresMigration: requiresMigration
        )
    }

    static func encode(_ themes: [CustomTheme]) throws -> Data {
        try JSONEncoder().encode(CustomThemeCatalog(themes: themes))
    }

    private static func failure(
        _ error: CustomThemePersistenceError
    ) -> CustomThemePersistenceLoadResult {
        CustomThemePersistenceLoadResult(
            themes: [],
            error: error,
            requiresMigration: false
        )
    }
}
