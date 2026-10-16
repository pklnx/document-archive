import Foundation
import Testing
@testable import DocumentArchive

/// The privacy manifest ships in the app bundle on every platform and says what the plan (#42)
/// declares. Which required-reason categories the code uses is checked by
/// scripts/check-privacy-manifest.py in CI.
@Suite struct PrivacyManifestTests {
    private func manifest() throws -> [String: Any] {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                               "PrivacyInfo.xcprivacy is missing from the app bundle")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    private func reasons(for category: String, in manifest: [String: Any]) -> [String] {
        let types = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        return types.filter { $0["NSPrivacyAccessedAPIType"] as? String == category }
            .flatMap { $0["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [] }
    }

    @Test func isInTheAppBundleAndParses() throws {
        _ = try manifest()
    }

    @Test func declaresNoTracking() throws {
        let manifest = try manifest()
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
    }

    @Test func declaresTheRequiredReasons() throws {
        let manifest = try manifest()
        #expect(reasons(for: "NSPrivacyAccessedAPICategoryUserDefaults", in: manifest) == ["CA92.1"])
        #expect(reasons(for: "NSPrivacyAccessedAPICategoryFileTimestamp", in: manifest) == ["3B52.1"])
    }

    /// Mistral (opt-in): other user content, linked to the user's own account, no tracking, only for
    /// the app's functionality (maintainer decision on #42).
    @Test func declaresMistralAsOtherUserContent() throws {
        let collected = try #require(try manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        #expect(collected.count == 1)
        let entry = try #require(collected.first)
        #expect(entry["NSPrivacyCollectedDataType"] as? String == "NSPrivacyCollectedDataTypeOtherUserContent")
        #expect(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool == true)
        #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
        #expect(entry["NSPrivacyCollectedDataTypePurposes"] as? [String]
                == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
    }
}
