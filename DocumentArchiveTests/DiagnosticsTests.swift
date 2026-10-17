import Foundation
import os
import Testing
@testable import DocumentArchive

/// The diagnostics report (#42): the pure formatter, the header of the running app, and the round
/// trip through unified logging on macOS and the iOS simulator.
@Suite @MainActor struct DiagnosticsTests {
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    private static func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)!
    }

    private static let header = DiagnosticsReport.Header(
        appVersion: "0.1.0", build: "7", system: "macOS", systemVersion: "26.0.1", deviceModel: "Mac15,3",
        sandboxed: true, store: "local", cloudKitAllowed: false, cloudKitActive: false, folderCopy: true)

    // MARK: Formatter

    @Test func formatterWritesTheHeaderFields() {
        let report = DiagnosticsReport(created: Self.date("2026-10-17T10:00:00.000Z"), header: Self.header, entries: [])
        let lines = report.text(timeZone: Self.berlin).components(separatedBy: "\n")

        #expect(lines.first == "Document Archive diagnostics")
        #expect(lines.contains("Created: 2026-10-17 12:00:00 +02:00"))
        #expect(lines.contains("App: 0.1.0 (7)"))
        #expect(lines.contains("System: macOS 26.0.1"))
        #expect(lines.contains("Device: Mac15,3"))
        #expect(lines.contains("Sandboxed: yes"))
        #expect(lines.contains("Store: local"))
        #expect(lines.contains("CloudKit allowed by this build: no"))
        #expect(lines.contains("CloudKit sync active: no"))
        #expect(lines.contains("Folder copy: folder chosen"))
        #expect(lines.contains("Log of this launch (0 entries)"))
    }

    @Test func formatterWritesOneLinePerEntry() {
        let entries = [
            DiagnosticEntry(date: Self.date("2026-10-17T10:00:01.250Z"), level: .notice, category: "store",
                            message: "Store opened: local"),
            DiagnosticEntry(date: Self.date("2026-10-17T10:00:02.000Z"), level: .error, category: "mistral",
                            message: "ocr: status 401, 120 ms"),
            DiagnosticEntry(date: Self.date("2026-10-17T10:00:03.000Z"), level: .fault, category: "store",
                            message: "first line\nsecond line"),
        ]
        let report = DiagnosticsReport(created: Self.date("2026-10-17T10:05:00.000Z"), header: Self.header,
                                       entries: entries)
        let text = report.text(timeZone: Self.berlin)
        let log = text.components(separatedBy: "Log of this launch (3 entries)\n")[1]

        #expect(log == """
            2026-10-17 12:00:01.250 +02:00  notice  store  Store opened: local
            2026-10-17 12:00:02.000 +02:00  error  mistral  ocr: status 401, 120 ms
            2026-10-17 12:00:03.000 +02:00  fault  store  first line
                second line

            """)
    }

    /// #23 adds its sync section through `sections`; it comes after the header, before the log.
    @Test func formatterWritesSectionsBetweenHeaderAndLog() {
        var report = DiagnosticsReport(created: .now, header: Self.header, entries: [])
        report.sections = [DiagnosticsReport.Section(title: "Sync", lines: ["CKErrorDomain 3"])]
        let text = report.text()

        let section = try! #require(text.range(of: "\n\nSync\nCKErrorDomain 3\n"))
        let folderCopy = try! #require(text.range(of: "Folder copy:"))
        let log = try! #require(text.range(of: "Log of this launch"))
        #expect(folderCopy.lowerBound < section.lowerBound && section.upperBound <= log.lowerBound)
    }

    @Test func formatterSaysWhenTheLogCouldNotBeRead() {
        let report = DiagnosticsReport(created: .now, header: Self.header, entries: [], logError: "OSLogErrorDomain 1")
        #expect(report.text().contains("The log could not be read: OSLogErrorDomain 1"))
    }

    @Test func fileNameHasTheDate() {
        let name = Diagnostics.fileName(for: Self.date("2026-10-17T23:30:00.000Z"), timeZone: Self.berlin)
        let day = "2026-10-18"   // the next day in Berlin
        #expect(name == String(localized: "Document Archive Diagnostics \(day)"))
        #expect(name.hasSuffix(" 2026-10-18"))
        #expect(!name.hasSuffix(".txt"))   // the exporter adds it for the plain-text type
    }

    // MARK: Header of the running app

    /// Unit tests run with the in-memory store and never start the folder copy or CloudKit.
    @Test func headerDescribesTheRunningApp() {
        let header = Diagnostics.currentHeader(info: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42"])
        #expect(header.appVersion == "1.2.3")
        #expect(header.build == "42")
        #expect(header.sandboxed == AppSandbox.isActive)
        #expect(header.store == ArchiveStore.OpenedStore.inMemory.rawValue)
        #expect(!header.cloudKitActive)
        #expect(!header.cloudKitAllowed)
        #expect(!header.folderCopy)
        #expect(!header.deviceModel.isEmpty)
        #expect(header.systemVersion.wholeMatch(of: #/\d+\.\d+\.\d+/#) != nil)
        #if os(macOS)
        #expect(header.system == "macOS")
        #else
        #expect(["iOS", "iPadOS"].contains(header.system))
        #endif
    }

    // MARK: Unified logging round trip

    /// Polls the log store until `isComplete` holds for the entries found (unified logging hands
    /// entries over asynchronously).
    private func entries(until isComplete: ([DiagnosticEntry]) -> Bool) async throws -> [DiagnosticEntry] {
        let clock = ContinuousClock()
        let deadline = clock.now + TestSupport.scaled(.seconds(15))
        var entries = try Diagnostics.readEntries()
        while !isComplete(entries), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            entries = try Diagnostics.readEntries()
        }
        return entries
    }

    /// One entry per level the export relies on (`.notice`, `.error`, `.fault`), each with its own
    /// public token: every one must come back from the log store, with its level and category.
    /// A single default-level entry could pass while the other levels were missing.
    @Test func everyLevelTheExportReliesOnIsReadBack() async throws {
        let token = UUID().uuidString
        Log.store.notice("diagnostics test notice \(token, privacy: .public)")
        Log.store.error("diagnostics test error \(token, privacy: .public)")
        Log.store.fault("diagnostics test fault \(token, privacy: .public)")

        let expected: [(DiagnosticEntry.Level, String)] = [
            (.notice, "diagnostics test notice \(token)"),
            (.error, "diagnostics test error \(token)"),
            (.fault, "diagnostics test fault \(token)"),
        ]
        let found = try await entries { entries in
            expected.allSatisfy { level, message in entries.contains { $0.message == message && $0.level == level } }
        }
        for (level, message) in expected {
            let entry = found.first { $0.message == message }
            #expect(entry?.level == level, "\(level) entry not read back")
            #expect(entry?.category == "store")
        }
    }

    /// A Mistral request is logged with its endpoint and status, and the report built afterwards
    /// never contains the API key in `MistralConfig` (the stub's own fake key) or the header.
    @Test func reportNeverContainsTheAPIKey() async throws {
        let stub = MistralStub.install { _, _ in .json(["data": [["id": MistralConfig.defaultOCRModel],
                                                                  ["id": MistralConfig.defaultChatModel]]]) }
        let key = stub.config.apiKey
        _ = try await MistralClient(config: stub.config, environment: stub.environment).testConnection()
        #expect(stub.requests.count == 1)

        let report = try await ProcessingEnvironment.$current.withValue(stub.environment) {
            _ = try await entries { entries in
                entries.contains { $0.category == "mistral" && $0.message.hasPrefix("models: status 200") }
            }
            return await Diagnostics.makeReport()
        }
        let text = report.text()
        #expect(report.logError == nil)
        #expect(text.contains("models: status 200"))
        #expect(!text.contains(key))
        #expect(!text.contains("Bearer"))
        #expect(!text.contains("Authorization"))
    }

    /// Each import outcome is a `.notice` in the `import` category, with the origin and the size.
    /// (Whether `.private` values are redacted cannot be tested here: test runs launched by Xcode
    /// see them; release builds get `<private>`, which the manual Mac check verifies.)
    @Test func importOutcomeIsLogged() async throws {
        let container = try TestSupport.makeContainer()
        let name = "Diagnostics-\(UUID().uuidString).pdf"
        let data = TestSupport.samplePDF(lines: [UUID().uuidString])
        let outcome = try await DocumentImporter.importFile(data: data, name: name, into: container.mainContext)
        guard case .imported(let document) = outcome else {
            Issue.record("not imported")
            return
        }
        let duplicate = try await DocumentImporter.importFile(data: data, name: name, into: container.mainContext)
        guard case .duplicate = duplicate else {
            Issue.record("not a duplicate")
            return
        }
        try await TestSupport.waitUntilProcessed([document])

        let imported = "Imported: file from interactive, \(data.count) bytes"
        let skipped = "Duplicate skipped: from interactive, \(data.count) bytes"
        let found = try await entries { entries in
            entries.contains { $0.message.hasPrefix(imported) } && entries.contains { $0.message.hasPrefix(skipped) }
        }
        for prefix in [imported, skipped] {
            let entry = try #require(found.last { $0.message.hasPrefix(prefix) }, "\(prefix) not logged")
            #expect(entry.level == .notice)
            #expect(entry.category == "import")
        }
        let analyzed = found.contains { $0.category == "ocr" && $0.level == .notice && $0.message.hasPrefix("Analyzed: 1 pages") }
        #expect(analyzed, "no ocr notice for the processed document")
    }
}
