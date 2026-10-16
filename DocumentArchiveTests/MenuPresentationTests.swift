import Testing
@testable import DocumentArchive

/// Confirmations that a menu item asks for wait until the menu has closed (iOS), so their popover
/// does not anchor to a closing menu. Regression: on iPadOS 26, More → Delete in the document
/// sometimes showed no confirmation at all.
@MainActor @Suite struct MenuPresentationTests {
    private final class Flag {
        var isSet = false
    }

    @Test func presentsAfterTheMenuHasClosed() async throws {
        let presented = Flag()
        MenuPresentation.afterMenuCloses { presented.isSet = true }

        #if os(iOS)
        // Not while the menu is still closing.
        #expect(!presented.isSet)
        await Task.yield()
        #expect(!presented.isSet)
        #else
        // macOS menus have closed when their action runs.
        #expect(presented.isSet)
        #endif

        try await Task.sleep(for: MenuPresentation.menuClosingTime + .seconds(1))
        #expect(presented.isSet)
    }

    @Test func waitsLongEnoughForTheMenuToClose() {
        // iOS needs about a third of a second to close a menu; much longer feels unresponsive.
        #expect(MenuPresentation.menuClosingTime >= .milliseconds(350))
        #expect(MenuPresentation.menuClosingTime <= .seconds(1))
    }
}
