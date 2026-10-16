import CoreData
import Foundation
import SwiftData

/// Repairs tag cycles (`TagHierarchy.repairCycles`) after changes that did not come from this
/// device's moves: CloudKit imports and, from #8 part 2, folder reads. Concurrent moves on two
/// devices can each be valid and still form a cycle once both arrive.
///
/// Triggers: the shared `StoreChangeObserver` (debounced), and the end of a CloudKit import
/// (the event `SyncMonitor` also observes), which restarts the observer's debounce. The repair
/// saves only when it changed something, so its own save does not start an endless loop.
/// At launch, `MetadataMaintenance.mergeDuplicates` repairs right after merging.
@MainActor
final class TagCycleRepair {
    static let shared = TagCycleRepair()

    private var task: Task<Void, Never>?
    private var importToken: NSObjectProtocol?

    func start(container: ModelContainer, changes: StoreChangeObserver) {
        guard task == nil else { return }
        let stream = changes.changes()
        task = Task {
            for await _ in stream {
                TagHierarchy.repairCycles(in: container.mainContext)
            }
        }
        importToken = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak changes] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .import, event.endDate != nil else { return }
            Task { @MainActor in changes?.signal() }
        }
    }
}
