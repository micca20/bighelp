import Foundation
import Testing

struct ChatGlassArchitectureTests {
    @Test func chatChromeUsesOnlyBoundedControlGlass() throws {
        let source = try load("Loopdy/Chat/ChatView.swift")
        #expect(!source.contains("ChatFloatingChromeBackdropLayer"))
        #expect(!source.contains("ChatFloatingChromeBackdropSurface"))
        #expect(source.contains("loopdyNavigationGlass"))
    }

    @Test func presentedChatSurfacesDoNotPaintOpaqueCanvasBackings() throws {
        let picker = try load("Loopdy/DesignSystem/LoopdyModelPickerSheet.swift")
        let actions = try load("Loopdy/Chat/ChatActionMenuSheet.swift")
        let settings = try load("Loopdy/Chat/ChatSessionSettingsView.swift")
        let references = try load("Loopdy/References/ReferenceHubDrawer.swift")

        #expect(!picker.contains("presentationBackground(theme.canvas)"))
        #expect(!actions.contains(".background(theme.canvas)"))
        #expect(settings.contains(".scrollContentBackground(.hidden)"))
        #expect(!references.contains(".fill(theme.surface)"))
    }

    private func load(_ relativePath: String) throws -> String {
        let repository = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repository.appending(path: relativePath), encoding: .utf8)
    }
}