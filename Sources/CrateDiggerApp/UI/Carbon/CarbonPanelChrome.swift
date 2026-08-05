import SwiftUI

/// Shared header and footer for the tool panels (Edit Tags, Fix Tags, Match
/// Tags, Library Cleanup, Artwork Search).
///
/// They had drifted into three different looks — different title sizes, tracking
/// and ink, some with a raised bar behind the title and some without, some
/// separated by a `Divider()` and some by a hairline overlay. Individually
/// defensible, collectively they read as three separate apps bolted together.
/// One definition each, used everywhere.
struct CarbonPanelHeader<Accessory: View>: View {
    @Environment(\.carbon) private var theme
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title.uppercased())
                .font(CarbonFont.mono(11, weight: .bold))
                .tracking(2)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.chassisHi)
        .overlay(
            Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1),
            alignment: .bottom
        )
    }
}

/// The action bar. Buttons belong on the trailing edge; anything explanatory
/// goes in `leading` so it doesn't compete with them.
struct CarbonPanelFooter<Leading: View, Trailing: View>: View {
    @Environment(\.carbon) private var theme
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    init(
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            leading()
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(theme.chassisHi)
        .overlay(
            Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1),
            alignment: .top
        )
    }
}

/// A secondary (non-committing) panel button — Cancel, Close, Re-Scan.
/// Replaces the mix of `.bordered` system buttons and bare `Button("…")` that
/// had crept into these panels, which rendered as stock macOS controls sitting
/// inside a skeuomorphic panel.
struct CarbonPanelButton: View {
    @Environment(\.carbonGeometry) private var geometry
    let title: String
    var style: KeyButtonStyle = .normal
    var width: CGFloat = 96
    let action: () -> Void

    var body: some View {
        KeyButton(style: style, action: action) {
            Text(title.uppercased())
                .font(CarbonFont.mono(9.5, weight: .bold))
                .tracking(1.5)
                .lineLimit(1)
        }
        .frame(width: width, height: geometry.keyHeight)
    }
}
