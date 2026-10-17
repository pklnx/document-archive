import Foundation
import OSLog

/// One entry of the app's log, read back from unified logging.
struct DiagnosticEntry: Equatable, Sendable {
    enum Level: String, Sendable {
        case undefined, debug, info, notice, error, fault
    }

    var date: Date
    var level: Level
    /// The `Logger` category (`import`, `ocr`, `mistral`, `mirror`, `sync`, `store`).
    var category: String
    /// The message as unified logging returns it: values logged as `.private` arrive as
    /// `<private>` (always in release builds).
    var message: String
}

/// The diagnostics report: a header about the app and the device, optional sections, and the
/// log of this launch. It is the **one** report builder of the app (maintainer decision on #42):
/// "Export Diagnostics…" in the settings writes `text()` into a file, and #23 adds its sync section
/// (events, error domains and codes, no descriptions) through `sections` and offers "Copy
/// Diagnostics" on the same text.
///
/// Formatting is a pure function of the stored values, so it is tested without the log store. The
/// report adds nothing private of its own: no titles, names, paths, keys or error descriptions.
struct DiagnosticsReport: Equatable, Sendable {
    struct Header: Equatable, Sendable {
        var appVersion: String
        var build: String
        /// "macOS", "iOS" or "iPadOS".
        var system: String
        var systemVersion: String
        var deviceModel: String
        var sandboxed: Bool
        /// `ArchiveStore.OpenedStore`, e.g. "local".
        var store: String
        /// The build setting `DA_CLOUDKIT_ENABLED` (and, on the Mac, the entitlement).
        var cloudKitAllowed: Bool
        /// Whether the open store syncs through CloudKit.
        var cloudKitActive: Bool
        /// Whether a folder for the folder copy is chosen.
        var folderCopy: Bool
    }

    /// A titled block of lines after the header.
    struct Section: Equatable, Sendable {
        var title: String
        var lines: [String]
    }

    var created: Date
    var header: Header
    var sections: [Section] = []
    var entries: [DiagnosticEntry]
    /// Why the log could not be read (error domain and code); `nil` when it was read.
    var logError: String?

    /// The report as plain text (English: it is read by whoever helps, not shown in the app).
    func text(timeZone: TimeZone = .current) -> String {
        var lines = [
            "Document Archive diagnostics",
            "Created: \(Self.format(created, timeZone: timeZone, fractionalSeconds: false))",
            "",
            "App: \(header.appVersion) (\(header.build))",
            "System: \(header.system) \(header.systemVersion)",
            "Device: \(header.deviceModel)",
            "Sandboxed: \(Self.yesNo(header.sandboxed))",
            "Store: \(header.store)",
            "CloudKit allowed by this build: \(Self.yesNo(header.cloudKitAllowed))",
            "CloudKit sync active: \(Self.yesNo(header.cloudKitActive))",
            "Folder copy: \(header.folderCopy ? "folder chosen" : "off")",
        ]
        for section in sections {
            lines += ["", section.title] + section.lines
        }
        lines += ["", "Log of this launch (\(entries.count) entries)"]
        if let logError { lines.append("The log could not be read: \(logError)") }
        lines += entries.map { line(for: $0, timeZone: timeZone) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One log line: time, level, category, message. Line breaks inside a message are indented,
    /// so every entry starts on its own line.
    func line(for entry: DiagnosticEntry, timeZone: TimeZone = .current) -> String {
        let message = entry.message.replacingOccurrences(of: "\n", with: "\n    ")
        return "\(Self.format(entry.date, timeZone: timeZone, fractionalSeconds: true))  \(entry.level.rawValue)  \(entry.category)  \(message)"
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func format(_ date: Date, timeZone: TimeZone, fractionalSeconds: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = fractionalSeconds ? "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ" : "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter.string(from: date)
    }
}

/// Builds the diagnostics report from the running app (Settings → General → Diagnostics).
enum Diagnostics {
    /// The header for this launch.
    @MainActor
    static func currentHeader(info: [String: Any]? = Bundle.main.infoDictionary) -> DiagnosticsReport.Header {
        DiagnosticsReport.Header(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            system: DeviceInfo.systemName,
            systemVersion: DeviceInfo.systemVersion,
            deviceModel: DeviceInfo.modelIdentifier,
            sandboxed: AppSandbox.isActive,
            store: ArchiveStore.opened?.rawValue ?? "not opened",
            cloudKitAllowed: SyncMonitor.cloudKitAvailable(),
            cloudKitActive: SyncMonitor.shared.isCloudKitEnabled,
            folderCopy: ArchiveMirrorController.shared.isEnabled
        )
    }

    /// The report with this launch's log; the log store is read off the main actor.
    @MainActor
    static func makeReport(now: Date = .now) async -> DiagnosticsReport {
        let header = currentHeader()
        let read = await Task.detached(priority: .userInitiated) { () -> Result<[DiagnosticEntry], Error> in
            Result { try readEntries() }
        }.value
        switch read {
        case .success(let entries):
            return DiagnosticsReport(created: now, header: header, entries: entries)
        case .failure(let error):
            return DiagnosticsReport(created: now, header: header, entries: [], logError: Log.code(of: error))
        }
    }

    /// The app's log entries of this process (this launch), oldest first. `.debug` entries are
    /// never stored and `.info` only for a while, so the report relies on `.notice` and above.
    nonisolated static func readEntries() throws -> [DiagnosticEntry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
        return try store.getEntries(matching: predicate).compactMap { entry -> DiagnosticEntry? in
            guard let log = entry as? OSLogEntryLog else { return nil }
            return DiagnosticEntry(date: log.date, level: level(of: log.level), category: log.category,
                                   message: log.composedMessage)
        }
    }

    nonisolated static func level(of level: OSLogEntryLog.Level) -> DiagnosticEntry.Level {
        switch level {
        case .debug: .debug
        case .info: .info
        case .notice: .notice
        case .error: .error
        case .fault: .fault
        case .undefined: .undefined
        @unknown default: .undefined
        }
    }

    /// "Document Archive Diagnostics 2026-10-17" (localized), without the extension: the file
    /// exporter adds ".txt" for the plain-text content type.
    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let stamp = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return String(localized: "Document Archive Diagnostics \(stamp)")
    }
}
