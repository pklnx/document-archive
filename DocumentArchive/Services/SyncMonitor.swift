import CoreData
import Foundation
import Observation
#if os(macOS)
import Security
#endif

/// Observes the CloudKit sync that SwiftData runs internally through
/// NSPersistentCloudKitContainer, and provides its state to the UI.
@MainActor
@Observable
final class SyncMonitor {
    enum State: Equatable {
        case idle
        case syncing
        case succeeded(Date)
        case failed(String)
    }

    static let shared = SyncMonitor()
    static let containerIdentifier = "iCloud.de.patrickklein.DocumentArchive"

    private(set) var state: State = .idle
    private(set) var lastSuccess: Date?
    /// Whether the store is actually connected to CloudKit (set at launch).
    var isCloudKitEnabled = false
    private var observer: NSObjectProtocol?

    var isICloudSignedIn: Bool { FileManager.default.ubiquityIdentityToken != nil }

    /// Whether the app is signed with the iCloud/CloudKit entitlement. Unsigned development builds
    /// are not; then SwiftData can only store locally.
    nonisolated static var hasCloudKitEntitlement: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains("CloudKit") ?? false
        #else
        // iOS apps only run signed; without the iCloud entitlement the system returns no identity token.
        return FileManager.default.ubiquityIdentityToken != nil
        #endif
    }

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
            let ended = event.endDate
            let succeeded = event.succeeded
            let message = event.error?.localizedDescription
            MainActor.assumeIsolated {
                self?.handle(ended: ended, succeeded: succeeded, error: message)
            }
        }
    }

    private func handle(ended: Date?, succeeded: Bool, error: String?) {
        guard let ended else {
            state = .syncing
            return
        }
        if succeeded {
            lastSuccess = ended
            state = .succeeded(ended)
        } else {
            state = .failed(error ?? String(localized: "Unknown error"))
        }
    }
}
