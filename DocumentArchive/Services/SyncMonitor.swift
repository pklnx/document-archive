import CoreData
import Foundation
import Observation
#if os(macOS)
import Security
#endif

/// Beobachtet die CloudKit-Synchronisation, die SwiftData intern über
/// NSPersistentCloudKitContainer abwickelt, und stellt den Status für die Oberfläche bereit.
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
    /// Ob der Datenspeicher tatsächlich mit CloudKit verbunden ist (wird beim Start gesetzt).
    var isCloudKitEnabled = false
    private var observer: NSObjectProtocol?

    var isICloudSignedIn: Bool { FileManager.default.ubiquityIdentityToken != nil }

    /// Ob die App mit iCloud/CloudKit-Berechtigung signiert ist. Unsignierte Entwicklungs-Builds
    /// haben sie nicht – dann kann SwiftData nur lokal speichern.
    nonisolated static var hasCloudKitEntitlement: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains("CloudKit") ?? false
        #else
        // iOS-Apps laufen nur signiert; ohne iCloud-Berechtigung liefert das System kein Identitäts-Token.
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
            state = .failed(error ?? "Unbekannter Fehler")
        }
    }
}
