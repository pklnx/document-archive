import SwiftUI

/// "Share as…" (#19): the file name before sharing or exporting, pre-filled with the export
/// name. The one-tap Share button in the toolbar keeps the default name.
struct ShareOptionsSheet: View {
    let document: Document
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var showExporter = false

    init(document: Document) {
        self.document = document
        _name = State(initialValue: (document.exportFileName as NSString).deletingPathExtension)
    }

    /// The name the receiver gets, with ".pdf" and the file name rules applied.
    private var fileName: String { FileNaming.sanitized(name) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("File name", text: $name)
                        .accessibilityIdentifier(AccessibilityID.shareOptionsName)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } footer: {
                    Text("The file will be named “\(fileName)”.")
                        .accessibilityIdentifier(AccessibilityID.shareOptionsFileName)
                }
                Section {
                    ShareLink(item: document.transfer(named: fileName), preview: SharePreview(fileName)) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier(AccessibilityID.shareOptionsShare)
                    Button("Export…", systemImage: "arrow.down.doc") { showExporter = true }
                        .accessibilityIdentifier(AccessibilityID.shareOptionsExport)
                }
                .disabled(document.pdfData == nil)
            }
            .formStyle(.grouped)
            .navigationTitle("Share as")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.shareOptionsDone)
                }
            }
            .fileExporter(isPresented: $showExporter, document: document.pdfData.map(PDFFile.init(data:)),
                          contentType: .pdf, defaultFilename: fileName) { _ in }
        }
        .accessibilityIdentifier(AccessibilityID.shareOptions)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 240)
        #endif
    }
}
