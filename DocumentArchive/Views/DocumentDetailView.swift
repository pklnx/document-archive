import SwiftData
import SwiftUI

struct DocumentDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var document: Document
    @Binding var editorTarget: RuleEditorTarget?
    var onDelete: () -> Void

    /// Whether the inspector was open, remembered where it is a column (Mac, wide iPad windows).
    @AppStorage("showInspector") private var remembersInspector = true
    /// The one state the inspector and the Info button use. On compact width (iPhone, narrow
    /// iPad windows and columns) it starts closed: the remembered state there left the sheet
    /// hidden but counted as open, so the first tap on Info did nothing.
    @State private var showInspector = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var showExporter = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let data = document.pdfData {
                PDFKitView(data: data, id: document.id)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView("Loading PDF…", systemImage: "icloud.and.arrow.down",
                                       description: Text("The file is being downloaded from iCloud."))
            }
        }
        .navigationTitle(document.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier(AccessibilityID.documentDetail)
        .inspector(isPresented: $showInspector) {
            DocumentInfoForm(document: document, editorTarget: $editorTarget)
                .accessibilityIdentifier(AccessibilityID.inspector)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    document.isInbox.toggle()
                    document.touch()
                } label: {
                    Label(document.isInbox ? "Mark as Done" : "Move to Inbox",
                          systemImage: document.isInbox ? "tray.and.arrow.up" : "tray.and.arrow.down")
                }
                .help(document.isInbox ? "Mark as done (remove from inbox)" : "Back to the inbox")

                Button {
                    document.isFavorite.toggle()
                    document.touch()
                } label: {
                    Label("Favorite", systemImage: document.isFavorite ? "star.fill" : "star")
                }

                if let transfer = document.transfer {
                    ShareLink(item: transfer, preview: SharePreview(document.title)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }

                Menu {
                    Button("Export as PDF…", systemImage: "arrow.down.doc") { showExporter = true }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
                .accessibilityIdentifier(AccessibilityID.inspectorToggle)
            }
        }
        .onAppear { showInspector = inspectorIsColumn && remembersInspector }
        .onChange(of: document.isProcessing) { wasProcessing, isProcessing in
            // The document stays on screen while it is processed; tell VoiceOver when it is ready.
            if wasProcessing, !isProcessing, document.isAlive {
                AccessibilityNotification.Announcement(String(localized: "Text recognition finished")).post()
            }
        }
        .onChange(of: showInspector) { if inspectorIsColumn { remembersInspector = showInspector } }
        .fileExporter(isPresented: $showExporter, document: document.pdfData.map(PDFFile.init(data:)),
                      contentType: .pdf, defaultFilename: document.exportFileName) { _ in }
        .confirmationDialog("Delete document?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                onDelete()
                context.delete(document)
                try? context.save()
            }
        } message: {
            Text("“\(document.title)” will be deleted on all devices.")
        }
    }

    private var inspectorIsColumn: Bool {
        #if os(iOS)
        horizontalSizeClass != .compact
        #else
        true
        #endif
    }
}

/// Edits a document's metadata: title, date, correspondent, type, tags, ASN, notes.
struct DocumentInfoForm: View {
    @Environment(\.modelContext) private var context
    @Bindable var document: Document
    @Binding var editorTarget: RuleEditorTarget?

    @Query(sort: \Correspondent.name) private var correspondents: [Correspondent]
    @Query(sort: \DocumentType.name) private var documentTypes: [DocumentType]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query private var allDocuments: [Document]

    @State private var classificationMessage: String?
    @State private var isClassifying = false

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $document.title, axis: .vertical)
                    .font(.headline)
                DatePicker("Issued", selection: $document.documentDate, displayedComponents: .date)
            }

            Section("Assignment") {
                Picker(selection: $document.correspondent) {
                    Text("None").tag(Correspondent?.none)
                    ForEach(correspondents) { Text($0.name).tag(Optional($0)) }
                } label: {
                    Label("Correspondent", systemImage: "person.crop.circle")
                }
                Picker(selection: $document.documentType) {
                    Text("None").tag(DocumentType?.none)
                    ForEach(documentTypes) { Label($0.name, systemImage: $0.symbol).tag(Optional($0)) }
                } label: {
                    Label("Document type", systemImage: "doc.text")
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Tags", systemImage: "tag")
                        Spacer()
                        Menu {
                            ForEach(tags) { tag in
                                Toggle(tag.name, isOn: Binding(
                                    get: { document.hasTag(tag) },
                                    set: { _ in document.toggleTag(tag) }
                                ))
                            }
                            if !tags.isEmpty { Divider() }
                            Button("New Tag…", systemImage: "plus") { editorTarget = .newTag }
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Edit tags")
                    }
                    if !document.sortedTags.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(document.sortedTags) { tag in
                                Button {
                                    document.toggleTag(tag)
                                } label: {
                                    HStack(spacing: 2) {
                                        TagChip(tag: tag)
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove tag \(tag.name)")
                            }
                        }
                    }
                }
                HStack {
                    Label("ASN", systemImage: "number")
                    Spacer()
                    TextField("–", value: $document.archiveSerialNumber, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .frame(maxWidth: 100)
                    if document.archiveSerialNumber == nil {
                        Button("Next") { document.archiveSerialNumber = nextASN }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Section("Notes") {
                TextField("Notes", text: $document.notes, axis: .vertical)
                    .lineLimit(3...10)
            }

            Section {
                Button {
                    Task {
                        isClassifying = true
                        let outcome = await AutoClassifier.classify(document, context: context)
                        try? context.save()
                        isClassifying = false
                        withAnimation { classificationMessage = outcome.summary }
                    }
                } label: {
                    HStack {
                        Label("Assign automatically", systemImage: "wand.and.stars")
                        if isClassifying {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(document.isProcessing || isClassifying)
                if let classificationMessage {
                    Text(classificationMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Button("Analyze again (text recognition + assignment)", systemImage: "text.viewfinder") {
                    classificationMessage = nil
                    DocumentImporter.process(document, context: context, classify: true)
                }
                .disabled(document.isProcessing || isClassifying)
                if !document.processingNote.isEmpty, !document.isProcessing {
                    // Readable text; the color only marks the icon.
                    Label {
                        Text(document.processingNote).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
            }

            Section("Details") {
                LabeledContent("Added", value: document.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Modified", value: document.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Source") { Label(document.source.label, systemImage: document.source.systemImage) }
                LabeledContent("Pages", value: "\(document.pageCount)")
                LabeledContent("Size", value: document.fileSize.formatted(.byteCount(style: .file)))
                if !document.originalFileName.isEmpty {
                    LabeledContent("Original file", value: document.originalFileName)
                }
                if !document.textSource.isEmpty {
                    LabeledContent("Text recognition", value: document.textSource)
                }
            }

            Section("Recognized Text") {
                if document.isProcessing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(MistralConfig.current()?.useOCR == true ? "Mistral OCR running…" : "Text recognition running…")
                            .foregroundStyle(.secondary)
                    }
                } else if document.extractedText.isEmpty {
                    Text("No text recognized").foregroundStyle(.secondary)
                } else {
                    DisclosureGroup("\(document.extractedText.count) characters") {
                        Text(document.extractedText)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: document.title) { document.touch() }
        .onChange(of: document.notes) { document.touch() }
        .onChange(of: document.documentDate) { document.touch() }
        .onChange(of: document.correspondent) { document.touch() }
        .onChange(of: document.documentType) { document.touch() }
        .onChange(of: document.archiveSerialNumber) { document.touch() }
    }

    private var nextASN: Int {
        (allDocuments.compactMap(\.archiveSerialNumber).max() ?? 0) + 1
    }
}
