import Foundation
import Testing
@testable import DocumentArchive

/// Version and export compliance in the generated Info.plist. The version comes from
/// Config/Project.xcconfig, which every target inherits (see docs/development/process.md → Releases).
@Suite struct AppInfoTests {
    private final class TestBundleToken {}

    private var appInfo: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    @Test func versionIsSemantic() throws {
        let version = try #require(appInfo["CFBundleShortVersionString"] as? String)
        #expect(version.wholeMatch(of: #/\d+\.\d+\.\d+/#) != nil, "\(version) is not major.minor.patch")
    }

    @Test func buildNumberIsAPositiveInteger() throws {
        let build = try #require(appInfo["CFBundleVersion"] as? String)
        let number = try #require(Int(build), "\(build) is not an integer")
        #expect(number > 0)
    }

    /// HTTPS and CryptoKit hashing only: exempt from export documentation.
    @Test func usesNoNonExemptEncryption() {
        #expect(appInfo["ITSAppUsesNonExemptEncryption"] as? Bool == false)
    }

    /// The test targets inherit the version too, so their bundles are never without one.
    @Test func testBundleHasAVersion() {
        let info = Bundle(for: TestBundleToken.self).infoDictionary ?? [:]
        #expect(Bundle(for: TestBundleToken.self) != Bundle.main)
        #expect((info["CFBundleShortVersionString"] as? String)?.isEmpty == false)
        #expect((info["CFBundleVersion"] as? String)?.isEmpty == false)
    }

    /// The folder copy writes this into archive.json.
    @Test func folderCopyNamesTheVersion() throws {
        let version = try #require(appInfo["CFBundleShortVersionString"] as? String)
        let build = try #require(appInfo["CFBundleVersion"] as? String)
        #expect(ArchiveMirror.appVersion == "Document Archive \(version) (\(build))")
    }
}
