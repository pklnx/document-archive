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

    @Test(arguments: colors, [false, true])
    func chipTextIsReadable(hex: String, dark: Bool) {
        let tag = RGB(hex: hex)
        let text = ColorContrast.chipText(tagHex: hex, dark: dark)
        for row in ColorContrast.rowBackgrounds(dark: dark) {
            let chip = tag.over(row, opacity: ColorContrast.chipBackgroundOpacity)
            #expect(ColorContrast.ratio(text, chip) >= ColorContrast.minimumTextContrast,
                    "\(hex) \(dark ? "dark" : "light"): \(ColorContrast.ratio(text, chip))")
        }
    }

    @Test(arguments: colors, [false, true])
    func increasedContrastBorderStandsOut(hex: String, dark: Bool) {
        let border = ColorContrast.chipBorder(tagHex: hex, dark: dark)
        for row in ColorContrast.rowBackgrounds(dark: dark) + [ColorContrast.selectedRowBackground] {
            #expect(ColorContrast.ratio(border, row) >= ColorContrast.minimumNonTextContrast,
                    "\(hex) \(dark ? "dark" : "light") against \(row)")
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
