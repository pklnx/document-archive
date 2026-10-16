import SwiftUI

/// The detail column while two or more documents are selected (macOS, iPad in regular width):
/// how many, a few thumbnails and all bulk actions.
struct BulkActionsView: View {
    let documents: [Document]

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    ThumbnailStack(documents: Array(documents.prefix(3)))
                        .accessibilityHidden(true)
                    Text("\(documents.count) documents selected")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            BulkActionsMenu(documents: documents, inSections: true)
        }
        .formStyle(.grouped)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .navigationTitle(Text("\(documents.count) documents selected"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier(AccessibilityID.bulkActions)
    }
}

/// Up to three thumbnails, fanned out like a stack of paper.
private struct ThumbnailStack: View {
    let documents: [Document]

    var body: some View {
        ZStack {
            ForEach(Array(documents.enumerated().reversed()), id: \.element.id) { index, document in
                ThumbnailView(data: document.isAlive ? document.thumbnailData : nil)
                    .frame(width: 72, height: 96)
                    .rotationEffect(.degrees(Double(index) * 6 - 6))
                    .offset(x: CGFloat(index) * 14 - 14)
            }
        }
        .frame(height: 110)
    }
}
