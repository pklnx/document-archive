import Foundation

/// Whether a file in the archive folder can be read now. Cloud providers evict files to save
/// space; an evicted file still exists and must never be treated as missing or deleted.
enum UbiquitousFileState: Equatable, Sendable {
    /// Neither the file nor a placeholder exists.
    case missing
    /// The file is there with its content (a local file, or a downloaded cloud file).
    case available
    /// The file exists under its real name without content (macOS 14+ File Provider, "Optimize
    /// Mac Storage"). Reading it blocks until it has downloaded.
    case dataless
    /// Only a `.<name>.icloud` placeholder exists (iOS, older providers).
    case placeholder

    /// `true` unless nothing is there at all.
    var exists: Bool { self != .missing }
    /// The file exists but must be downloaded before it can be read.
    var needsDownload: Bool { self == .dataless || self == .placeholder }
}

/// Seam over `URLResourceValues` (`isUbiquitousItem`, `ubiquitousItemDownloadingStatus`) and the
/// `.icloud` placeholder check, so tests can simulate evicted files.
protocol UbiquityStatusProviding: Sendable {
    func state(of url: URL) -> UbiquitousFileState
    /// Asks the provider to download the file; the caller retries later.
    func startDownloading(_ url: URL)
}

/// The real implementation.
struct UbiquityStatus: UbiquityStatusProviding {
    func state(of url: URL) -> UbiquitousFileState {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus == .notDownloaded {
                return .dataless
            }
            return .available
        }
        return manager.fileExists(atPath: Self.placeholderURL(for: url).path) ? .placeholder : .missing
    }

    func startDownloading(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// `Folder/name.json` → `Folder/.name.json.icloud`
    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
    }
}
