import SwiftUI

struct HeaderShell: View {
    var body: some View {
        // v10 header grid: brand 156 · OLED flex · switcher 110, gap 12. This
        // intentionally breaks the old "brand == Sources width" seam alignment
        // (approved) — the brand column is now a fixed 156 and the OLED flexes
        // between it and the VIEW/THEME/EQ switcher.
        HStack(spacing: CarbonLayout.mainGap) {
            BrandBlock()
                .frame(width: CarbonLayout.brandWidth, alignment: .leading)
            OLEDDisplay()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ViewSwitcherColumn()
                .frame(width: CarbonLayout.viewSwitchWidth)
        }
    }
}
