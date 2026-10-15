import SwiftUI

extension Binding where Value == Bool {
    /// `true` while `item` is set. When the system dismisses the alert or dialog (swipe down, tap
    /// outside an iPad popover, Escape), it sets this to `false`, which clears `item`.
    ///
    /// Use it with the `presenting:` variants of `alert` and `confirmationDialog`, so the actions
    /// get the item even if it is cleared before they run.
    init<Item>(presenting item: Binding<Item?>) {
        self.init(
            get: { item.wrappedValue != nil },
            set: { isPresented in
                if !isPresented { item.wrappedValue = nil }
            }
        )
    }
}
