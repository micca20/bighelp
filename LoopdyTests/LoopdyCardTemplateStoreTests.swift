import Foundation
import Testing
@testable import Loopdy

struct LoopdyCardTemplateStoreTests {
    @Test func installsAndReloadsTemplate() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let template = try makeTemplate(version: 1)
        let store = makeStore(directory: directory)

        try store.install(template)

        #expect(try store.installedTemplates() == [template])
        #expect(try makeStore(directory: directory).template(id: template.id) == template)
    }

    @Test func upgradesToANewerVersion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        try store.install(makeTemplate(version: 1))
        let upgrade = try makeTemplate(
            version: 2,
            document: makeCardDocument(title: "Upgraded weather")
        )

        try store.install(upgrade)

        #expect(try store.template(id: upgrade.id) == upgrade)
    }

    @Test func rejectsDowngradesAndPreservesTheInstalledVersion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        let current = try makeTemplate(version: 2)
        try store.install(current)

        #expect(throws: LoopdyCardTemplateStoreError.downgrade(
            installedVersion: 2,
            proposedVersion: 1
        )) {
            try store.install(makeTemplate(version: 1))
        }
        #expect(try makeStore(directory: directory).template(id: current.id) == current)
    }

    @Test func rejectsHashMismatchAndPreservesTheInstalledVersion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        let current = try makeTemplate(version: 1)
        try store.install(current)
        let changedDocument = makeCardDocument(title: "Tampered")
        let tampered = try makeTemplate(
            version: 2,
            document: changedDocument,
            sha256: String(repeating: "0", count: 64)
        )

        #expect(throws: LoopdyCardTemplateStoreError.hashMismatch) {
            try store.install(tampered)
        }
        #expect(try makeStore(directory: directory).template(id: current.id) == current)
    }

    @Test func rejectsInvalidEmbeddedCardAndPreservesTheInstalledVersion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        let current = try makeTemplate(version: 1)
        try store.install(current)
        var invalidDocument = makeCardDocument(title: "Invalid upgrade")
        invalidDocument["root"] = .string("missing")
        let invalid = try makeTemplate(version: 2, document: invalidDocument)

        #expect(throws: LoopdyCardTemplateStoreError.invalidEmbeddedCard) {
            try store.install(invalid)
        }
        #expect(try makeStore(directory: directory).template(id: current.id) == current)
    }

    @Test func failedAtomicWriteLeavesPreviousVersionAndNoTemporaryFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialStore = makeStore(directory: directory)
        let current = try makeTemplate(version: 1)
        try initialStore.install(current)
        let protection = TemplateFileProtection()
        protection.failWrites = true
        let failingStore = makeStore(directory: directory, fileProtection: protection)

        #expect(throws: TemplatePersistenceFailure.write) {
            try failingStore.install(makeTemplate(
                version: 2,
                document: makeCardDocument(title: "Uncommitted")
            ))
        }

        #expect(try makeStore(directory: directory).template(id: current.id) == current)
        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remainingNames == ["card-templates-v1.json"])
        #expect(protection.writtenURLs.allSatisfy { $0.lastPathComponent.hasPrefix(".") })
    }

    @Test func usesBackgroundProtectionAndAHiddenAtomicTemporaryFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let protection = TemplateFileProtection()
        let store = makeStore(directory: directory, fileProtection: protection)

        try store.install(makeTemplate(version: 1))

        #expect(protection.events == [
            .prepare(.backgroundCompatible),
            .write(.backgroundCompatible),
            .apply(.backgroundCompatible),
        ])
        let writtenURL = try #require(protection.writtenURLs.first)
        #expect(protection.writtenURLs.count == 1)
        #expect(writtenURL.lastPathComponent.hasPrefix(".card-templates-"))
    }

    @Test func removesInstalledTemplate() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        let template = try makeTemplate(version: 1)
        try store.install(template)

        try store.remove(id: template.id)

        #expect(try store.installedTemplates().isEmpty)
        #expect(try makeStore(directory: directory).template(id: template.id) == nil)
    }

    @Test func accountResetClearsTemplatesWithoutUsingPreferences() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unrelated = directory.appending(path: "unrelated.json")
        try Data("keep".utf8).write(to: unrelated)
        let store = makeStore(directory: directory)
        try store.install(makeTemplate(version: 1))

        try store.resetForAccountChange()

        #expect(try store.installedTemplates().isEmpty)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "card-templates-v1.json").path
        ))
    }

    @Test func substitutesDeclaredLiteralSlotsAndPercentEncodesURLQueryValues() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parametersSchema = makeParametersSchema([
            "city": .object(["type": .string("string")]),
            "count": .object(["type": .string("integer")]),
        ], required: ["city", "count"])
        var document = makeCardDocument(
            title: "Weather for {{city}}",
            url: "https://api.example.com/weather?q={{city}}&count={{count}}"
        )
        guard case .object(var elements) = document["elements"],
              case .object(var text) = elements["text"],
              case .object(var props) = text["props"] else {
            Issue.record("Invalid fixture")
            return
        }
        props["value"] = .string("{{city}}")
        text["props"] = .object(props)
        elements["text"] = .object(text)
        document["elements"] = .object(elements)
        let template = try makeTemplate(
            version: 1,
            document: document,
            parametersSchema: parametersSchema
        )
        let store = makeStore(directory: directory)
        try store.install(template)

        let card = try store.instantiate(
            id: template.id,
            parameters: [
                "city": .string("Austin & admin=true"),
                "count": .integer(3),
            ]
        )

        #expect(card.title == "Weather for Austin & admin=true")
        let renderedProps = try #require(card.elements["text"]?.object?["props"]?.object)
        #expect(renderedProps["value"] == .string("Austin & admin=true"))
        let requestURL = try #require(
            card.dataSources.first?.object?["request"]?.object?["url"]?.string
        )
        let components = try #require(URLComponents(string: requestURL))
        #expect(components.scheme == "https")
        #expect(components.host == "api.example.com")
        #expect(components.queryItems == [
            URLQueryItem(name: "q", value: "Austin & admin=true"),
            URLQueryItem(name: "count", value: "3"),
        ])
        #expect(requestURL.contains("q=Austin%20%26%20admin%3Dtrue"))
    }

    @Test func rejectsSlotsInElementIDsAndPointersAndNeverReplacesStructuralFields() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parametersSchema = makeParametersSchema([
            "city": .object(["type": .string("string")]),
        ], required: ["city"])
        var document = makeCardDocument(title: "{{city}}")
        guard case .object(var elements) = document["elements"],
              case .object(var root) = elements["root"],
              case .array(var children) = root["children"],
              case .object(var text) = elements.removeValue(forKey: "text"),
              case .object(var props) = text["props"] else {
            Issue.record("Invalid fixture")
            return
        }
        props["value"] = .object([
            "source": .string("weather"),
            "pointer": .string("/{{city}}"),
        ])
        text["props"] = .object(props)
        children[0] = .string("{{city}}")
        root["children"] = .array(children)
        elements["root"] = .object(root)
        elements["{{city}}"] = .object(text)
        document["elements"] = .object(elements)
        let template = try makeTemplate(
            version: 1,
            document: document,
            parametersSchema: parametersSchema
        )
        let store = makeStore(directory: directory)
        try store.install(template)

        #expect(throws: LoopdyCardTemplateStoreError.unsafeSubstitution) {
            try store.instantiate(
                id: template.id,
                parameters: ["city": .string("austin")]
            )
        }
    }

    @Test func rejectsSlotsInComponentTypeOperationURLAuthorityAndRefreshBounds() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = makeParametersSchema([
            "slot": .object(["type": .string("string")]),
        ])
        var prohibitedDocuments: [[String: LoopdyJSONValue]] = []

        var componentType = makeCardDocument()
        guard case .object(var componentElements) = componentType["elements"],
              case .object(var componentText) = componentElements["text"] else {
            Issue.record("Invalid fixture")
            return
        }
        componentText["type"] = .string("{{slot}}")
        componentElements["text"] = .object(componentText)
        componentType["elements"] = .object(componentElements)
        prohibitedDocuments.append(componentType)

        var operation = makeCardDocument()
        guard case .object(var operationElements) = operation["elements"],
              case .object(var operationText) = operationElements["text"],
              case .object(var operationProps) = operationText["props"] else {
            Issue.record("Invalid fixture")
            return
        }
        operationProps["value"] = .object([
            "expression": .object([
                "op": .string("{{slot}}"),
                "arguments": .array([.integer(1)]),
            ]),
        ])
        operationText["props"] = .object(operationProps)
        operationElements["text"] = .object(operationText)
        operation["elements"] = .object(operationElements)
        prohibitedDocuments.append(operation)

        prohibitedDocuments.append(makeCardDocument(
            url: "{{slot}}://api.example.com/weather?q=safe"
        ))

        var refresh = makeCardDocument()
        guard case .array(var sources) = refresh["data_sources"],
              case .object(var source) = sources[0],
              case .object(var refreshBounds) = source["refresh"] else {
            Issue.record("Invalid fixture")
            return
        }
        refreshBounds["minimum_interval_seconds"] = .string("{{slot}}")
        source["refresh"] = .object(refreshBounds)
        sources[0] = .object(source)
        refresh["data_sources"] = .array(sources)
        prohibitedDocuments.append(refresh)

        for document in prohibitedDocuments {
            #expect(throws: LoopdyCardTemplateStoreError.invalidEmbeddedCard) {
                try makeStore(directory: directory).install(makeTemplate(
                    version: 1,
                    document: document,
                    parametersSchema: schema
                ))
            }
        }
    }

    @Test func rejectsSlotsInRendererOwnedFields() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = makeParametersSchema([
            "city": .object(["type": .string("string")]),
        ], required: ["city"])
        var document = makeCardDocument(title: "{{city}}")
        document["content_hash"] = .string("{{city}}" + String(repeating: "a", count: 56))
        let template = try makeTemplate(
            version: 1,
            document: document,
            parametersSchema: schema
        )
        let store = makeStore(directory: directory)
        try store.install(template)

        #expect(throws: LoopdyCardTemplateStoreError.unsafeSubstitution) {
            try store.instantiate(
                id: template.id,
                parameters: ["city": .string("austin")]
            )
        }
    }

    @Test func rejectsUndeclaredMissingAndWronglyTypedParameters() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parametersSchema = makeParametersSchema([
            "city": .object(["type": .string("string")]),
        ], required: ["city"])
        let template = try makeTemplate(
            version: 1,
            document: makeCardDocument(title: "{{city}}"),
            parametersSchema: parametersSchema
        )
        let store = makeStore(directory: directory)
        try store.install(template)

        #expect(throws: LoopdyCardTemplateStoreError.invalidParameters) {
            try store.instantiate(id: template.id, parameters: [:])
        }
        #expect(throws: LoopdyCardTemplateStoreError.invalidParameters) {
            try store.instantiate(id: template.id, parameters: [
                "city": .integer(1),
                "extra": .string("no"),
            ])
        }
    }
}

private func makeStore(
    directory: URL,
    fileProtection: any LoopdyLocalFileProtecting = TemplateFileProtection()
) -> LoopdyCardTemplateStore {
    LoopdyCardTemplateStore(
        dataDirectory: directory,
        fileProtection: fileProtection
    )
}

private func makeTemplate(
    version: Int,
    document: [String: LoopdyJSONValue]? = nil,
    parametersSchema: [String: LoopdyJSONValue] = makeParametersSchema([:]),
    sha256: String? = nil
) throws -> LoopdyCardTemplate {
    let document = document ?? makeCardDocument()
    return LoopdyCardTemplate(
        id: "weather.summary",
        version: version,
        name: "Weather summary",
        summary: "A reviewed weather card",
        author: "Loopdy",
        license: "MIT",
        minimumCardVersion: 1,
        parametersSchema: parametersSchema,
        document: try LoopdyCardDocument(document: document),
        sha256: try sha256 ?? LoopdyCardTemplate.sha256(for: document)
    )
}

private func makeParametersSchema(
    _ properties: [String: LoopdyJSONValue],
    required: [String] = []
) -> [String: LoopdyJSONValue] {
    [
        "type": .string("object"),
        "properties": .object(properties),
        "required": .array(required.map(LoopdyJSONValue.string)),
        "additionalProperties": .boolean(false),
    ]
}

private func makeCardDocument(
    title: String = "Weather",
    url: String = "https://api.example.com/weather?q=chicago"
) -> [String: LoopdyJSONValue] {
    [
        "schema": .string("loopdy.card"),
        "version": .integer(1),
        "title": .string(title),
        "spoken_summary": .string("Current weather"),
        "data_sources": .array([
            .object([
                "id": .string("weather"),
                "request": .object([
                    "method": .string("GET"),
                    "url": .string(url),
                ]),
                "response": .object([
                    "format": .string("json"),
                    "root": .string(""),
                ]),
                "refresh": .object([
                    "minimum_interval_seconds": .integer(300),
                    "stale_after_seconds": .integer(900),
                    "expires_at": .string("2026-09-05T12:00:00Z"),
                ]),
            ]),
        ]),
        "root": .string("root"),
        "elements": .object([
            "root": .object([
                "type": .string("card"),
                "props": .object([
                    "title": .string("Weather"),
                ]),
                "children": .array([.string("text")]),
            ]),
            "text": .object([
                "type": .string("text"),
                "props": .object([
                    "value": .object([
                        "source": .string("weather"),
                        "pointer": .string("/temperature"),
                    ]),
                ]),
                "children": .array([]),
            ]),
        ]),
        "content_hash": .string(String(repeating: "a", count: 64)),
        "card_id": .string(String(repeating: "b", count: 32)),
        "origin": .string("live"),
        "created_at": .string("2026-09-02T12:00:00Z"),
    ]
}

private enum TemplatePersistenceFailure: Error { case write }

private final class TemplateFileProtection: LoopdyLocalFileProtecting, @unchecked Sendable {
    enum Event: Equatable {
        case prepare(LoopdyLocalProtectionClass)
        case write(LoopdyLocalProtectionClass)
        case apply(LoopdyLocalProtectionClass)
    }

    var failWrites = false
    private(set) var events: [Event] = []
    private(set) var writtenURLs: [URL] = []

    func prepareDirectory(
        _ directory: URL,
        protection: LoopdyLocalProtectionClass,
        fileManager: FileManager
    ) throws {
        events.append(.prepare(protection))
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(
        _ data: Data,
        to file: URL,
        protection: LoopdyLocalProtectionClass
    ) throws {
        events.append(.write(protection))
        writtenURLs.append(file)
        if failWrites { throw TemplatePersistenceFailure.write }
        try data.write(to: file, options: .withoutOverwriting)
    }

    func apply(
        _ protection: LoopdyLocalProtectionClass,
        to file: URL,
        fileManager: FileManager
    ) throws {
        events.append(.apply(protection))
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "LoopdyCardTemplateStoreTests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
