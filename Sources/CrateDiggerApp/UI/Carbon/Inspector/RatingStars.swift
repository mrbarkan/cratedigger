import SwiftUI
import CrateDiggerCore

/// Five stars in the inspector. Clicking a lit star clears back to unrated, so
/// the control can undo itself without a separate button.
struct RatingStars: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    @State private var hovered: Int = 0

    var body: some View {
        // Nothing really selected: the stars stay drawn so the row does not jump,
        // but they are inert. Rating writes straight into a store with no undo,
        // so it must not act on the browser's fallback "first visible track".
        let enabled = model.hasRatableSelection
        let rating = enabled ? model.ratingForSelection : 0

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
                .disabled(!enabled)
                .onHover { inside in hovered = (inside && enabled) ? star : 0 }
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
            }
        }
        .opacity(enabled ? 1 : 0.4)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .help(enabled
              ? "Rate the selected tracks. Click the same star again to clear."
              : "Select a track to rate it.")
    }
}
