import Foundation

enum BighelpCardTemplateStoreError: Error, Equatable {
    case invalidTemplate
    case unsupportedCardVersion(Int)
    case hashMismatch
    case invalidEmbeddedCard
    case downgrade(installedVersion: Int, proposedVersion: Int)
    case versionConflict(Int)
    case invalidStore
    case invalidParameters
    case unsafeSubstitution
    case missingTemplate(String)
}

final class BighelpCardTemplateStore {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let templates: [BighelpCardTemplate]
    }

    private struct ParameterDefinition {
        enum ValueType: String {
            case string
            case integer
            case number
            case boolean
        }

        let type: ValueType
        let allowedValues: [BighelpJSONValue]?
    }

    private struct ParsedParametersSchema {
        let definitions: [String: ParameterDefinition]
        let required: Set<String>
    }

    private static let schemaVersion = 1
    private static let supportedCardVersion = 1
    private static let fileName = "card-templates-v1.json"
    private static let temporaryFilePrefix = ".card-templates-"
    private static let slotExpression = try! NSRegularExpression(
        pattern: #"\{\{([A-Za-z][A-Za-z0-9_-]{0,63})\}\}"#
    )
    private static let structuralKeys: Set<String> = [
        "schema", "version", "type", "id", "source", "pointer", "op", "operation",
        "method", "root", "format", "children", "content_hash", "card_id", "origin",
        "created_at", "valid_until", "minimum_interval_seconds", "stale_after_seconds",
        "expires_at", "refresh",
    ]

    private let directory: URL
    private let fileURL: URL
    private let fileManager: FileManager
    private let fileProtection: any BighelpLocalFileProtecting
    private let protectedDataAvailability: any BighelpProtectedDataAvailabilityProviding

    init(
        dataDirectory: URL,
        fileManager: FileManager = .default,
        fileProtection: any BighelpLocalFileProtecting = BighelpLocalFileProtector(),
        protectedDataAvailability: any BighelpProtectedDataAvailabilityProviding = BighelpSystemProtectedDataAvailability()
    ) {
        directory = dataDirectory.standardizedFileURL
        fileURL = directory.appending(path: Self.fileName, directoryHint: .notDirectory)
        self.fileManager = fileManager
        self.fileProtection = fileProtection
        self.protectedDataAvailability = protectedDataAvailability
    }

    func installedTemplates() throws -> [BighelpCardTemplate] {
        try loadTemplates().sorted { $0.id < $1.id }
    }

    func template(id: String) throws -> BighelpCardTemplate? {
        try loadTemplates().first { $0.id == id }
    }

    func install(_ template: BighelpCardTemplate) throws {
        try validate(template)
        var templates = try loadTemplates()
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            let installed = templates[index]
            guard template.version >= installed.version else {
                throw BighelpCardTemplateStoreError.downgrade(
                    installedVersion: installed.version,
                    proposedVersion: template.version
                )
            }
            if template.version == installed.version {
                guard template == installed else {
                    throw BighelpCardTemplateStoreError.versionConflict(template.version)
                }
                return
            }
            templates[index] = template
        } else {
            templates.append(template)
        }
        try persist(templates)
    }

    func remove(id: String) throws {
        var templates = try loadTemplates()
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        templates.remove(at: index)
        try persist(templates)
    }

    func resetForAccountChange() throws {
        try requireBighelpProtectedData(protectedDataAvailability)
        guard fileManager.fileExists(atPath: directory.bighelpFileSystemPath) else { return }
        if fileManager.fileExists(atPath: fileURL.bighelpFileSystemPath) {
            try fileManager.removeItem(at: fileURL)
        }
        for candidate in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) where candidate.lastPathComponent.hasPrefix(Self.temporaryFilePrefix) {
            try fileManager.removeItem(at: candidate)
        }
    }

    func instantiate(
        id: String,
        parameters: [String: BighelpJSONValue]
    ) throws -> BighelpCardDocument {
        guard let template = try template(id: id) else {
            throw BighelpCardTemplateStoreError.missingTemplate(id)
        }
        let schema = try Self.parseParametersSchema(template.parametersSchema)
        try Self.validate(parameters: parameters, against: schema)
        let substituted = try Self.substitute(
            template.wireDocument,
            parameters: parameters,
            declaredNames: Set(schema.definitions.keys)
        )
        do {
            return try BighelpCardValidator.validate(
                BighelpCardTemplate.renderDocument(from: substituted)
            )
        } catch let error as BighelpCardTemplateStoreError {
            throw error
        } catch {
            throw BighelpCardTemplateStoreError.invalidEmbeddedCard
        }
    }

    private func loadTemplates() throws -> [BighelpCardTemplate] {
        guard fileManager.fileExists(atPath: fileURL.bighelpFileSystemPath) else { return [] }
        do {
            let envelope = try JSONDecoder().decode(
                Envelope.self,
                from: Data(contentsOf: fileURL)
            )
            guard envelope.schemaVersion == Self.schemaVersion,
                  Set(envelope.templates.map(\.id)).count == envelope.templates.count else {
                throw BighelpCardTemplateStoreError.invalidStore
            }
            for template in envelope.templates { try validate(template) }
            return envelope.templates
        } catch let error as BighelpCardTemplateStoreError {
            throw error
        } catch {
            throw BighelpCardTemplateStoreError.invalidStore
        }
    }

    private func persist(_ templates: [BighelpCardTemplate]) throws {
        try requireBighelpProtectedData(protectedDataAvailability)
        try fileProtection.prepareDirectory(
            directory,
            protection: .backgroundCompatible,
            fileManager: fileManager
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Envelope(
            schemaVersion: Self.schemaVersion,
            templates: templates.sorted { $0.id < $1.id }
        ))
        let temporaryURL = directory.appending(
            path: "\(Self.temporaryFilePrefix)\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )

        do {
            try fileProtection.write(
                data,
                to: temporaryURL,
                protection: .backgroundCompatible
            )
            if fileManager.fileExists(atPath: fileURL.bighelpFileSystemPath) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
            try fileProtection.apply(
                .backgroundCompatible,
                to: fileURL,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func validate(_ template: BighelpCardTemplate) throws {
        guard Self.isIdentifier(template.id),
              template.version > 0,
              Self.isBoundedText(template.name, maximum: 120),
              Self.isBoundedText(template.summary, maximum: 1_000),
              Self.isBoundedText(template.author, maximum: 120),
              Self.isBoundedText(template.license, maximum: 120),
              template.sha256.count == 64,
              template.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw BighelpCardTemplateStoreError.invalidTemplate
        }
        guard (1...Self.supportedCardVersion).contains(template.minimumCardVersion) else {
            throw BighelpCardTemplateStoreError.unsupportedCardVersion(
                template.minimumCardVersion
            )
        }
        do {
            _ = try Self.parseParametersSchema(template.parametersSchema)
        } catch {
            throw BighelpCardTemplateStoreError.invalidTemplate
        }
        let digest: String
        do {
            digest = try BighelpCardTemplate.sha256(for: template.wireDocument)
        } catch {
            throw BighelpCardTemplateStoreError.invalidTemplate
        }
        guard digest == template.sha256 else {
            throw BighelpCardTemplateStoreError.hashMismatch
        }
        do {
            _ = try BighelpCardValidator.validate(template.document)
        } catch {
            throw BighelpCardTemplateStoreError.invalidEmbeddedCard
        }
    }

    private static func parseParametersSchema(
        _ schema: [String: BighelpJSONValue]
    ) throws -> ParsedParametersSchema {
        let allowedRootKeys = Set(["type", "properties", "required", "additionalProperties"])
        guard Set(schema.keys).isSubset(of: allowedRootKeys),
              schema["type"]?.string == "object",
              schema["additionalProperties"]?.boolean == false,
              let properties = schema["properties"]?.object,
              let rawRequired = schema["required"]?.array else {
            throw BighelpCardTemplateStoreError.invalidTemplate
        }

        var definitions: [String: ParameterDefinition] = [:]
        for (name, rawDefinition) in properties {
            guard isParameterName(name),
                  let definition = rawDefinition.object,
                  Set(definition.keys).isSubset(of: Set([
                    "type", "title", "description", "default", "enum",
                  ])),
                  let rawType = definition["type"]?.string,
                  let type = ParameterDefinition.ValueType(rawValue: rawType) else {
                throw BighelpCardTemplateStoreError.invalidTemplate
            }
            let allowedValues = definition["enum"]?.array
            if let allowedValues, allowedValues.isEmpty {
                throw BighelpCardTemplateStoreError.invalidTemplate
            }
            if let title = definition["title"]?.string,
               !isBoundedText(title, maximum: 120) {
                throw BighelpCardTemplateStoreError.invalidTemplate
            }
            if let description = definition["description"]?.string,
               !isBoundedText(description, maximum: 500) {
                throw BighelpCardTemplateStoreError.invalidTemplate
            }
            let parsed = ParameterDefinition(type: type, allowedValues: allowedValues)
            if let defaultValue = definition["default"] {
                try validate(value: defaultValue, against: parsed)
            }
            if let allowedValues {
                for value in allowedValues { try validate(value: value, against: parsed) }
            }
            definitions[name] = parsed
        }

        let requiredNames = rawRequired.compactMap(\.string)
        guard requiredNames.count == rawRequired.count,
              Set(requiredNames).count == requiredNames.count,
              Set(requiredNames).isSubset(of: Set(definitions.keys)) else {
            throw BighelpCardTemplateStoreError.invalidTemplate
        }
        return ParsedParametersSchema(
            definitions: definitions,
            required: Set(requiredNames)
        )
    }

    private static func validate(
        parameters: [String: BighelpJSONValue],
        against schema: ParsedParametersSchema
    ) throws {
        guard Set(parameters.keys).isSubset(of: Set(schema.definitions.keys)),
              schema.required.isSubset(of: Set(parameters.keys)) else {
            throw BighelpCardTemplateStoreError.invalidParameters
        }
        do {
            for (name, value) in parameters {
                guard let definition = schema.definitions[name] else {
                    throw BighelpCardTemplateStoreError.invalidParameters
                }
                try validate(value: value, against: definition)
            }
        } catch {
            throw BighelpCardTemplateStoreError.invalidParameters
        }
    }

    private static func validate(
        value: BighelpJSONValue,
        against definition: ParameterDefinition
    ) throws {
        let hasExpectedType: Bool = switch (definition.type, value) {
        case (.string, .string), (.integer, .integer), (.number, .number),
             (.number, .integer), (.boolean, .boolean):
            true
        default:
            false
        }
        guard hasExpectedType,
              definition.allowedValues?.contains(value) != false else {
            throw BighelpCardTemplateStoreError.invalidParameters
        }
    }

    private static func substitute(
        _ document: [String: BighelpJSONValue],
        parameters: [String: BighelpJSONValue],
        declaredNames: Set<String>
    ) throws -> [String: BighelpJSONValue] {
        var result = document
        for key in ["title", "spoken_summary"] {
            if let value = result[key] {
                result[key] = try substituteLiteral(
                    value,
                    parameters: parameters,
                    declaredNames: declaredNames
                )
            }
        }

        for (key, value) in result where !["title", "spoken_summary", "elements", "data_sources"].contains(key) {
            try rejectSlots(in: key, declaredNames: declaredNames)
            try rejectSlots(in: value, declaredNames: declaredNames)
        }

        guard case .object(let rawElements)? = result["elements"] else {
            throw BighelpCardTemplateStoreError.invalidEmbeddedCard
        }
        var elements: [String: BighelpJSONValue] = [:]
        for (elementID, rawElement) in rawElements {
            try rejectSlots(in: elementID, declaredNames: declaredNames)
            guard case .object(var element) = rawElement else {
                throw BighelpCardTemplateStoreError.invalidEmbeddedCard
            }
            for (key, value) in element where key != "props" {
                try rejectSlots(in: key, declaredNames: declaredNames)
                try rejectSlots(in: value, declaredNames: declaredNames)
            }
            if let props = element["props"] {
                element["props"] = try substituteLiteral(
                    props,
                    parameters: parameters,
                    declaredNames: declaredNames
                )
            }
            elements[elementID] = .object(element)
        }
        result["elements"] = .object(elements)

        guard case .array(let rawSources)? = result["data_sources"] else {
            throw BighelpCardTemplateStoreError.invalidEmbeddedCard
        }
        result["data_sources"] = .array(try rawSources.map { rawSource in
            guard case .object(var source) = rawSource else {
                throw BighelpCardTemplateStoreError.invalidEmbeddedCard
            }
            for (key, value) in source where key != "request" {
                try rejectSlots(in: key, declaredNames: declaredNames)
                try rejectSlots(in: value, declaredNames: declaredNames)
            }
            guard case .object(var request)? = source["request"] else {
                throw BighelpCardTemplateStoreError.invalidEmbeddedCard
            }
            for (key, value) in request where key != "url" {
                try rejectSlots(in: key, declaredNames: declaredNames)
                try rejectSlots(in: value, declaredNames: declaredNames)
            }
            if let url = request["url"]?.string {
                request["url"] = .string(try substituteURLQuery(
                    url,
                    parameters: parameters,
                    declaredNames: declaredNames
                ))
            }
            source["request"] = .object(request)
            return .object(source)
        })
        return result
    }

    private static func substituteLiteral(
        _ value: BighelpJSONValue,
        parameters: [String: BighelpJSONValue],
        declaredNames: Set<String>
    ) throws -> BighelpJSONValue {
        switch value {
        case .string(let text):
            return try substituteString(
                text,
                parameters: parameters,
                declaredNames: declaredNames,
                preservesValueType: true
            )
        case .object(let object):
            var result: [String: BighelpJSONValue] = [:]
            for (key, nested) in object {
                try rejectSlots(in: key, declaredNames: declaredNames)
                if structuralKeys.contains(key) {
                    try rejectSlots(in: nested, declaredNames: declaredNames)
                    result[key] = nested
                } else if key == "url", let url = nested.string {
                    result[key] = .string(try substituteURLQuery(
                        url,
                        parameters: parameters,
                        declaredNames: declaredNames
                    ))
                } else {
                    result[key] = try substituteLiteral(
                        nested,
                        parameters: parameters,
                        declaredNames: declaredNames
                    )
                }
            }
            return .object(result)
        case .array(let array):
            return .array(try array.map {
                try substituteLiteral(
                    $0,
                    parameters: parameters,
                    declaredNames: declaredNames
                )
            })
        case .number, .integer, .boolean, .null:
            return value
        }
    }

    private static func substituteString(
        _ text: String,
        parameters: [String: BighelpJSONValue],
        declaredNames: Set<String>,
        preservesValueType: Bool
    ) throws -> BighelpJSONValue {
        let names = slotNames(in: text)
        guard names.isSubset(of: declaredNames) else {
            throw BighelpCardTemplateStoreError.unsafeSubstitution
        }
        guard !names.isEmpty else { return .string(text) }
        if names.count == 1,
           let name = names.first,
           text == "{{\(name)}}" {
            guard let value = parameters[name] else {
                throw BighelpCardTemplateStoreError.invalidParameters
            }
            return preservesValueType ? value : .string(try stringValue(value))
        }
        var result = text
        for name in names.sorted() {
            guard let value = parameters[name] else {
                throw BighelpCardTemplateStoreError.invalidParameters
            }
            result = result.replacingOccurrences(
                of: "{{\(name)}}",
                with: try stringValue(value)
            )
        }
        return .string(result)
    }

    private static func substituteURLQuery(
        _ rawURL: String,
        parameters: [String: BighelpJSONValue],
        declaredNames: Set<String>
    ) throws -> String {
        guard var components = URLComponents(string: rawURL),
              components.scheme != nil,
              components.host != nil else {
            throw BighelpCardTemplateStoreError.unsafeSubstitution
        }
        for protectedPart in [
            components.scheme,
            components.user,
            components.password,
            components.host,
            components.percentEncodedPath.removingPercentEncoding,
            components.fragment,
        ].compactMap({ $0 }) {
            try rejectSlots(in: protectedPart, declaredNames: declaredNames)
        }
        let originalScheme = components.scheme
        let originalHost = components.host
        let items = try (components.queryItems ?? []).map { item in
            try rejectSlots(in: item.name, declaredNames: declaredNames)
            guard let value = item.value else { return item }
            let substituted = try substituteString(
                value,
                parameters: parameters,
                declaredNames: declaredNames,
                preservesValueType: false
            )
            guard let string = substituted.string else {
                throw BighelpCardTemplateStoreError.invalidParameters
            }
            return URLQueryItem(name: item.name, value: string)
        }
        components.queryItems = items.isEmpty ? nil : items
        guard components.scheme == originalScheme,
              components.host == originalHost,
              let url = components.url,
              (try? BighelpCardNetworkPolicy.validate(url)) != nil else {
            throw BighelpCardTemplateStoreError.unsafeSubstitution
        }
        return url.absoluteString
    }

    private static func rejectSlots(
        in value: BighelpJSONValue,
        declaredNames: Set<String>
    ) throws {
        switch value {
        case .string(let text): try rejectSlots(in: text, declaredNames: declaredNames)
        case .object(let object):
            for (key, nested) in object {
                try rejectSlots(in: key, declaredNames: declaredNames)
                try rejectSlots(in: nested, declaredNames: declaredNames)
            }
        case .array(let array):
            for nested in array { try rejectSlots(in: nested, declaredNames: declaredNames) }
        case .number, .integer, .boolean, .null:
            break
        }
    }

    private static func rejectSlots(
        in text: String,
        declaredNames: Set<String>
    ) throws {
        guard slotNames(in: text).isDisjoint(with: declaredNames) else {
            throw BighelpCardTemplateStoreError.unsafeSubstitution
        }
    }

    private static func slotNames(in text: String) -> Set<String> {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(slotExpression.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[swiftRange])
        })
    }

    private static func stringValue(_ value: BighelpJSONValue) throws -> String {
        switch value {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        case .object, .array, .null:
            throw BighelpCardTemplateStoreError.invalidParameters
        }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128,
              let first = value.utf8.first,
              (first >= 97 && first <= 122) || (first >= 48 && first <= 57) else {
            return false
        }
        return value.utf8.allSatisfy {
            ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isParameterName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64,
              let first = value.utf8.first,
              (first >= 65 && first <= 90) || (first >= 97 && first <= 122) else {
            return false
        }
        return value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
        }
    }

    private static func isBoundedText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
