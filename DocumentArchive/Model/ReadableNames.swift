import Foundation

/// Names VoiceOver reads for the tag colors and symbols and the document type symbols in the editors.
extension Tag {
    /// One name per color in `palette`, in the same order.
    static var paletteNames: [String] {
        [
            String(localized: "Red"), String(localized: "Orange"), String(localized: "Yellow"),
            String(localized: "Green"), String(localized: "Teal"), String(localized: "Blue"),
            String(localized: "Indigo"), String(localized: "Purple"), String(localized: "Pink"),
            String(localized: "Slate"),
        ]
    }

    /// The name of a palette color; other colors (synced from elsewhere) get a generic name.
    static func colorName(for hex: String) -> String {
        if let index = palette.firstIndex(where: { $0.caseInsensitiveCompare(hex) == .orderedSame }) {
            return paletteNames[index]
        }
        return String(localized: "Custom color")
    }

    /// One name per symbol in `symbolChoices`.
    static var symbolNames: [String: String] {
        [
            "tag.fill": String(localized: "Tag"),
            "folder.fill": String(localized: "Folder"),
            "star.fill": String(localized: "Star"),
            "heart.fill": String(localized: "Heart"),
            "flag.fill": String(localized: "Flag"),
            "bookmark.fill": String(localized: "Bookmark"),
            "house.fill": String(localized: "Home"),
            "car.fill": String(localized: "Car"),
            "briefcase.fill": String(localized: "Work"),
            "cross.case.fill": String(localized: "Health"),
            "eurosign.circle.fill": String(localized: "Money"),
            "building.columns.fill": String(localized: "Bank"),
            "graduationcap.fill": String(localized: "Education"),
            "airplane": String(localized: "Travel"),
            "cart.fill": String(localized: "Shopping"),
            "bolt.fill": String(localized: "Energy"),
            "pawprint.fill": String(localized: "Pets"),
            "leaf.fill": String(localized: "Garden"),
        ]
    }

    /// The name of a tag symbol; symbols not offered here (synced from elsewhere) get a generic name.
    static func symbolName(for symbol: String) -> String {
        symbolNames[symbol] ?? String(localized: "Symbol")
    }
}

extension DocumentType {
    /// One name per symbol in `symbolChoices`.
    static var symbolNames: [String: String] {
        [
            "doc.text": String(localized: "Document"),
            "eurosign.circle": String(localized: "Money"),
            "doc.plaintext": String(localized: "Text"),
            "envelope": String(localized: "Letter"),
            "signature": String(localized: "Signature"),
            "list.bullet.rectangle": String(localized: "List"),
            "building.columns": String(localized: "Bank"),
            "cross.case": String(localized: "Health"),
            "house": String(localized: "Home"),
            "car": String(localized: "Car"),
            "shield": String(localized: "Insurance"),
            "person.text.rectangle": String(localized: "ID card"),
            "graduationcap": String(localized: "Education"),
            "briefcase": String(localized: "Work"),
            "cart": String(localized: "Shopping"),
            "bolt": String(localized: "Energy"),
            "phone": String(localized: "Phone"),
            "airplane": String(localized: "Travel"),
        ]
    }

    static func symbolName(for symbol: String) -> String {
        symbolNames[symbol] ?? String(localized: "Symbol")
    }
}
