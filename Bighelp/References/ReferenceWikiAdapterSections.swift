import Foundation

/// Source-coordinate extraction, deliberately independent of WikiMarkdown's
/// display-only normalized projection. Unsupported heading syntax stays available
/// through the page option; it is never reconstructed from rendered Markdown.
enum ReferenceWikiAdapterSections {
    struct Section {
        let id: String
        let title: String
        let range: Range<Int>
    }

    private struct Heading {
        let id: String
        let title: String
        let level: Int
        let start: Int
    }

    static func sections(in data: Data) -> [Section] {
        guard data.count <= WikiLimits.readBytes else { return [] }
        let bytes = Array(data)
        var headings: [Heading] = []
        var offset = 0
        var fence: (marker: UInt8, count: Int)?
        var frontMatter = false
        while offset < bytes.count {
            let start = offset
            while offset < bytes.count, bytes[offset] != 10, bytes[offset] != 13 { offset += 1 }
            let end = offset
            if offset < bytes.count {
                let newline = bytes[offset]
                offset += 1
                if newline == 13, offset < bytes.count, bytes[offset] == 10 { offset += 1 }
            }
            var content = start
            if start == 0, end >= 3, bytes[0..<3].elementsEqual([0xEF, 0xBB, 0xBF]) { content += 3 }
            let firstContent = content
            while content < end, bytes[content] == 32 { content += 1 }
            // Four-space indented code cannot start/end a fence or heading.
            guard content - firstContent <= 3 else { continue }
            let line = bytes[content..<end]
            if start == 0, line.elementsEqual([45, 45, 45]) {
                frontMatter = true
                continue
            }
            if frontMatter {
                if line.elementsEqual([45, 45, 45]) || line.elementsEqual([46, 46, 46]) { frontMatter = false }
                continue
            }
            guard content < end else { continue }
            if let active = fence {
                var cursor = content
                while cursor < end, bytes[cursor] == active.marker { cursor += 1 }
                if cursor - content >= active.count,
                   bytes[cursor..<end].allSatisfy({ $0 == 32 || $0 == 9 }) { fence = nil }
                continue
            }
            if bytes[content] == 96 || bytes[content] == 126 {
                let marker = bytes[content]
                var cursor = content
                while cursor < end, bytes[cursor] == marker { cursor += 1 }
                if cursor - content >= 3 {
                    // Backticks in the info string do not open a CommonMark fence.
                    if marker != 96 || !bytes[cursor..<end].contains(96) {
                        fence = (marker, cursor - content)
                    }
                    continue
                }
            }
            var cursor = content
            while cursor < end, bytes[cursor] == 35 { cursor += 1 }
            let level = cursor - content
            guard (1...6).contains(level), cursor == end || bytes[cursor] == 32 || bytes[cursor] == 9 else { continue }
            // Fail closed instead of returning a section whose next boundary was
            // outside the scan budget. The full page remains independently usable.
            guard headings.count < 512 else { return [] }
            let rawHeading = Data(bytes[content..<end])
            let id = "heading-" + WikiLimits.digest(rawHeading)
            while cursor < end, bytes[cursor] == 32 || bytes[cursor] == 9 { cursor += 1 }
            let rawTitle = String(decoding: bytes[cursor..<end], as: UTF8.self)
            let title = ReferenceAdapterContent.prefix(rawTitle, maximumBytes: 256).text
            headings.append(Heading(id: id, title: title.isEmpty ? "Untitled heading" : title,
                                    level: level, start: start))
        }
        var counts: [String: Int] = [:]
        for heading in headings { counts[heading.id, default: 0] += 1 }
        var result: [Section] = []
        for (index, heading) in headings.enumerated() where counts[heading.id] == 1 {
            let next = headings.dropFirst(index + 1).first { $0.level <= heading.level }
            result.append(Section(id: heading.id, title: heading.title,
                                  range: heading.start..<(next?.start ?? bytes.count)))
        }
        return result
    }
}
