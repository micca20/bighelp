import SwiftUI
import Testing
@testable import Bighelp

@MainActor
struct BighelpSideMenuTests {
    /// The Mac title bar's sidebar button does nothing while there's no sidebar
    /// to show (first-run setup), then each click asks the shell to toggle it.
    @Test func titleBarRequestsToggleOnlyWhenThereIsASidebar() {
        let menu = BighelpSideMenu()
        menu.requestToggle()
        #expect(menu.toggleRequests == 0)
        menu.canToggle = true
        menu.requestToggle()
        menu.requestToggle()
        #expect(menu.toggleRequests == 2)
    }

    @Test func showingAndHidingReportsTheCloseOnce() {
        let menu = BighelpSideMenu()
        var closes = 0
        menu.show(AnyView(Text("Menu"))) { closes += 1 }
        #expect(menu.isOpen)
        menu.hide()
        menu.hide()
        #expect(!menu.isOpen)
        #expect(closes == 1)
    }
}
