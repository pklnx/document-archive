import SwiftData
import SwiftUI

struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        TabView {
            Form { GeneralSettingsSections() }
                .formStyle(.grouped)
                .tabItem { Label("General", systemImage: "gearshape") }
            Form { MistralSettingsSection() }
                .formStyle(.grouped)
                .tabItem { Label("AI (Mistral)", systemImage: "sparkles") }
            Form { SyncSettingsSections() }
                .formStyle(.grouped)
                .tabItem { Label("iCloud", systemImage: "icloud") }
            Form { StorageSettingsSection() }
                .formStyle(.grouped)
                .tabItem { Label("Storage", systemImage: "folder") }
        }
        #else
        Form {
            MistralSettingsSection()
            GeneralSettingsSections()
            StorageSettingsSection()
            SyncSettingsSections()
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #endif
    }
}

// MARK: - Mistral

struct MistralSettingsSection: View {
    @AppStorage(MistralConfig.useOCRKey) private var useOCR = true
    @AppStorage(MistralConfig.useLLMKey) private var useLLM = true
    @AppStorage(MistralConfig.ocrModelKey) private var ocrModel = MistralConfig.defaultOCRModel
    @AppStorage(MistralConfig.chatModelKey) private var chatModel = MistralConfig.defaultChatModel

    @State private var apiKey = ""
    @State private var hasStoredKey = false
    @State private var keyFingerprint = ""
    @State private var testResult: (success: Bool, message: String)?
    @State private var isTesting = false

    var body: some View {
        Section {
            if hasStoredKey {
                LabeledContent("API key") {
                    HStack {
                        Label("Saved", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Text(keyFingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) {
                            KeychainStore.delete(MistralConfig.apiKeyAccount)
                            loadKeyState()
                            testResult = nil
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } else {
                SecureField("API key", text: $apiKey, prompt: Text("Paste the Mistral API key"))
                    .autocorrectionDisabled()
                Button("Save Key") {
                    KeychainStore.save(MistralConfig.sanitize(apiKey), for: MistralConfig.apiKeyAccount)
                    apiKey = ""
                    loadKeyState()
                    if hasStoredKey { Task { await test() } }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                Link("Create an API key at Mistral", destination: URL(string: "https://console.mistral.ai/api-keys")!)
                    .font(.caption)
            }

            Toggle("Mistral OCR for text recognition", isOn: $useOCR)
            Toggle("Mistral model for titles and assignment", isOn: $useLLM)
        } header: {
            Text("Mistral AI")
        } footer: {
            Text("With a key, new documents are sent to the Mistral API for text recognition and assignment. Without a key, or on errors, the app keeps working with Apple's local text recognition and your rules. The key is stored in the Keychain.")
        }

        Section("Models") {
            TextField("OCR model", text: $ocrModel, prompt: Text(MistralConfig.defaultOCRModel))
                .autocorrectionDisabled()
            TextField("Assignment model", text: $chatModel, prompt: Text(MistralConfig.defaultChatModel))
                .autocorrectionDisabled()
            HStack {
                Button("Test Connection") { Task { await test() } }
                    .disabled(!hasStoredKey || isTesting)
                if isTesting { ProgressView().controlSize(.small) }
                if let testResult {
                    Label(testResult.message, systemImage: testResult.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(testResult.success ? .green : .red)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .onAppear(perform: loadKeyState)
    }

    private func loadKeyState() {
        let key = KeychainStore.read(MistralConfig.apiKeyAccount).map(MistralConfig.sanitize) ?? ""
        hasStoredKey = !key.isEmpty
        keyFingerprint = MistralConfig.fingerprint(key)
    }

    private func test() async {
        let environment = ProcessingEnvironment.current
        guard let config = environment.mistralConfig() else { return }
        isTesting = true
        defer { isTesting = false }
        do {
            let result = try await MistralClient(config: config, environment: environment).testConnection()
            testResult = (result.isComplete, result.message)
        } catch {
            testResult = (false, error.localizedDescription)
        }
    }
}

// MARK: - General

struct GeneralSettingsSections: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Document> { _ in true }) private var queriedDocuments: [Document]
    private var documents: [Document] { queriedDocuments.filter(\.isAlive) }
    @Query private var documentTypes: [DocumentType]
    @Query private var tags: [Tag]
    @Query private var correspondents: [Correspondent]
    @AppStorage(AutoClassifier.autoCreateCorrespondentsKey) private var autoCreateCorrespondents = true
    @AppStorage(TextLayer.enabledKey) private var addTextLayer = true
    @AppStorage(CleanupMode.settingKey) private var photoCleanup = CleanupMode.defaultSetting
    @AppStorage(CleanupMode.defaultFilterKey) private var photoFilter = CleanupMode.defaultFilter

    @State private var reclassifyProgress: (done: Int, total: Int)?
    @State private var mergeMessage: String?

    var body: some View {
        Section {
            Toggle("Add a text layer to scans", isOn: $addTextLayer)
        } header: {
            Text("Text recognition")
        } footer: {
            Text("Writes the recognized text invisibly into scanned PDFs, so the text can be selected, copied and found in other apps. Applies to documents processed on this device. Documents processed on your other devices may still get a text layer there.")
        }

        Section {
            Picker("Clean up photos", selection: $photoCleanup) {
                ForEach(CleanupMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Default filter", selection: $photoFilter) {
                ForEach(PageFilter.allCases) { Text($0.label).tag($0) }
            }
            .disabled(photoCleanup == .off)
        } header: {
            Text("Import")
        } footer: {
            Text("“Automatic” straightens photographed pages and applies the filter when they are imported; the page is only cropped when it was detected reliably. PDFs and camera scans are not changed. Everything runs on this device.")
        }

        Section {
            Toggle("Create new senders as correspondents automatically", isOn: $autoCreateCorrespondents)
        } header: {
            Text("Automatic assignment")
        } footer: {
            Text("Detects the sender with AI, or from company names (GmbH, AG, Inc., …) or the e-mail address, when no matching correspondent exists yet.")
        }

        Section("Library") {
            LabeledContent("Documents", value: "\(documents.count)")
            LabeledContent("Pages", value: "\(documents.reduce(0) { $0 + $1.pageCount })")
            LabeledContent("Storage used", value: documents.reduce(0) { $0 + $1.fileSize }.formatted(.byteCount(style: .file)))
            LabeledContent("Correspondents", value: "\(correspondents.count)")
            LabeledContent("Document Types", value: "\(documentTypes.count)")
            LabeledContent("Tags", value: "\(tags.count)")
        }

        Section {
            Button("Create default document types", systemImage: "square.stack.3d.up") {
                addDefaultTypes()
            }
            HStack {
                Button("Merge duplicate entries", systemImage: "arrow.triangle.merge") {
                    let removed = MetadataMaintenance.mergeDuplicates(in: context)
                    mergeMessage = removed == 0 ? String(localized: "No duplicates found.")
                                                : String(localized: "\(removed) duplicate(s) merged.")
                }
                if let mergeMessage {
                    Text(mergeMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Reassign all documents", systemImage: "wand.and.stars") {
                    Task { await reclassifyAll() }
                }
                .disabled(reclassifyProgress != nil)
                if let reclassifyProgress {
                    ProgressView(value: Double(reclassifyProgress.done), total: Double(max(reclassifyProgress.total, 1)))
                        .frame(maxWidth: 120)
                    Text("\(reclassifyProgress.done)/\(reclassifyProgress.total)").font(.caption.monospacedDigit())
                }
            }
        } header: {
            Text("Tools")
        } footer: {
            Text("“Reassign” adds missing correspondents, document types and tags. Existing assignments are kept.")
        }

        DiagnosticsSettingsSection()
    }

    private func reclassifyAll() async {
        let all = documents
        reclassifyProgress = (0, all.count)
        for (index, document) in all.enumerated() {
            await AutoClassifier.classify(document, context: context)
            reclassifyProgress = (index + 1, all.count)
        }
        try? context.save()
        reclassifyProgress = nil
    }

    /// Only creates types that do not exist yet, so there are no duplicates,
    /// even when the button is pressed on several devices.
    private func addDefaultTypes() {
        let existing = Set(documentTypes.map { $0.name.lowercased() })
        for (name, symbol, match) in DocumentType.defaults where !existing.contains(name.lowercased()) {
            context.insert(DocumentType(name: name, symbol: symbol, matchText: match))
        }
        try? context.save()
        DocumentType.upgradeDefaults(in: context)
    }
}

// MARK: - iCloud

struct SyncSettingsSections: View {
    private var monitor = SyncMonitor.shared

    var body: some View {
        Section {
            LabeledContent("Sync") {
                if monitor.isCloudKitEnabled {
                    Label("Active", systemImage: "checkmark.icloud").foregroundStyle(.green)
                } else {
                    Label("Inactive – local only", systemImage: "externaldrive").foregroundStyle(.orange)
                }
            }
            if !monitor.isCloudKitEnabled {
                Text("This version of the app is not signed with the iCloud entitlement. Your documents are only on this device. To sync with iPhone and iPad, sign the app in Xcode with your Apple Developer team (target “DocumentArchive” → Signing & Capabilities → Team). Your existing documents are uploaded automatically afterwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("iCloud account") {
                if monitor.isICloudSignedIn {
                    Label("Signed in", systemImage: "checkmark.icloud").foregroundStyle(.green)
                } else {
                    Label("Not signed in", systemImage: "icloud.slash").foregroundStyle(.orange)
                }
            }
            LabeledContent("Last sync") {
                Text(monitor.lastSuccess?.formatted(date: .abbreviated, time: .shortened)
                     ?? (monitor.isCloudKitEnabled ? String(localized: "None since the app started") : "–"))
            }
            if case .failed(let message) = monitor.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("iCloud Sync")
        } footer: {
            Text("All documents are stored in your private iCloud and synced automatically between Mac, iPhone and iPad. There is no server and no account besides your Apple ID.")
        }
    }
}
