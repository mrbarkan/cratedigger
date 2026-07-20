import SwiftUI

struct HeaderShell: View {
    @Environment(\.carbonGeometry) private var geometry

    var body: some View {
        // v10 header grid: brand 156 · OLED flex · switcher 110, gap 12. This
        // intentionally breaks the old "brand == Sources width" seam alignment
        // (approved) — the brand column is now a fixed 156 and the OLED flexes
        // between it and the VIEW/THEME/EQ switcher.
        HStack(spacing: geometry.mainGap) {
            BrandBlock()
                .frame(width: geometry.brandWidth, alignment: .leading)
            OLEDDisplay()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ViewSwitcherColumn()
                .frame(width: geometry.viewSwitchWidth)
        }
        .overlay(alignment: .topTrailing) {
            StatusLED()
                .padding(.top, 4)
                .padding(.trailing, 4)
        }
    }
}
