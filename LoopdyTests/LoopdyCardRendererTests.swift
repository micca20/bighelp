import Testing
@testable import Loopdy

struct LoopdyCardRendererTests {
    @Test func rendererAndValidatorShareTheFiniteFourteenComponentCatalog() {
        #expect(LoopdyCardRenderer.supportedTypes == Set([
            "card", "vstack", "hstack", "grid", "text", "metric", "badge",
            "progress", "chart", "table", "list", "divider", "spacer", "image",
        ]))
        #expect(LoopdyCardValidator.supportedElementTypes == LoopdyCardRenderer.supportedTypes)
    }
}
