import SwiftUI

/// bighelp's own line icons (`Design/Glyphs`): a 24-pt grid, round 2-pt strokes and
/// the brand's dot. Menus and settings keep naming SF Symbols; the ones with a
/// bighelp drawing show that instead, and any other name falls back to the symbol.
enum BighelpGlyph: String, CaseIterable, Sendable {
    case agents, bars, bell, bellDot, book, bookClosed, branch, chats, chatVoice, checklist, chip, compose
    case database, doc, docRich, envelope, face, folder, gesture, grid3, group, host, kanban, key, lock
    case notebook, nodes, palette, paw, person, personCard, personCycle, plane, plug, plus, projects
    case puzzle, question, scheduled, server, settings, shield, simple, sliders, sparkles, tabBar
    case terminal, tools, tray, usage, watch, wave, wrench

    var assetName: String { "Glyph" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    init?(systemName: String) {
        guard let glyph = Self.symbols[systemName] else { return nil }
        self = glyph
    }

    private static let symbols: [String: BighelpGlyph] = [
        "desktopcomputer": .host, "plus": .plus, "folder": .folder, "square.and.pencil": .compose,
        "person.3": .group, "bubble.left.and.bubble.right": .chats, "figure.stand": .simple,
        "person.2": .agents, "calendar.badge.clock": .scheduled, "rectangle.split.3x1": .kanban,
        "gauge.with.dots.needle.50percent": .usage, "square.grid.2x2": .tools, "gearshape": .settings,
        "bell": .bell, "bell.badge": .bellDot, "checklist": .checklist, "doc": .doc, "doc.richtext": .docRich,
        "books.vertical": .book, "book": .bookClosed, "cpu": .chip, "sparkles": .sparkles,
        "wrench.and.screwdriver": .wrench, "wrench.adjustable.fill": .wrench, "brain": .notebook,
        "puzzlepiece.extension": .puzzle, "externaldrive.connected.to.line.below": .plug, "waveform": .wave,
        "arrow.triangle.branch": .branch, "key": .key, "key.fill": .key, "chart.bar": .bars,
        "doc.text.magnifyingglass": .terminal, "person.crop.rectangle.stack": .personCard,
        "tray.full": .tray, "person.crop.circle.badge.gearshape": .personCycle,
        "slider.horizontal.3": .sliders, "server.rack": .server, "network": .nodes, "lock.shield": .shield,
        "paintpalette": .palette, "rectangle.bottomthird.inset.filled": .tabBar, "internaldrive": .database,
        "envelope": .envelope, "hand.raised": .lock, "applewatch": .watch,
        "person.crop.circle.badge.checkmark": .person, "rectangle.3.group": .grid3,
        "theatermasks": .face, "theatermasks.fill": .face, "bubble.left.and.text.bubble.right": .chatVoice,
        "questionmark.circle": .question, "pawprint.fill": .paw, "hand.draw.fill": .gesture,
        "paperplane": .plane,
    ]
}

/// An SF Symbol name drawn with bighelp's glyph when there is one.
struct BighelpSymbolImage: View {
    let systemName: String

    var body: some View {
        if let glyph = BighelpGlyph(systemName: systemName) {
            Image(glyph.assetName).resizable().renderingMode(.template).scaledToFit()
        } else {
            // A symbol fills its frame; the glyphs keep a 3-pt margin on their 24-pt grid.
            Image(systemName: systemName).resizable().scaledToFit().fontWeight(.medium).scaleEffect(0.78)
        }
    }
}
