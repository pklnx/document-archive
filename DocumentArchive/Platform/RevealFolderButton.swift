import SwiftUI
#if os(macOS)
import AppKit
#endif

/// "Show in Finder" (macOS) or "Show in Files" (iOS) for the archive folder copy.
///
/// iOS has no public API for this; the Files app opens `shareddocuments://<path>`. That scheme is
/// not documented, so if it does not open, the path is shown with a share button instead.
struct RevealFolderButton: View {
    /// The folder the user chose; the copy is in its `Document Archive/` subfolder.
    let url: URL

    #if os(iOS)
    @Environment(\.openURL) private var openURL
    @State private var showsPath = false
    #endif

    private var archiveFolder: URL { ArchiveFolderLayout(chosenFolder: url).root }

    var body: some View {
        #if os(macOS)
        Button("Show in Finder", systemImage: "folder") {
            FolderAccess.withAccess(to: url) {
                NSWorkspace.shared.activateFileViewerSelecting([archiveFolder])
            }
        }
        #else
        Button("Show in Files", systemImage: "folder") {
            guard let target = Self.filesAppURL(for: archiveFolder) else {
                showsPath = true
                return
            }
            openURL(target) { accepted in showsPath = !accepted }
        }
        if showsPath {
            HStack {
                Text(archiveFolder.path(percentEncoded: false))
                    .font(.caption)
                    .textSelection(.enabled)
                Spacer()
                ShareLink(item: archiveFolder) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
            }
        }
        #endif
    }

    /// `file:///private/var/…/Document Archive/` → `shareddocuments:///private/var/…/Document%20Archive/`
    static func filesAppURL(for folder: URL) -> URL? {
        URL(string: "shareddocuments://" + folder.path(percentEncoded: true))
    }
}
