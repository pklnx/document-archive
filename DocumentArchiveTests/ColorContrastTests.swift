import Foundation
import Testing
@testable import DocumentArchive

@Suite struct ColorContrastTests {
    typealias RGB = ColorContrast.RGB

    /// The palette plus colors that are hard to read: pure yellow, black, white and a light teal.
    static let colors = ArchiveTag.palette + ["#FFFF00", "#000000", "#FFFFFF", "#7FFFD4"]

    @Test func knownRatios() {
        #expect(abs(ColorContrast.ratio(.black, .white) - 21) < 0.01)
        #expect(abs(ColorContrast.ratio(.white, .white) - 1) < 0.01)
        // #777 on white is the classic "just below AA" grey
        #expect(abs(ColorContrast.ratio(RGB(hex: "#777777"), .white) - 4.48) < 0.01)
        #expect(ColorContrast.ratio(RGB(hex: "#777777"), .white) == ColorContrast.ratio(.white, RGB(hex: "#777777")))
    }

    @Test func hexParsing() {
        #expect(RGB(hex: "#FF0000") == RGB(red: 1, green: 0, blue: 0))
        #expect(RGB(hex: "00FF00") == RGB(red: 0, green: 1, blue: 0))
        #expect(RGB(hex: "nonsense") == RGB(hex: "#3B82F6"), "falls back to the default tag blue, like Color(hex:)")
    }

    static let appearances = [false, true]

    /// Every row a chip can sit on: normal, grey selected (iPhone edit mode, unfocused macOS list)
    /// and accent selected (iPad, focused macOS list).
    @Test func everyRowBackgroundIsCovered() {
        for dark in Self.appearances {
            let rows = ColorContrast.allRowBackgrounds(dark: dark)
            #expect(rows.contains(ColorContrast.selectedRowBackground(dark: dark)))
            #expect(ColorContrast.greySelectedRowBackgrounds(dark: dark).allSatisfy { rows.contains($0) })
            #expect(ColorContrast.rowBackgrounds(dark: dark).allSatisfy { rows.contains($0) })
        }
    }

    @Test(arguments: colors, appearances)
    func chipTextIsReadable(hex: String, dark: Bool) {
        let text = ColorContrast.chipText(tagHex: hex, dark: dark)
        let fill = ColorContrast.chipBackground(tagHex: hex, dark: dark)
        #expect(ColorContrast.ratio(text, fill) >= ColorContrast.minimumTextContrast,
                "\(hex): \(ColorContrast.ratio(text, fill))")
    }

    /// Regression: on iPad, a row that stayed selected while more rows were added kept
    /// `backgroundProminence == .standard` on its accent background, so the chip used the colors
    /// for a white row and its translucent fill took on the accent ("Tax" green on Petrol). The
    /// fill is opaque now: the same color on every row, selected or not.
    @Test(arguments: colors, appearances)
    func chipFillDoesNotDependOnTheRow(hex: String, dark: Bool) {
        let fill = ColorContrast.chipBackground(tagHex: hex, dark: dark)
        let normalRow = ColorContrast.rowBackgrounds(dark: dark)[0]
        #expect(fill == RGB(hex: hex).over(normalRow, opacity: ColorContrast.chipBackgroundOpacity))
        // What a translucent fill gave on the accent row: not the color the text was made for.
        let translucentOnAccent = RGB(hex: hex).over(ColorContrast.selectedRowBackground(dark: dark),
                                                     opacity: ColorContrast.chipBackgroundOpacity)
        #expect(fill != translucentOnAccent)
    }

    /// With Increase Contrast, the chip's outline stands out (3:1) on every row: through its border
    /// on normal and grey selected rows, through its opaque fill on the accent color.
    @Test(arguments: colors, appearances)
    func increasedContrastChipStandsOut(hex: String, dark: Bool) {
        let border = ColorContrast.chipBorder(tagHex: hex, dark: dark)
        let fill = ColorContrast.chipBackground(tagHex: hex, dark: dark)
        for row in ColorContrast.rowBackgrounds(dark: dark) + ColorContrast.greySelectedRowBackgrounds(dark: dark) {
            #expect(ColorContrast.ratio(border, row) >= ColorContrast.minimumNonTextContrast, "\(hex) against \(row)")
        }
        let accent = ColorContrast.selectedRowBackground(dark: dark)
        #expect(ColorContrast.ratio(fill, accent) >= ColorContrast.minimumNonTextContrast,
                "\(hex) fill against the accent: \(ColorContrast.ratio(fill, accent))")
    }

    /// The selected row is drawn in the accent color; the constants must follow the asset.
    @Test func selectedRowMatchesTheAccentColorAsset() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "DocumentArchive/Assets.xcassets/AccentColor.colorset/Contents.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try #require(json["colors"] as? [[String: Any]])
        func component(_ value: Any?) throws -> Double {
            let text = try #require(value as? String)
            if text.hasPrefix("0x") { return Double(try #require(Int(text.dropFirst(2), radix: 16))) / 255 }
            return try #require(Double(text))
        }
        var found: [Bool: RGB] = [:]
        for entry in entries {
            let isDark = (entry["appearances"] as? [[String: String]])?.contains { $0["value"] == "dark" } ?? false
            let components = try #require((entry["color"] as? [String: Any])?["components"] as? [String: Any])
            found[isDark] = RGB(red: try component(components["red"]), green: try component(components["green"]),
                                blue: try component(components["blue"]))
        }
        for dark in [false, true] {
            let asset = try #require(found[dark], "accent color for \(dark ? "dark" : "light") missing")
            let constant = ColorContrast.selectedRowBackground(dark: dark)
            #expect(abs(asset.red - constant.red) < 0.003 && abs(asset.green - constant.green) < 0.003
                    && abs(asset.blue - constant.blue) < 0.003, "\(dark ? "dark" : "light"): \(asset) vs \(constant)")
        }
    }

    @Test func readableColorsStayUnchangedAndOthersKeepTheirHue() {
        // Already dark enough on light rows: unchanged
        #expect(ColorContrast.chipText(tagHex: "#1E3A8A", dark: false) == RGB(hex: "#1E3A8A"))
        // Too light: darkened, but still blue rather than grey
        let blue = ColorContrast.chipText(tagHex: "#3B82F6", dark: false)
        #expect(blue != RGB(hex: "#3B82F6"))
        #expect(blue.blue > blue.red && blue.blue > blue.green)
        // Dark appearance lightens instead
        #expect(ColorContrast.luminance(ColorContrast.chipText(tagHex: "#6366F1", dark: true))
                > ColorContrast.luminance(RGB(hex: "#6366F1")))
    }
}
