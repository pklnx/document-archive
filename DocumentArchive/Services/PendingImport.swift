import CoreGraphics
import Foundation

/// How imported photos are cleaned up (#20).
/// "Review before saving" (the editor sheet) follows in #20 part 2.
enum CleanupMode: String, CaseIterable, Sendable, Identifiable {
    /// Built exactly as before: the whole photo, no filter.
    case off
    /// Straightened and filtered without asking, with the cautious rules of
    /// `ImageCleanup.unattendedSettings`.
    case automatic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .automatic: String(localized: "Automatic")
        }
    }

    /// `UserDefaults` keys of the per-device settings (Settings → General → Import).
    static let settingKey = "photoCleanupMode"
    static let defaultFilterKey = "photoCleanupFilter"
    static let defaultSetting = CleanupMode.off
    static let defaultFilter = PageFilter.color

    static func setting(in defaults: UserDefaults) -> CleanupMode {
        defaults.string(forKey: settingKey).flatMap(CleanupMode.init(rawValue:)) ?? defaultSetting
    }

    static func defaultFilter(in defaults: UserDefaults) -> PageFilter {
        defaults.string(forKey: defaultFilterKey).flatMap(PageFilter.init(rawValue:)) ?? defaultFilter
    }

    /// Source of the settings; tests replace them (inside `GlobalStateTests`). Tests never read
    /// the real settings: Off and Color unless a test says otherwise.
    nonisolated(unsafe) static var settingProvider: () -> CleanupMode = {
        TestEnvironment.isRunningTests ? defaultSetting : setting(in: .standard)
    }
    nonisolated(unsafe) static var defaultFilterProvider: () -> PageFilter = {
        TestEnvironment.isRunningTests ? defaultFilter : defaultFilter(in: .standard)
    }

    /// The mode for an import from `origin` with the user's `setting`. Interactive imports use
    /// the setting; unattended ones (#12's watch folder and share queue) never wait for the user,
    /// so they clean up automatically unless the setting is Off.
    static func mode(for origin: ImportOrigin, setting: CleanupMode) -> CleanupMode {
        switch origin {
        case .interactive: setting
        case .unattended: setting == .off ? .off : .automatic
        }
    }
}

/// Where an import comes from; decides the cleanup mode when the caller does not pass one.
enum ImportOrigin: Sendable {
    /// File dialog, drag and drop, Photos, "Open with" / "Open in…": the user is there.
    case interactive
    /// Watch folder and share-extension queue (#12 parts 2 and 3): nobody looks at the import.
    case unattended
}

/// Photos waiting to become one document. Holds only what is needed: the original bytes (for
/// the hash and to decode the pages again at full resolution), previews of at most
/// `ImageCoding.previewPixelSize` and the detected settings, so many pending photos fit in
/// memory. Full-size pages are decoded one at a time in `DocumentImporter.makeDocumentData`.
///
/// #20 part 2 shows these in the review sheet; #22's vault import builds on `makeDocumentData`.
struct PendingImport: @unchecked Sendable {
    /// One entry per page.
    var originalData: [Data]
    var preview: [CGImage]
    var settings: [CleanupSettings]
    /// The hash of the original bytes (all pages together), stored as the document's `contentHash`.
    var hash: String
    var title: String
    var originalFileName: String
    var source: DocumentSource

    /// Decodes a preview of every page and detects the page in it. The detected settings use
    /// `filter`; a page where nothing was found keeps the whole image.
    /// - Returns: `nil` when a photo cannot be decoded.
    static func make(originalData: [Data], title: String, originalFileName: String = "",
                     source: DocumentSource = .image, filter: PageFilter) async -> PendingImport? {
        guard !originalData.isEmpty else { return nil }
        var previews: [CGImage] = []
        var settings: [CleanupSettings] = []
        for data in originalData {
            guard let preview = ImageCoding.orientedImage(from: data, maxPixelSize: ImageCoding.previewPixelSize) else {
                return nil
            }
            var detected = CleanupSettings(filter: filter)
            if let page = await ImageCleanup.detectPage(in: preview) {
                detected.quad = page.quad
                detected.confidence = page.confidence
            }
            previews.append(preview)
            settings.append(detected)
        }
        return PendingImport(originalData: originalData, preview: previews, settings: settings,
                             hash: DocumentImporter.sha256(originalData.reduce(Data(), +)),
                             title: title, originalFileName: originalFileName, source: source)
    }

    /// The settings used when nobody reviewed the pages (Automatic mode; "Save all" in part 2).
    var unattended: PendingImport {
        var copy = self
        copy.settings = settings.map(ImageCleanup.unattendedSettings(for:))
        return copy
    }
}
