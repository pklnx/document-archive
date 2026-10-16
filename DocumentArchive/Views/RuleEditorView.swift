import SwiftData
import SwiftUI

/// Creating and editing tags, correspondents and document types, including their matching rule.
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
    /// Tags only: the parent tag's id, `nil` for the top level.
    @State private var parentID: UUID?
    /// Tags only: the chosen parent cannot be used any more; saving waits for a new choice.
    @State private var parentProblem: TagHierarchy.ParentProblem?

    @Query(sort: \Tag.name) private var allTags: [Tag]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }

                if isTag {
                    Section {
                        Picker("Parent tag", selection: $parentID) {
                            Text("None (top level)").tag(UUID?.none)
                            ForEach(parentChoices, id: \.tag.id) { entry in
                                Text(verbatim: String(repeating: "\u{2003}", count: entry.depth) + entry.tag.name)
                                    .accessibilityLabel(Text(verbatim: TagHierarchy.displayPath(of: entry.tag)))
                                    .tag(Optional(entry.tag.id))
                            }
                        }
                    } footer: {
                        Text("Documents with a nested tag also appear under its parent tag.")
                    }

                    tagSymbolSection

                    Section("Color") {
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
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityAddTraits(hex == colorHex ? [.isButton, .isSelected] : .isButton)
                                    .accessibilityLabel(Tag.colorName(for: hex))
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
                                    .accessibilityAddTraits(choice == symbol ? [.isButton, .isSelected] : .isButton)
                                    .accessibilityLabel(DocumentType.symbolName(for: choice))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Picker("Assignment", selection: $matchMode) {
                        ForEach(MatchMode.allCases) { Text($0.label).tag($0) }
                    }
                    if matchMode != .none {
                        TextField(matchPlaceholder, text: $matchText, axis: .vertical)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Automatic assignment")
                } footer: {
                    Text("New documents whose text matches this rule are assigned automatically. Case does not matter.")
                }

                if matchMode != .none {
                    Section {
                        Toggle("Also apply to existing documents", isOn: $applyToExisting)
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
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.ruleEditorCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert(parentProblem.map(Self.title(for:)) ?? "", isPresented: Binding(presenting: $parentProblem),
                   presenting: parentProblem) { _ in
                Button("OK") {}
            } message: { problem in
                Text(Self.message(for: problem))
            }
            .onAppear(perform: load)
            .onChange(of: name) { oldValue, newValue in
                // For correspondents, suggest the name as the match phrase
                if isCorrespondent, matchText.isEmpty || matchText == SenderDetector.coreName(oldValue) {
                    matchText = SenderDetector.coreName(newValue)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 440)
        #endif
    }

    private var tagSymbolSection: some View {
        Section("Symbol") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(Tag.symbolChoices, id: \.self) { choice in
                    Image(systemName: choice)
                        .font(.title3)
                        .foregroundStyle(Color(hex: colorHex))
                        .frame(width: 36, height: 36)
                        .background(choice == symbol ? Color.accentColor.opacity(0.2) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            // Not by color alone: the chosen symbol also gets a border.
                            if choice == symbol {
                                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { symbol = choice }
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(choice == symbol ? [.isButton, .isSelected] : .isButton)
                        .accessibilityLabel(Tag.symbolName(for: choice))
                        .accessibilityAction { symbol = choice }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// The edited tag, `nil` for a new one.
    private var editedTag: Tag? {
        if case .tag(let tag) = target { tag } else { nil }
    }

    /// Every tag the edited tag may be nested in: not itself and none of its descendants.
    private var parentChoices: [(tag: Tag, depth: Int)] {
        let edited = editedTag
        return TagHierarchy.flattened(allTags).filter { entry in
            guard let edited else { return true }
            return TagHierarchy.canMove(edited, under: entry.tag)
        }
    }

    static func title(for problem: TagHierarchy.ParentProblem) -> String {
        switch problem {
        case .parentDeleted: String(localized: "Parent tag no longer exists")
        case .wouldCreateCycle: String(localized: "Tag cannot be nested there")
        }
    }

    static func message(for problem: TagHierarchy.ParentProblem) -> String {
        switch problem {
        case .parentDeleted:
            String(localized: "The chosen parent tag was deleted in the meantime. Choose another parent tag and save again.")
        case .wouldCreateCycle:
            String(localized: "The chosen parent tag is now nested in this tag, so this tag cannot be moved into it. Choose another parent tag and save again.")
        }
    }

    private var isTag: Bool {
        switch target {
        case .newTag, .newSubtag, .tag: true
        default: false
        }
    }

    private var isCorrespondent: Bool {
        if case .newCorrespondent = target { return true }
        if case .correspondent = target { return true }
        return false
    }

    private var isDocumentType: Bool { !isTag && !isCorrespondent }

    private var title: String {
        switch target {
        case .newTag, .newSubtag: String(localized: "New Tag")
        case .newCorrespondent: String(localized: "New Correspondent")
        case .newDocumentType: String(localized: "New Document Type")
        case .tag: String(localized: "Edit Tag")
        case .correspondent: String(localized: "Edit Correspondent")
        case .documentType: String(localized: "Edit Document Type")
        }
    }

    private var matchPlaceholder: String {
        switch matchMode {
        case .regex: String(localized: "e.g. Kundennr\\.?\\s*12345")
        case .exact: String(localized: "e.g. Stadtwerke München")
        default: String(localized: "Search words, separated by spaces")
        }
    }

    private func load() {
        switch target {
        case .tag(let tag):
            name = tag.name; colorHex = tag.colorHex; matchMode = tag.matchMode; matchText = tag.matchText
            symbol = tag.symbol
            parentID = tag.parent?.id
        case .correspondent(let correspondent):
            name = correspondent.name; matchMode = correspondent.matchMode; matchText = correspondent.matchText
        case .documentType(let type):
            name = type.name; symbol = type.symbol; matchMode = type.matchMode; matchText = type.matchText
        case .newTag:
            colorHex = Tag.palette.randomElement()!
            symbol = Tag.symbolChoices[0]
        case .newSubtag(let parent):
            // Nested tags start with the parent's look, like a subfolder.
            colorHex = parent.colorHex
            symbol = parent.symbol
            parentID = parent.id
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
        case .newTag, .newSubtag, .tag:
            // Checked before anything changes: a parent deleted or moved meanwhile is reported,
            // never silently replaced by another one.
            let parent: Tag?
            switch TagHierarchy.parent(withID: parentID, for: editedTag, among: allTags) {
            case .success(let chosen): parent = chosen
            case .failure(let problem):
                if problem == .parentDeleted { parentID = editedTag?.parent.flatMap { TagHierarchy.isAlive($0) ? $0.id : nil } }
                parentProblem = problem
                return
            }
            let tag: Tag
            if let existing = editedTag { tag = existing } else { tag = Tag(name: name); context.insert(tag) }
            tag.name = name; tag.colorHex = colorHex; tag.symbol = symbol
            tag.matchMode = matchMode; tag.matchText = matchText
            TagHierarchy.move(tag, under: parent)
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
