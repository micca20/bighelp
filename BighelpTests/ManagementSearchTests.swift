import Testing
@testable import Bighelp

/// Search on Plugins, MCP Servers, Messaging, Toolsets, Skills and Webhooks.
struct ManagementSearchTests {
    @Test func noSearchMatchesEverything() {
        #expect(ManagementSearch.matches("", "Firecrawl"))
        #expect(ManagementSearch.matches("   ", nil))
        #expect(!ManagementSearch.isActive(" \n"))
        #expect(ManagementSearch.isActive("git"))
    }

    @Test func everyWordHasToAppearSomewhereInTheRow() {
        #expect(ManagementSearch.matches("web search", "Web", "Search the internet"))
        #expect(ManagementSearch.matches("SEARCH", "web", "search the internet"))
        #expect(!ManagementSearch.matches("web image", "Web", "Search the internet"))
        #expect(ManagementSearch.matches("cafe", "Café notes", nil))
        #expect(!ManagementSearch.matches("slack", nil, "Telegram"))
    }
}
