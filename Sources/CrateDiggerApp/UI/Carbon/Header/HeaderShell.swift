import SwiftUI

struct HeaderShell: View {
    var body: some View {
        HStack(spacing: 16) {
            BrandBlock()
                .frame(width: CarbonLayout.brandWidth, alignment: .leading)
            OLEDDisplay()
                .frame(maxWidth: .infinity)
            ViewSwitcherColumn()
                .frame(width: CarbonLayout.viewSwitchWidth)
        }
        .padding(.horizontal, 6)
    }
}
