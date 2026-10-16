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

    /// Light and dark appearance, each on a normal and on a selected row.
    static let situations = [(false, false), (false, true), (true, false), (true, true)]
        .map { Situation(dark: $0.0, selected: $0.1) }

    struct Situation: CustomTestStringConvertible {
        var dark: Bool
        var selected: Bool
        var testDescription: String { "\(dark ? "dark" : "light")\(selected ? ", selected" : "")" }
        var rows: [RGB] { ColorContrast.backgrounds(dark: dark, selected: selected) }
    }

    @Test func selectedRowsUseTheAccentColor() {
        #expect(ColorContrast.backgrounds(dark: true, selected: true) == [ColorContrast.selectedRowBackground(dark: true)])
        #expect(ColorContrast.backgrounds(dark: false, selected: false) == ColorContrast.rowBackgrounds(dark: false))
    }

    @Test(arguments: colors, situations)
    func chipTextIsReadable(hex: String, situation: Situation) {
        let tag = RGB(hex: hex)
        let text = ColorContrast.chipText(tagHex: hex, dark: situation.dark, selected: situation.selected)
        for row in situation.rows {
            let chip = tag.over(row, opacity: ColorContrast.chipBackgroundOpacity)
            #expect(ColorContrast.ratio(text, chip) >= ColorContrast.minimumTextContrast,
                    "\(hex): \(ColorContrast.ratio(text, chip))")
        }
    }

    @Test(arguments: colors, situations)
    func increasedContrastBorderStandsOut(hex: String, situation: Situation) {
        let border = ColorContrast.chipBorder(tagHex: hex, dark: situation.dark, selected: situation.selected)
        for row in situation.rows {
            #expect(ColorContrast.ratio(border, row) >= ColorContrast.minimumNonTextContrast, "\(hex) against \(row)")
        }
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
