import SwiftUI
import UniformTypeIdentifiers

/// Settings → General → Diagnostics: "Export Diagnostics…" writes `DiagnosticsReport` into a
/// plain-text file wherever the user saves it (save panel on the Mac, Files on iPhone and iPad).
/// Nothing is sent anywhere.
struct DiagnosticsSettingsSection: View {
    @State private var file: DiagnosticsFile?
    @State private var isExporting = false
    @State private var isPreparing = false
    @State private var fileName = ""
    @State private var message: String?

    var body: some View {
        Section {
            HStack {
                Button("Export Diagnostics…", systemImage: "doc.text.magnifyingglass") {
                    Task { await prepare() }
                }
                .disabled(isPreparing)
                .accessibilityIdentifier(AccessibilityID.diagnosticsExport)
                if isPreparing { ProgressView().controlSize(.small) }
            }
            // On the row: a presentation modifier on a Section is not reliably presented.
            .fileExporter(isPresented: $isExporting, document: file, contentType: .plainText,
                          defaultFilename: fileName) { result in
                switch result {
                case .success: message = String(localized: "Diagnostics saved.")
                case .failure(let error as CocoaError) where error.code == .userCancelled: break
                case .failure(let error): message = error.localizedDescription
                }
                file = nil
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Creates a text file with the app version, the system, the device model, the storage settings and what the app logged since it started: imports, text recognition, Mistral requests, the folder copy and sync, with counts, durations and error codes. Document titles, file names and text are left out. Nothing is sent anywhere; you choose where the file is saved.")
        }
    }

    private func prepare() async {
        isPreparing = true
        defer { isPreparing = false }
        message = nil
        let report = await Diagnostics.makeReport()
        fileName = Diagnostics.fileName(for: report.created)
        file = DiagnosticsFile(text: report.text())
        isExporting = true
    }
}

/// The report as a plain-text document for `fileExporter`.
struct DiagnosticsFile: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
