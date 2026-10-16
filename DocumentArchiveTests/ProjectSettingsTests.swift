import Foundation
import Testing

/// Build settings that must come from `Config/Project.xcconfig` (and the optional
/// `Config/Local.xcconfig` it includes) instead of the targets. A target-level setting overrides
/// the project's base configuration, so Xcode's signing editor adding `DEVELOPMENT_TEAM = ""` to a
/// target would silently ignore the team in `Local.xcconfig` again (#42). Reads the project file
/// from the source checkout; macOS only, where the tests run on the machine that has it.
@Suite struct ProjectSettingsTests {
    #if os(macOS)
    private static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func read(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appending(path: path), encoding: .utf8)
    }

    @Test func targetsSetNoDevelopmentTeam() throws {
        let project = try read("DocumentArchive.xcodeproj/project.pbxproj")
        #expect(!project.contains("DEVELOPMENT_TEAM"), "set the team in Config/Local.xcconfig, not in a target")
    }

    /// The sandboxed test build's own container depends on the suffix (docs: Sandbox).
    @Test func appBundleIdentifierTakesTheSuffix() throws {
        let project = try read("DocumentArchive.xcodeproj/project.pbxproj")
        let identifiers = project.split(separator: "\n").filter { $0.contains("PRODUCT_BUNDLE_IDENTIFIER = ") }
        let app = identifiers.filter { $0.hasSuffix("PRODUCT_BUNDLE_IDENTIFIER = \"de.patrickklein.DocumentArchive$(DA_BUNDLE_ID_SUFFIX)\";") }
        #expect(app.count == 2, "the app target's Debug and Release configurations")
        #expect(!identifiers.contains { $0.hasSuffix("PRODUCT_BUNDLE_IDENTIFIER = de.patrickklein.DocumentArchive;") })
        let config = try read("Config/Project.xcconfig")
        #expect(config.contains("\nDA_BUNDLE_ID_SUFFIX =\n"), "empty for every real build")
    }

    /// `Local.xcconfig` overrides everything, so its include comes last.
    @Test func localOverridesAreIncludedLast() throws {
        let lines = try read("Config/Project.xcconfig").split(separator: "\n")
            .filter { !$0.hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(lines.last == "#include? \"Local.xcconfig\"")
    }
    #endif
}
