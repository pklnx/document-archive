import SwiftData
import SwiftUI

struct DocumentDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var document: Document
    @Binding var editorTarget: RuleEditorTarget?
    var onDelete: () -> Void

    @AppStorage("showInspector") private var showInspector = true
    @State private var showExporter = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let data = document.pdfData {
                PDFKitView(data: data, id: document.id)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView("PDF wird geladen …", systemImage: "icloud.and.arrow.down",
                                       description: Text("Die Datei wird gerade aus iCloud geladen."))
            }
        }
        .navigationTitle(document.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .inspector(isPresented: $showInspector) {
            DocumentInfoForm(document: document, editorTarget: $editorTarget)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    document.isInbox.toggle()
                    document.touch()
                } label: {
                    Label(document.isInbox ? "Als erledigt markieren" : "In den Posteingang",
                          systemImage: document.isInbox ? "tray.and.arrow.up" : "tray.and.arrow.down")
                }
                .help(document.isInbox ? "Als erledigt markieren (aus dem Posteingang entfernen)" : "Zurück in den Posteingang")

                Button {
                    document.isFavorite.toggle()
                    document.touch()
                } label: {
                    Label("Favorit", systemImage: document.isFavorite ? "star.fill" : "star")
                }

                if let transfer = document.transfer {
                    ShareLink(item: transfer, preview: SharePreview(document.title)) {
                        Label("Teilen", systemImage: "square.and.arrow.up")
                    }
                }

                Menu {
                    Button("Als PDF exportieren …", systemImage: "arrow.down.doc") { showExporter = true }
                    Divider()
                    Button("Löschen", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Label("Mehr", systemImage: "ellipsis.circle")
                }

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Informationen", systemImage: "info.circle")
                }
            }
        }
        .fileExporter(isPresented: $showExporter, document: document.pdfData.map(PDFFile.init(data:)),
                      contentType: .pdf, defaultFilename: document.exportFileName) { _ in }
        .confirmationDialog("Dokument löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                onDelete()
                context.delete(document)
                try? context.save()
            }
        } message: {
            Text("„\(document.title)“ wird auf allen Geräten gelöscht.")
        }
    }
}

/// Metadaten eines Dokuments bearbeiten – Titel, Datum, Korrespondent, Typ, Tags, ASN, Notizen.
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
                TextField("Titel", text: $document.title, axis: .vertical)
                    .font(.headline)
                DatePicker("Ausgestellt", selection: $document.documentDate, displayedComponents: .date)
            }

            Section("Zuordnung") {
                Picker(selection: $document.correspondent) {
                    Text("Keiner").tag(Correspondent?.none)
                    ForEach(correspondents) { Text($0.name).tag(Optional($0)) }
                } label: {
                    Label("Korrespondent", systemImage: "person.crop.circle")
                }
                Picker(selection: $document.documentType) {
                    Text("Keiner").tag(DocumentType?.none)
                    ForEach(documentTypes) { Label($0.name, systemImage: $0.symbol).tag(Optional($0)) }
                } label: {
                    Label("Dokumenttyp", systemImage: "doc.text")
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
                            Button("Neuer Tag …", systemImage: "plus") { editorTarget = .newTag }
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Tags bearbeiten")
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
                                .accessibilityLabel("Tag \(tag.name) entfernen")
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
                        Button("Nächste") { document.archiveSerialNumber = nextASN }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Section("Notizen") {
                TextField("Notizen", text: $document.notes, axis: .vertical)
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
                        Label("Automatisch zuordnen", systemImage: "wand.and.stars")
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
                Button("Erneut analysieren (Texterkennung + Zuordnung)", systemImage: "text.viewfinder") {
                    classificationMessage = nil
                    DocumentImporter.process(document, context: context, classify: true)
                }
                .disabled(document.isProcessing || isClassifying)
                if !document.processingNote.isEmpty, !document.isProcessing {
                    Label(document.processingNote, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Details") {
                LabeledContent("Hinzugefügt", value: document.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Geändert", value: document.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Quelle") { Label(document.source.label, systemImage: document.source.systemImage) }
                LabeledContent("Seiten", value: "\(document.pageCount)")
                LabeledContent("Größe", value: document.fileSize.formatted(.byteCount(style: .file)))
                if !document.originalFileName.isEmpty {
                    LabeledContent("Originaldatei", value: document.originalFileName)
                }
                if !document.textSource.isEmpty {
                    LabeledContent("Texterkennung", value: document.textSource)
                }
            }

            Section("Erkannter Text") {
                if document.isProcessing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(MistralConfig.current()?.useOCR == true ? "Mistral OCR läuft …" : "Texterkennung läuft …")
                            .foregroundStyle(.secondary)
                    }
                } else if document.extractedText.isEmpty {
                    Text("Kein Text erkannt").foregroundStyle(.secondary)
                } else {
                    DisclosureGroup("\(document.extractedText.count) Zeichen") {
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
