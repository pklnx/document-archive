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

    /// Background of a selected row: the app's accent color (AccentColor asset).
    static let selectedRowBackground = RGB(red: 0.13, green: 0.56, blue: 0.40)

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

    /// The tag color, darkened (light appearance) or lightened (dark appearance) just enough to
    /// reach `minimum` against every background. Keeps the hue recognizable.
    static func adjusted(_ color: RGB, against backgrounds: [RGB], dark: Bool, minimum: Double) -> RGB {
        let target = dark ? RGB.white : RGB.black
        var amount = 0.0
        var result = color
        while backgrounds.contains(where: { ratio(result, $0) < minimum }), amount < 1 {
            amount = min(1, amount + 0.02)
            result = color.mixed(with: target, amount: amount)
        }
        return result
    }

    /// Text color of a tag chip: readable (4.5:1) on the chip's tinted background on every row
    /// background of the appearance.
    static func chipText(tagHex: String, dark: Bool) -> RGB {
        let tag = RGB(hex: tagHex)
        let chipBackgrounds = rowBackgrounds(dark: dark).map { tag.over($0, opacity: chipBackgroundOpacity) }
        return adjusted(tag, against: chipBackgrounds, dark: dark, minimum: minimumTextContrast)
    }

    /// Border of a tag chip with Increase Contrast: 3:1 against the normal and the selected row.
    static func chipBorder(tagHex: String, dark: Bool) -> RGB {
        let backgrounds = rowBackgrounds(dark: dark) + [selectedRowBackground]
        return adjusted(RGB(hex: tagHex), against: backgrounds, dark: dark, minimum: minimumNonTextContrast)
    }
}
