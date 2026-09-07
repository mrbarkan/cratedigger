import AppKit
import SwiftUI

/// The theme's mark, opposite "CrateDigger" on the header: the logo image its
/// bundle carries, else its name set the same way the app's own is. Right-
/// aligned against the switcher column's edge, mirroring the brand row.
struct ThemeLogo: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        Group {
            // ponytail: decoded straight off disk on each theme change — it's
            // one small image, and a cache keyed by URL would serve a stale
            // one after a same-name re-import. Move to a stamp-keyed cache
            // only if theme edits ever get sluggish.
            if let url = theme.logoURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text(theme.name)
                    .font(CarbonFont.sans(14, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .carbonTip(theme.logoURL == nil ? "\(theme.name), the active theme. Add a logo to it in the theme editor." : theme.name)
    }
}
