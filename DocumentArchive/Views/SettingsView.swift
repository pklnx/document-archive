import SwiftData
import SwiftUI

struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        TabView {
            Form { GeneralSettingsSections() }
                .formStyle(.grouped)
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
            Form { MistralSettingsSection() }
                .formStyle(.grouped)
                .tabItem { Label("KI (Mistral)", systemImage: "sparkles") }
            Form { SyncSettingsSections() }
                .formStyle(.grouped)
                .tabItem { Label("iCloud", systemImage: "icloud") }
        }
        #else
        Form {
            MistralSettingsSection()
            GeneralSettingsSections()
            SyncSettingsSections()
        }
        .formStyle(.grouped)
        .navigationTitle("Einstellungen")
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
                LabeledContent("API-Schlüssel") {
                    HStack {
                        Label("Gespeichert", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Text(keyFingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Button("Entfernen", role: .destructive) {
                            KeychainStore.delete(MistralConfig.apiKeyAccount)
                            loadKeyState()
                            testResult = nil
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } else {
                SecureField("API-Schlüssel", text: $apiKey, prompt: Text("Mistral-API-Schlüssel einfügen"))
                    .autocorrectionDisabled()
                Button("Schlüssel speichern") {
                    KeychainStore.save(MistralConfig.sanitize(apiKey), for: MistralConfig.apiKeyAccount)
                    apiKey = ""
                    loadKeyState()
                    if hasStoredKey { Task { await test() } }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                Link("API-Schlüssel bei Mistral erstellen", destination: URL(string: "https://console.mistral.ai/api-keys")!)
                    .font(.caption)
            }

            Toggle("Mistral OCR für die Texterkennung", isOn: $useOCR)
            Toggle("Mistral-Modell für Titel und Zuordnung", isOn: $useLLM)
        } header: {
            Text("Mistral AI")
        } footer: {
            Text("Ist ein Schlüssel hinterlegt, werden neue Dokumente zur Texterkennung und Zuordnung an die Mistral-API übertragen. Ohne Schlüssel oder bei Fehlern arbeitet die App mit der lokalen Apple-Texterkennung und deinen Regeln weiter. Der Schlüssel wird im Schlüsselbund gespeichert.")
        }

        Section("Modelle") {
            TextField("OCR-Modell", text: $ocrModel, prompt: Text(MistralConfig.defaultOCRModel))
                .autocorrectionDisabled()
            TextField("Zuordnungsmodell", text: $chatModel, prompt: Text(MistralConfig.defaultChatModel))
                .autocorrectionDisabled()
            HStack {
                Button("Verbindung testen") { Task { await test() } }
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
        guard let config = MistralConfig.current() else { return }
        isTesting = true
        defer { isTesting = false }
        do {
            let message = try await MistralClient(config: config).testConnection()
            testResult = (!message.contains("nicht gefunden"), message)
        } catch {
            testResult = (false, error.localizedDescription)
        }
    }
}

// MARK: - Allgemein

struct GeneralSettingsSections: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Document> { _ in true }) private var queriedDocuments: [Document]
    private var documents: [Document] { queriedDocuments.filter(\.isAlive) }
    @Query private var documentTypes: [DocumentType]
    @Query private var tags: [Tag]
    @Query private var correspondents: [Correspondent]
    @AppStorage(AutoClassifier.autoCreateCorrespondentsKey) private var autoCreateCorrespondents = true

    @State private var reclassifyProgress: (done: Int, total: Int)?
    @State private var mergeMessage: String?

    var body: some View {
        Section {
            Toggle("Neue Absender automatisch als Korrespondent anlegen", isOn: $autoCreateCorrespondents)
        } header: {
            Text("Automatische Zuordnung")
        } footer: {
            Text("Erkennt den Absender per KI oder über Firmennamen (GmbH, AG, Inc. …) bzw. die E-Mail-Adresse, wenn noch kein passender Korrespondent existiert.")
        }

        Section("Bibliothek") {
            LabeledContent("Dokumente", value: "\(documents.count)")
            LabeledContent("Seiten", value: "\(documents.reduce(0) { $0 + $1.pageCount })")
            LabeledContent("Speicherbedarf", value: documents.reduce(0) { $0 + $1.fileSize }.formatted(.byteCount(style: .file)))
            LabeledContent("Korrespondenten", value: "\(correspondents.count)")
            LabeledContent("Dokumenttypen", value: "\(documentTypes.count)")
            LabeledContent("Tags", value: "\(tags.count)")
        }

        Section {
            Button("Standard-Dokumenttypen anlegen", systemImage: "square.stack.3d.up") {
                addDefaultTypes()
            }
            HStack {
                Button("Doppelte Einträge zusammenführen", systemImage: "arrow.triangle.merge") {
                    let removed = MetadataMaintenance.mergeDuplicates(in: context)
                    mergeMessage = removed == 0 ? "Keine Duplikate gefunden." : "\(removed) Duplikat(e) zusammengeführt."
                }
                if let mergeMessage {
                    Text(mergeMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Alle Dokumente neu zuordnen", systemImage: "wand.and.stars") {
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
            Text("Werkzeuge")
        } footer: {
            Text("„Neu zuordnen“ ergänzt fehlende Korrespondenten, Dokumenttypen und Tags. Vorhandene Zuordnungen bleiben erhalten.")
        }
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

    /// Legt nur Typen an, die es noch nicht gibt – so entstehen keine Duplikate,
    /// auch wenn der Knopf auf mehreren Geräten gedrückt wird.
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
            LabeledContent("Synchronisation") {
                if monitor.isCloudKitEnabled {
                    Label("Aktiv", systemImage: "checkmark.icloud").foregroundStyle(.green)
                } else {
                    Label("Inaktiv – nur lokal", systemImage: "externaldrive").foregroundStyle(.orange)
                }
            }
            if !monitor.isCloudKitEnabled {
                Text("Diese App-Version ist nicht mit iCloud-Berechtigung signiert. Deine Dokumente liegen nur auf diesem Gerät. Für den Abgleich mit iPhone und iPad muss die App in Xcode mit deinem Apple-Developer-Team signiert werden (Target „DocumentArchive“ → Signing & Capabilities → Team). Deine vorhandenen Dokumente werden danach automatisch hochgeladen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("iCloud-Konto") {
                if monitor.isICloudSignedIn {
                    Label("Angemeldet", systemImage: "checkmark.icloud").foregroundStyle(.green)
                } else {
                    Label("Nicht angemeldet", systemImage: "icloud.slash").foregroundStyle(.orange)
                }
            }
            LabeledContent("Letzte Synchronisation") {
                Text(monitor.lastSuccess?.formatted(date: .abbreviated, time: .shortened)
                     ?? (monitor.isCloudKitEnabled ? "Noch keiner seit App-Start" : "–"))
            }
            if case .failed(let message) = monitor.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("iCloud-Synchronisation")
        } footer: {
            Text("Alle Dokumente werden in deiner privaten iCloud gespeichert und automatisch zwischen Mac, iPhone und iPad abgeglichen. Es gibt keinen Server und kein Benutzerkonto außer deiner Apple-ID.")
        }
    }
}
