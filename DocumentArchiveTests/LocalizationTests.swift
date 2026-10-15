import Foundation
import Testing
@testable import DocumentArchive

/// The UI is written in English and translated to German through String Catalogs.
/// A missing or broken German translation is a bug, so these tests read the catalogs from the
/// source tree. They are run after the build, so new UI texts must have been added to the catalog.
@Suite struct LocalizationTests {
    static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    struct Entry {
        var key: String
        var state: String?
        var german: String?
    }

    static func entries(of catalog: String) throws -> [Entry] {
        let url = sourceRoot.appending(path: "DocumentArchive/\(catalog)")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["sourceLanguage"] as? String == "en")
        let strings = try #require(json["strings"] as? [String: Any])
        return strings.map { key, value in
            let unit = ((value as? [String: Any])?["localizations"] as? [String: Any])
                .flatMap { $0["de"] as? [String: Any] }
                .flatMap { $0["stringUnit"] as? [String: Any] }
            return Entry(key: key, state: unit?["state"] as? String, german: unit?["value"] as? String)
        }
    }

    @Test(arguments: ["Localizable.xcstrings", "InfoPlist.xcstrings"])
    func everyStringHasAGermanTranslation(catalog: String) throws {
        let entries = try Self.entries(of: catalog)
        #expect(!entries.isEmpty)
        for entry in entries {
            #expect(entry.state == "translated", "\(catalog): “\(entry.key)” has no finished German translation")
            #expect(entry.german?.isEmpty == false, "\(catalog): “\(entry.key)” has an empty German translation")
        }
    }

    /// A translation with other placeholders than its key crashes or shows wrong values at runtime.
    @Test func translationsKeepThePlaceholders() throws {
        let specifier = /%(?:(\d+)\$)?(lld|ld|d|@|lf|f)/
        func kinds(_ string: String) -> [String] {
            var positional: [(Int, String)] = []
            var sequential: [String] = []
            for match in string.matches(of: specifier) {
                if let position = match.1.flatMap({ Int($0) }) {
                    positional.append((position, String(match.2)))
                } else {
                    sequential.append(String(match.2))
                }
            }
            return positional.isEmpty ? sequential : positional.sorted { $0.0 < $1.0 }.map(\.1)
        }
        for entry in try Self.entries(of: "Localizable.xcstrings") {
            guard let german = entry.german else { continue }
            #expect(kinds(german) == kinds(entry.key), "Placeholders differ for “\(entry.key)” → “\(german)”")
        }
    }

    @Test func germanTranslationIsUsedForAKnownKey() throws {
        let german = try #require(Bundle.main.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)))
        #expect(german.localizedString(forKey: "Inbox", value: nil, table: nil) == "Posteingang")
        #expect(german.localizedString(forKey: "Import Documents…", value: nil, table: nil) == "Dokumente importieren …")
    }
}
