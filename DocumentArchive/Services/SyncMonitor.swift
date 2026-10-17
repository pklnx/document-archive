import CoreData
import Foundation
import Observation
import os
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

    /// Info.plist key filled from the build setting `DA_CLOUDKIT_ENABLED` (see Config/Project.xcconfig).
    nonisolated static let cloudKitFlagKey = "DACloudKitEnabled"

    /// Whether this build may use CloudKit. The build flag must be on – it is only set for builds
    /// signed with the paid Apple Developer team – and on macOS the CloudKit entitlement must be
    /// present as well. Being signed in to iCloud alone is not enough: ad-hoc signed simulator and
    /// unsigned builds must never open a CloudKit store.
    nonisolated static func cloudKitAvailable(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        hasEntitlement: () -> Bool = { hasCloudKitEntitlement }
    ) -> Bool {
        guard isOn(infoDictionary?[cloudKitFlagKey]) else { return false }
        #if os(macOS)
        return hasEntitlement()
        #else
        return true
        #endif
    }

    /// Reads a Boolean Info.plist value written as `YES`/`NO` by the build setting.
    nonisolated private static func isOn(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return ["yes", "true", "1"].contains(string)
    }

    /// Whether the app is signed with the iCloud/CloudKit entitlement (macOS). Unsigned development
    /// builds are not; then SwiftData can only store locally.
    nonisolated static var hasCloudKitEntitlement: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains("CloudKit") ?? false
        #else
        return true   // iOS has no public API for this; the build flag decides
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
            let kind = Self.name(of: event.type)
            let code = event.error.map { Log.code(of: $0) }
            MainActor.assumeIsolated {
                self?.handle(kind: kind, ended: ended, succeeded: succeeded, error: message, code: code)
            }
        }
    }

    /// The event type for the log (`.public`).
    nonisolated private static func name(of type: NSPersistentCloudKitContainer.EventType) -> String {
        switch type {
        case .setup: "setup"
        case .import: "import"
        case .export: "export"
        @unknown default: "event \(type.rawValue)"
        }
    }

    private func handle(kind: String, ended: Date?, succeeded: Bool, error: String?, code: String?) {
        guard let ended else {
            Log.sync.notice("CloudKit \(kind, privacy: .public) started")
            state = .syncing
            return
        }
        if succeeded {
            Log.sync.notice("CloudKit \(kind, privacy: .public) succeeded")
            lastSuccess = ended
            state = .succeeded(ended)
        } else {
            Log.sync.error("CloudKit \(kind, privacy: .public) failed: \(code ?? "no error", privacy: .public) \(error ?? "", privacy: .private)")
            state = .failed(error ?? String(localized: "Unknown error"))
        }
    }
}
