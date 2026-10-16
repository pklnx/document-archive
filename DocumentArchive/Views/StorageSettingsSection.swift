import SwiftUI
import UniformTypeIdentifiers

/// Settings → "Storage Location": a copy of the archive in a folder the user chose (#8). The live
/// database stays on this device; the folder gets one PDF and one JSON file per document.
struct StorageSettingsSection: View {
    @Bindable private var mirror = ArchiveMirrorController.shared
    @State private var showFolderPicker = false
    @State private var confirmDefault = false

    var body: some View {
        Section {
            LabeledContent("Location") {
                Text(locationText)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier(AccessibilityID.storageLocation)
            .alert(mirror.notice ?? "", isPresented: Binding(presenting: $mirror.notice)) {
                Button("OK") {}
            }

            if mirror.isAvailable {
                Button(mirror.isEnabled ? "Choose Another Folder…" : "Choose Folder…", systemImage: "folder.badge.plus") {
                    showFolderPicker = true
                }
                .accessibilityIdentifier(AccessibilityID.storageChooseFolder)
                .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                    switch result {
                    case .success(let url): Task { await mirror.choose(url) }
                    case .failure(let error): mirror.notice = error.localizedDescription
                    }
                }
                if mirror.isEnabled {
                    enabledRows
                }
            } else {
                Text("The folder copy is off while the app runs with sample data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Storage Location")
        } footer: {
            Text("The archive itself always stays on this device. With a folder, the app also keeps a copy there: a PDF and a file with the details for every document. If the folder is in iCloud Drive, Dropbox, OneDrive or a similar service, that provider receives the PDFs, the recognized text and all details in readable form; they are not encrypted.")
        }
    }

    private var locationText: String {
        guard mirror.isEnabled else { return String(localized: "Only on this device") }
        return mirror.folderURL?.path(percentEncoded: false) ?? String(localized: "Folder not available")
    }

    @ViewBuilder
    private var enabledRows: some View {
        if let url = mirror.folderURL {
            RevealFolderButton(url: url)
        }
        HStack {
            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { mirror.syncNow() }
                .disabled(mirror.isRunning)
                .accessibilityIdentifier(AccessibilityID.storageSyncNow)
            Spacer()
            if mirror.isRunning {
                FolderCopyProgress(progress: mirror.progress)
                Button("Cancel") { mirror.cancel() }
                    .buttonStyle(.borderless)
            }
        }
        LabeledContent("Last copy") {
            Text(mirror.lastRun?.formatted(date: .abbreviated, time: .shortened) ?? "–")
        }
        if let error = mirror.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        if let count = mirror.deletionsAwaitingConfirmation {
            PendingDeletionsView(count: count)
        }
        Button("Back to Default", systemImage: "internaldrive", role: .destructive) { confirmDefault = true }
            .accessibilityIdentifier(AccessibilityID.storageUseDefault)
            .confirmationDialog("Stop using the folder?", isPresented: $confirmDefault, titleVisibility: .visible) {
                Button("Back to Default", role: .destructive) { mirror.useDefaultLocation() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The archive is then stored only on this device. The files in the folder are kept.")
            }
    }
}

/// "Documents done / total" of a running folder-copy pass.
struct FolderCopyProgress: View {
    let progress: (done: Int, total: Int)?

    var body: some View {
        if let progress, progress.total > 0 {
            ProgressView(value: Double(progress.done), total: Double(progress.total))
                .frame(maxWidth: 120)
                .accessibilityLabel("Copying to the folder")
            Text("\(progress.done)/\(progress.total)")
                .font(.caption.monospacedDigit())
                .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Copying to the folder")
        }
    }
}

/// The mass-delete guard stopped: many deletions wait until the user confirms or discards them.
struct PendingDeletionsView: View {
    let count: Int
    private var mirror = ArchiveMirrorController.shared

    init(count: Int) {
        self.count = count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Deletions waiting for confirmation: \(count)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("They are removed from the folder only after you confirm. “Discard” keeps the documents in the folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Confirm") { mirror.confirmDeletions() }
                    .accessibilityIdentifier(AccessibilityID.deletionsConfirm)
                Button("Discard") { mirror.discardDeletions() }
                    .accessibilityIdentifier(AccessibilityID.deletionsDiscard)
            }
            .buttonStyle(.bordered)
        }
    }
}

/// Sidebar footer: the folder copy's state, shown only while a folder is chosen.
struct FolderCopyStatusView: View {
    private var mirror = ArchiveMirrorController.shared

    var body: some View {
        if mirror.isEnabled {
            Group {
                if let count = mirror.deletionsAwaitingConfirmation {
                    PendingDeletionsView(count: count)
                } else if mirror.lastError != nil {
                    Label("Folder copy failed – see Settings", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if mirror.isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Copying to the folder…")
                    }
                } else {
                    Label("Copy in folder is up to date", systemImage: "folder")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.folderCopyStatus)
        }
    }
}
