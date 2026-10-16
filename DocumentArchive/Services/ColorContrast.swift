import Foundation

/// Contrast calculations after WCAG 2.x, used for tag chips: text needs 4.5:1 against its
/// background, borders and other non-text parts 3:1.
enum ColorContrast {
    /// An sRGB color with components from 0 to 1.
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// "#RRGGBB" or "RRGGBB"; unreadable values give the default tag blue, like `Color(hex:)`.
        init(hex: String) {
            let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            let value = UInt64(cleaned, radix: 16) ?? 0x3B82F6
            self.init(red: Double((value >> 16) & 0xFF) / 255,
                      green: Double((value >> 8) & 0xFF) / 255,
                      blue: Double(value & 0xFF) / 255)
        }

        static let black = RGB(red: 0, green: 0, blue: 0)
        static let white = RGB(red: 1, green: 1, blue: 1)

        /// `self` drawn with `opacity` over `background`.
        func over(_ background: RGB, opacity: Double) -> RGB {
            RGB(red: red * opacity + background.red * (1 - opacity),
                green: green * opacity + background.green * (1 - opacity),
                blue: blue * opacity + background.blue * (1 - opacity))
        }

        /// Moves the color towards `target` by `amount` (0 = unchanged, 1 = target).
        func mixed(with target: RGB, amount: Double) -> RGB {
            target.over(self, opacity: amount)
        }
    }

    static let minimumTextContrast = 4.5
    static let minimumNonTextContrast = 3.0
    /// Opacity of the tag color behind the chip text (see `TagChip`).
    static let chipBackgroundOpacity = 0.18

    /// Row backgrounds a chip can sit on, per appearance. Dark covers the plain black list and the
    /// grouped/secondary dark background.
    static func rowBackgrounds(dark: Bool) -> [RGB] {
        dark ? [RGB.black, RGB(hex: "#1C1C1E")] : [RGB.white, RGB(hex: "#F2F2F7")]
    }

    /// Background of a selected row in a focused list on iPad and macOS: the app's accent color
    /// (AccentColor asset, Petrol, the same in light and dark mode). `ColorContrastTests` checks
    /// that this matches the asset.
    static func selectedRowBackground(dark: Bool) -> RGB {
        RGB(hex: "#0B7480")
    }

    /// The grey a selected row gets instead of the accent color: iPhone edit mode and a macOS list
    /// without focus (approximate system colors).
    static func greySelectedRowBackgrounds(dark: Bool) -> [RGB] {
        dark ? [RGB(hex: "#3A3A3C"), RGB(hex: "#464646")] : [RGB(hex: "#D1D1D6"), RGB(hex: "#DCDCDC")]
    }

    /// Every row background a chip can sit on: normal rows and selected rows (grey or accent).
    static func allRowBackgrounds(dark: Bool) -> [RGB] {
        rowBackgrounds(dark: dark) + greySelectedRowBackgrounds(dark: dark) + [selectedRowBackground(dark: dark)]
    }

    /// Relative luminance (WCAG 2.x).
    static func luminance(_ color: RGB) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// Contrast ratio from 1 (none) to 21 (black on white).
    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The tag color, changed as little as possible to reach `minimum` against every background,
    /// so the hue stays recognizable. It is darkened first in the light appearance and lightened
    /// first in the dark one. If the backgrounds are far apart, only a narrow band works, so the
    /// search uses small steps. Without any
    /// solution, the candidate with the best worst-case contrast wins.
    static func adjusted(_ color: RGB, against backgrounds: [RGB], dark: Bool, minimum: Double) -> RGB {
        func worstRatio(_ candidate: RGB) -> Double {
            backgrounds.map { ratio(candidate, $0) }.min() ?? .infinity
        }
        let targets = dark ? [RGB.white, RGB.black] : [RGB.black, RGB.white]
        var best = color
        var bestRatio = worstRatio(color)
        if bestRatio >= minimum { return color }
        for step in 1...500 {
            let amount = Double(step) / 500
            for target in targets {
                let candidate = color.mixed(with: target, amount: amount)
                let candidateRatio = worstRatio(candidate)
                if candidateRatio >= minimum { return candidate }
                if candidateRatio > bestRatio { (best, bestRatio) = (candidate, candidateRatio) }
            }
        }
        return best
    }

    /// Fill of a tag chip: the tag color at `chipBackgroundOpacity` over the normal row background,
    /// drawn **opaque**. The chip therefore looks the same on every row, selected or not, and its
    /// text contrast does not depend on how the platform draws a selected row (accent color on
    /// iPad and in a focused macOS list, grey in iPhone edit mode and in an unfocused macOS list).
    /// SwiftUI's `backgroundProminence` is not reliable for this: on iPad a row that stays
    /// selected while more rows are added keeps `.standard` on its accent background.
    static func chipBackground(tagHex: String, dark: Bool) -> RGB {
        RGB(hex: tagHex).over(rowBackgrounds(dark: dark)[0], opacity: chipBackgroundOpacity)
    }

    /// Text color of a tag chip: readable (4.5:1) on the chip's fill.
    static func chipText(tagHex: String, dark: Bool) -> RGB {
        adjusted(RGB(hex: tagHex), against: [chipBackground(tagHex: tagHex, dark: dark)], dark: dark,
                 minimum: minimumTextContrast)
    }

    /// Border of a tag chip with Increase Contrast: 3:1 against the normal and the grey selected
    /// rows, and in dark mode also against the accent color of a selected row (Petrol is dark, so
    /// one light border reaches all of them). In light mode the opaque, light fill itself stands
    /// out on the accent color (see tests).
    static func chipBorder(tagHex: String, dark: Bool) -> RGB {
        let rows = rowBackgrounds(dark: dark) + greySelectedRowBackgrounds(dark: dark)
        return adjusted(RGB(hex: tagHex), against: dark ? rows + [selectedRowBackground(dark: dark)] : rows,
                        dark: dark, minimum: minimumNonTextContrast)
    }
}
