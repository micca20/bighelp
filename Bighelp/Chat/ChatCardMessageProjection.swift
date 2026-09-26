import Foundation

/// Ordered projection of assistant Markdown. The original message remains the
/// copy/export authority; this projection is presentation-only.
struct ChatCardMessageProjection: Equatable, Sendable {
    enum Segment: Equatable, Sendable {
        case markdown(MarkdownDocument)
        case card(BighelpCardEnvelope)
    }

    static let fenceLanguage = "loopdy-card"
    static let maximumCardBytes = 65_536

    let segments: [Segment]
    let cardIDs: Set<String>

    init(source: String, role: TimelineRole) {
        guard role == .assistant else {
            segments = [.markdown(MarkdownDocument(source))]
            cardIDs = []
            return
        }

        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let opening = "```\(Self.fenceLanguage)"
        var projected: [Segment] = []
        var markdownLines: [String] = []
        var identities = Set<String>()
        var index = 0

        func flushMarkdown() {
            guard !markdownLines.isEmpty else { return }
            let source = markdownLines.joined(separator: "\n")
            if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                projected.append(.markdown(MarkdownDocument(source)))
            }
            markdownLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.drop(while: { $0 == " " })
            let indentation = line.count - trimmed.count
            guard indentation <= 3, trimmed == opening else {
                markdownLines.append(line)
                index += 1
                // A card shown inside an ordinary code example is not a card
                // instruction. Consume the outer Markdown fence as one block.
                if indentation <= 3, let marker = trimmed.first, marker == "`" || marker == "~" {
                    let fenceLength = trimmed.prefix(while: { $0 == marker }).count
                    if fenceLength >= 3 {
                        while index < lines.count {
                            let candidate = lines[index]
                            markdownLines.append(candidate)
                            index += 1
                            let closing = candidate.drop(while: { $0 == " " })
                            let count = closing.prefix(while: { $0 == marker }).count
                            if candidate.count - closing.count <= 3, count >= fenceLength,
                               closing.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { break }
                        }
                    }
                }
                continue
            }

            var closingIndex: Int?
            var cursor = index + 1
            while cursor < lines.count {
                if lines[cursor].trimmingCharacters(in: .whitespaces) == "```" {
                    closingIndex = cursor
                    break
                }
                cursor += 1
            }
            guard let closingIndex else {
                markdownLines.append(contentsOf: lines[index...])
                index = lines.count
                continue
            }

            let body = lines[(index + 1)..<closingIndex].joined(separator: "\n")
            guard let data = body.data(using: .utf8),
                  data.count <= Self.maximumCardBytes,
                  let envelope = try? JSONDecoder().decode(BighelpCardEnvelope.self, from: data),
                  identities.insert(envelope.id).inserted else {
                markdownLines.append(contentsOf: lines[index...closingIndex])
                index = closingIndex + 1
                continue
            }

            flushMarkdown()
            projected.append(.card(envelope))
            index = closingIndex + 1
        }

        flushMarkdown()
        segments = projected.isEmpty ? [.markdown(MarkdownDocument(normalized))] : projected
        cardIDs = identities
    }
}
