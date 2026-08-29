import SwiftUI
import CrateDiggerCore

/// Five stars in the inspector. Clicking a lit star clears back to unrated, so
/// the control can undo itself without a separate button.
struct RatingStars: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    @State private var hovered: Int = 0

    var body: some View {
        let rating = model.ratingForSelection

        HStack(spacing: 4) {
            Text("RATING")
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(theme.ink4)

            Spacer(minLength: 8)

            ForEach(1...5, id: \.self) { star in
                Button {
                    // Tapping the star you are already on clears the rating.
                    model.rateSelection(rating == star ? 0 : star)
                } label: {
                    Image(systemName: star <= (hovered > 0 ? hovered : rating) ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(star <= (hovered > 0 ? hovered : rating) ? theme.orange : theme.ink4)
                }
                .buttonStyle(.plain)
                .onHover { inside in hovered = inside ? star : 0 }
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .help("Rate the selected tracks. Click the same star again to clear.")
    }
}
