import SwiftUI

struct ViewSwitcherColumn: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(OLEDView.allCases, id: \.self) { view in
                ViewSwitchButton(view: view, isOn: model.oledView == view) {
                    model.oledView = view
                }
            }
        }
    }
}

private struct ViewSwitchButton: View {
    @Environment(\.carbon) private var theme
    let view: OLEDView
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        KeyButton(style: isOn ? .selected : .normal, action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.black.opacity(0.25))
                        .frame(width: 6, height: 6)
                    if isOn {
                        Circle()
                            .fill(theme.orange)
                            .frame(width: 6, height: 6)
                            .shadow(color: theme.orange, radius: 4)
                    }
                }
                Text(view.label.uppercased())
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(1.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity)
    }
}
