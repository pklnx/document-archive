import SwiftUI

extension Binding where Value == Bool {
    /// `true` while `item` is set. When the system dismisses the alert or dialog (swipe down, tap
    /// outside an iPad popover, Escape), it sets this to `false`, which clears `item`.
    ///
    /// Use it with the `presenting:` variants of `alert` and `confirmationDialog`, so the actions
    /// get the item even if it is cleared before they run.
    ///
    /// On the main actor like the views that use it: the item is often a SwiftData model, so the
    /// binding is not `Sendable`, and only main-actor closures may capture it.
    @MainActor
    init<Item>(presenting item: Binding<Item?>) {
        self.init(
            get: { @MainActor in item.wrappedValue != nil },
            set: { @MainActor isPresented in
                if !isPresented { item.wrappedValue = nil }
            }
        )
    }
}
