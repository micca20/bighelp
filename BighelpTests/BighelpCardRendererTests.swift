import Testing
@testable import Bighelp

struct BighelpCardRendererTests {
    @Test func rendererAndValidatorShareTheFiniteFourteenComponentCatalog() {
        #expect(BighelpCardRenderer.supportedTypes == Set([
            "card", "vstack", "hstack", "grid", "text", "metric", "badge",
            "progress", "chart", "table", "list", "divider", "spacer", "image",
        ]))
        #expect(BighelpCardValidator.supportedElementTypes == BighelpCardRenderer.supportedTypes)
    }
}
