import SwiftUI
import Testing
@testable import DocumentArchive

/// Alerts and dialogs must use real bindings: the system dismisses them by setting the binding to
/// `false` (swipe down, tap outside an iPad popover), which a `.constant` binding ignores.
@Suite struct PresentationBindingTests {
    /// Holds the presented item like a view's `@State`.
    private final class Box<Item> {
        var item: Item?
        init(_ item: Item?) { self.item = item }
        var binding: Binding<Item?> { Binding(get: { self.item }, set: { self.item = $0 }) }
    }

    @Test func presentedWhileTheItemIsSet() {
        let box = Box<String>(nil)
        let isPresented = Binding(presenting: box.binding)
        #expect(!isPresented.wrappedValue)

        box.item = "Rechnung"
        #expect(isPresented.wrappedValue)
    }

    @Test func dismissingClearsTheItem() {
        let box = Box("Rechnung")
        let isPresented = Binding(presenting: box.binding)

        isPresented.wrappedValue = false

        #expect(box.item == nil)
    }

    @Test func settingTrueKeepsTheItem() {
        let box = Box("Rechnung")
        Binding(presenting: box.binding).wrappedValue = true
        #expect(box.item == "Rechnung")
    }
}
