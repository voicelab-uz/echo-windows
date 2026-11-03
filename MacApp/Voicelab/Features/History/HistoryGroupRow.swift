import SwiftUI

/// Each recording is its own rounded card, separated from the next by a small gap.
/// Rows stay direct, stable scroll targets; the card is only a background.
struct HistoryCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Design.canvas)
            .clipShape(RoundedRectangle(cornerRadius: settingsGroupRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: settingsGroupRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1).allowsHitTesting(false)
            }
            .padding(.bottom, 8)
    }
}

/// The one big container behind every day heading and card. Drawn as joined strips so
/// the rows remain direct children of the lazy stack: the first strip rounds the top
/// corners, the last strip rounds the bottom ones.
struct HistoryContainer: ViewModifier {
    let first: Bool
    let last: Bool
    private let radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.bottom, last ? 2 : 0)
            .background(
                .fill.quaternary,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: first ? radius : 0, bottomLeadingRadius: last ? radius : 0,
                    bottomTrailingRadius: last ? radius : 0, topTrailingRadius: first ? radius : 0,
                    style: .continuous))
    }
}
