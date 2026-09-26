import SwiftUI
import UniformTypeIdentifiers

struct CustomThemeCatalogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }
    var catalog: CustomThemeCatalog

    init(catalog: CustomThemeCatalog) { self.catalog = catalog }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        catalog = try JSONDecoder().decode(CustomThemeCatalog.self, from: data)
        guard catalog.schemaVersion == CustomThemeCatalog.currentSchemaVersion,
              catalog.themes.count <= SettingsStore.maximumCustomThemes,
              Set(catalog.themes.map(\.id)).count == catalog.themes.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try JSONEncoder().encode(catalog))
    }
}

struct CustomThemePortableDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
