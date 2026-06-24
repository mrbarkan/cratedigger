import SwiftUI

struct HeaderShell: View {
    var body: some View {
        // Brand column == Sources width (+ matching gap) so the OLED's LEFT
        // edge lines up with the browser's left seam. The right cluster keeps
        // its natural width, so the OLED still flexes all the way out to the
        // VIEW/THEME/EQ buttons.
        HStack(spacing: CarbonLayout.mainGap) {
            BrandBlock()
                .frame(width: CarbonLayout.sidebarWidth, alignment: .leading)
            OLEDDisplay()
                .frame(maxWidth: .infinity)
            ViewSwitcherColumn()
                .frame(width: CarbonLayout.viewSwitchWidth)
        }
    }
}
