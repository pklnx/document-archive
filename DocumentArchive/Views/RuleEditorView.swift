import SwiftData
import SwiftUI

/// Anlegen und Bearbeiten von Tags, Korrespondenten und Dokumenttypen inkl. Zuordnungsregel.
struct RuleEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let target: RuleEditorTarget

    @State private var name = ""
    @State private var colorHex = Tag.palette[5]
    @State private var symbol = "doc.text"
    @State private var matchMode = MatchMode.any
    @State private var matchText = ""
    @State private var applyToExisting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }

                if isTag {
                    Section("Farbe") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                            ForEach(Tag.palette, id: \.self) { hex in
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if hex == colorHex {
                                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                        }
                                    }
                                    .onTapGesture { colorHex = hex }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityLabel("Farbe \(hex)")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if isDocumentType {
                    Section("Symbol") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                            ForEach(DocumentType.symbolChoices, id: \.self) { choice in
                                Image(systemName: choice)
                                    .font(.title3)
                                    .frame(width: 36, height: 36)
                                    .background(choice == symbol ? Color.accentColor.opacity(0.2) : .clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .onTapGesture { symbol = choice }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityLabel(choice)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Picker("Zuordnung", selection: $matchMode) {
                        ForEach(MatchMode.allCases) { Text($0.label).tag($0) }
                    }
                    if matchMode != .none {
                        TextField(matchPlaceholder, text: $matchText, axis: .vertical)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Automatische Zuordnung")
                } footer: {
                    Text("Neue Dokumente, deren Text zu dieser Regel passt, werden automatisch zugeordnet. Groß-/Kleinschreibung spielt keine Rolle.")
                }

                if matchMode != .none {
                    Section {
                        Toggle("Auch auf vorhandene Dokumente anwenden", isOn: $applyToExisting)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
            .onChange(of: name) { oldValue, newValue in
                // Bei Korrespondenten den Namen als Suchbegriff vorschlagen
                if isCorrespondent, matchText.isEmpty || matchText == SenderDetector.coreName(oldValue) {
                    matchText = SenderDetector.coreName(newValue)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 440)
        #endif
    }

    private var isTag: Bool {
        if case .newTag = target { return true }
        if case .tag = target { return true }
        return false
    }

    private var isCorrespondent: Bool {
        if case .newCorrespondent = target { return true }
        if case .correspondent = target { return true }
        return false
    }

    private var isDocumentType: Bool { !isTag && !isCorrespondent }

    private var title: String {
        switch target {
        case .newTag: "Neuer Tag"
        case .newCorrespondent: "Neuer Korrespondent"
        case .newDocumentType: "Neuer Dokumenttyp"
        case .tag: "Tag bearbeiten"
        case .correspondent: "Korrespondent bearbeiten"
        case .documentType: "Dokumenttyp bearbeiten"
        }
    }

    private var matchPlaceholder: String {
        switch matchMode {
        case .regex: "z. B. Kundennr\\.?\\s*12345"
        case .exact: "z. B. Stadtwerke München"
        default: "Suchbegriffe, durch Leerzeichen getrennt"
        }
    }

    private func load() {
        switch target {
        case .tag(let tag):
            name = tag.name; colorHex = tag.colorHex; matchMode = tag.matchMode; matchText = tag.matchText
        case .correspondent(let correspondent):
            name = correspondent.name; matchMode = correspondent.matchMode; matchText = correspondent.matchText
        case .documentType(let type):
            name = type.name; symbol = type.symbol; matchMode = type.matchMode; matchText = type.matchText
        case .newTag:
            colorHex = Tag.palette.randomElement()!
        case .newCorrespondent:
            matchMode = .exact
        case .newDocumentType:
            break
        }
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule: any MatchingRule
        switch target {
        case .newTag, .tag:
            let tag: Tag
            if case .tag(let existing) = target { tag = existing } else { tag = Tag(name: name); context.insert(tag) }
            tag.name = name; tag.colorHex = colorHex; tag.matchMode = matchMode; tag.matchText = matchText
            rule = tag
        case .newCorrespondent, .correspondent:
            let correspondent: Correspondent
            if case .correspondent(let existing) = target { correspondent = existing } else {
                correspondent = Correspondent(name: name); context.insert(correspondent)
            }
            correspondent.name = name; correspondent.matchMode = matchMode; correspondent.matchText = matchText
            rule = correspondent
        case .newDocumentType, .documentType:
            let type: DocumentType
            if case .documentType(let existing) = target { type = existing } else {
                type = DocumentType(name: name); context.insert(type)
            }
            type.name = name; type.symbol = symbol; type.matchMode = matchMode; type.matchText = matchText
            rule = type
        }

        if applyToExisting, let documents = try? context.fetch(FetchDescriptor<Document>()) {
            for document in documents where rule.matches(text: document.title + "\n" + document.extractedText) {
                switch rule {
                case let tag as Tag where !document.hasTag(tag): document.toggleTag(tag)
                case let correspondent as Correspondent where document.correspondent == nil:
                    document.correspondent = correspondent
                case let type as DocumentType where document.documentType == nil:
                    document.documentType = type
                default: break
                }
            }
        }
        try? context.save()
        dismiss()
    }
}
