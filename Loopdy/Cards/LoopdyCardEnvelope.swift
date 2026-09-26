import Foundation

enum LoopdyCardEnvelope: Codable, Equatable, Sendable {
    case legacy(GenerativeUICard)
    case card(LoopdyCardDocument)

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Header.self)
        let schema = try container.decode(String.self, forKey: .schema)
        let version = try container.decode(Int.self, forKey: .version)
        switch (schema, version) {
        case ("loopdy.card", 1):
            let card = try LoopdyCardDocument(from: decoder)
            self = .card(try LoopdyCardValidator.validateForStaticRelease(card))
        case ("loopdy.generative_ui", 1), ("loopdy.generative_ui", 2):
            self = .legacy(try GenerativeUICard(from: decoder))
        default:
            throw LoopdyCardEnvelopeError.unsupported(schema: schema, version: version)
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .legacy(let value): try value.encode(to: encoder)
        case .card(let value): try value.encode(to: encoder)
        }
    }

    private enum Header: String, CodingKey { case schema, version }
}

enum LoopdyCardEnvelopeError: Error, Equatable {
    case unsupported(schema: String, version: Int)
}

enum LoopdyCardRendererResult {
    static let deliverySchema = "loopdy.card_delivery"
    static let deliveryInstruction = "Calling the renderer does not display the card. Include display_markdown exactly once in the assistant answer."

    static func decode(_ data: Data) throws -> LoopdyCardEnvelope {
        if let raw = try? JSONDecoder().decode(LoopdyCardEnvelope.self, from: data) {
            return raw
        }
        let value = try JSONDecoder().decode([String: LoopdyJSONValue].self, from: data)
        guard Set(value.keys) == Set(["schema", "version", "card", "display_markdown", "instruction"]),
              value["schema"]?.string == deliverySchema,
              value["version"]?.integer == 1,
              value["instruction"]?.string == deliveryInstruction,
              let cardObject = value["card"]?.object,
              let markdown = value["display_markdown"]?.string else {
            throw LoopdyCardEnvelopeError.unsupported(schema: value["schema"]?.string ?? "", version: value["version"]?.integer ?? 0)
        }
        let cardData = try JSONEncoder.sorted.encode(cardObject)
        let card = try JSONDecoder().decode(LoopdyCardEnvelope.self, from: cardData)
        let prefix = "```loopdy-card\n"
        let suffix = "\n```"
        guard markdown.hasPrefix(prefix), markdown.hasSuffix(suffix) else {
            throw LoopdyCardEnvelopeError.unsupported(schema: deliverySchema, version: 1)
        }
        let start = markdown.index(markdown.startIndex, offsetBy: prefix.count)
        let end = markdown.index(markdown.endIndex, offsetBy: -suffix.count)
        let fenced = Data(markdown[start..<end].utf8)
        let fencedCard = try JSONDecoder().decode(LoopdyCardEnvelope.self, from: fenced)
        guard fencedCard == card else {
            throw LoopdyCardEnvelopeError.unsupported(schema: deliverySchema, version: 1)
        }
        return card
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension LoopdyCardEnvelope {
    var id: String {
        switch self {
        case .legacy(let card): card.id
        case .card(let card): card.id
        }
    }

    var title: String {
        switch self {
        case .legacy(let card): card.title
        case .card(let card): card.title
        }
    }

    var component: GenerativeUIComponent? {
        guard case .legacy(let card) = self else { return nil }
        return card.component
    }

    var legacyCard: GenerativeUICard? {
        guard case .legacy(let card) = self else { return nil }
        return card
    }

    var documentCard: LoopdyCardDocument? {
        guard case .card(let card) = self else { return nil }
        return card
    }
}
