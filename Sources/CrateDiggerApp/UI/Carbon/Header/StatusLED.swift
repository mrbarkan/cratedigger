import SwiftUI

/// Tiny activity lamp in the header's top-right corner: recessed-dark when
/// idle, amber breathing pulse while the app is working. Hover lists what's
/// running. The repeatForever animation is attached only while working and
/// cancelled on idle — an idle LED must cost zero GPU (same rule as the
/// Material ban).
struct StatusLED: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(model.isWorking
                  ? theme.orange.opacity(pulsing ? 1.0 : 0.35)
                  : Color.black.opacity(0.35))
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
            .shadow(color: model.isWorking ? theme.orange.opacity(pulsing ? 0.7 : 0.15) : .clear,
                    radius: pulsing ? 4 : 1)
            .help(helpText)
            .onChange(of: model.isWorking) { working in
                if working {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulsing = true
                    }
                } else {
                    // Reassigning the property with a non-repeating animation
                    // cancels the repeatForever — nothing animates while idle.
                    withAnimation(.linear(duration: 0.1)) { pulsing = false }
                }
            }
    }

    private var helpText: String {
        guard model.isWorking else { return "Idle" }
        let labels = model.activityLabels
        return labels.isEmpty ? "Working…" : labels.joined(separator: " · ")
    }
}
