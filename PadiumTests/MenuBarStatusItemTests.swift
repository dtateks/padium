import Testing
@testable import Padium

@Suite("MenuBarStatusPresentation")
struct MenuBarStatusPresentationTests {
    private static let statuses: [RuntimeStatus] = [.checking, .permissionsRequired, .degraded, .active]

    @Test("title is non-empty for every status")
    func titleNonEmpty() {
        for status in Self.statuses {
            #expect(!MenuBarStatusPresentation.title(for: status).isEmpty)
        }
    }

    @Test("titles are distinct across statuses")
    func titlesDistinct() {
        let titles = Self.statuses.map(MenuBarStatusPresentation.title(for:))
        #expect(Set(titles).count == titles.count)
    }

    @Test("menu items emit symbol name for every status")
    func menuItemSymbolName() {
        for status in Self.statuses {
            #expect(!MenuBarStatusPresentation.symbolName(for: status).isEmpty)
        }
    }

    @Test("menu item symbol names are distinct")
    func menuItemSymbolsDistinct() {
        let symbols = Self.statuses.map(MenuBarStatusPresentation.symbolName(for:))
        #expect(Set(symbols).count == symbols.count)
    }

    @Test("menu bar icon uses the quiet brand symbol when active")
    func menuBarSymbolForActive() {
        #expect(MenuBarStatusPresentation.menuBarSymbolName(for: .active) == "hand.tap.fill")
    }

    @Test("menu bar icon escalates to a warning glyph in attention states")
    func menuBarSymbolForAttentionStates() {
        #expect(MenuBarStatusPresentation.menuBarSymbolName(for: .degraded) == "exclamationmark.triangle.fill")
        #expect(MenuBarStatusPresentation.menuBarSymbolName(for: .permissionsRequired) == "exclamationmark.shield.fill")
    }

    @Test("menu bar icon distinguishes the checking state from active")
    func menuBarSymbolForChecking() {
        let checking = MenuBarStatusPresentation.menuBarSymbolName(for: .checking)
        let active = MenuBarStatusPresentation.menuBarSymbolName(for: .active)
        #expect(checking != active)
        #expect(!checking.isEmpty)
    }
}
