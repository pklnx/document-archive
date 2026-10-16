import Foundation
#if os(iOS)
import UIKit
#endif

/// Lets a running folder-copy pass finish when the app goes to the background (iOS asks for
/// extra time with `beginBackgroundTask`; macOS keeps running anyway). There is no background
/// polling: the next pass starts when the app is active again.
@MainActor
enum BackgroundActivity {
    static func run<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        #if os(iOS)
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: name) {
            // Out of time: files are written atomically, so the pass can stop anywhere.
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        defer {
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
        #endif
        return try await body()
    }
}
