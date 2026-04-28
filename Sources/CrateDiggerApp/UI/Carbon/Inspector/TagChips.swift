import CrateDiggerCore
import SwiftUI

struct TagChips: View {
    @Environment(\.carbon) private var theme
    let album: Album?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(chips, id: \.label) { chip in
                ChipView(label: chip.label, style: chip.style)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chips: [Chip] {
        guard let album else { return [Chip(label: "—", style: .normal)] }
        var collected: [Chip] = []
        for format in album.formats.sorted() {
            collected.append(Chip(label: format.uppercased(), style: format.lowercased() == "flac" ? .dark : .normal))
        }
        if let year = album.year {
            collected.append(Chip(label: String(year), style: .normal))
        }
        if collected.isEmpty {
            collected.append(Chip(label: "—", style: .normal))
        }
        return collected
    }

    private struct Chip {
        let label: String
        let style: ChipStyle
    }
}

private enum ChipStyle {
    case normal
    case dark
    case orange
}

private struct ChipView: View {
    @Environment(\.carbon) private var theme
    let label: String
    let style: ChipStyle

    var body: some View {
        Text(label)
            .font(CarbonFont.mono(9, weight: .semibold))
            .tracking(1.6)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(textColor)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .normal: Rectangle().fill(theme.isDark ? Color(hex: 0x2A2A27) : theme.chassisHi)
        case .dark:   Rectangle().fill(theme.ink)
        case .orange: Rectangle().fill(theme.orange)
        }
    }

    private var textColor: Color {
        switch style {
        case .normal: return theme.ink2
        case .dark:   return theme.isDark ? theme.orange : Color(hex: 0xF3F6EC)
        case .orange: return .white
        }
    }

    private var borderColor: Color {
        switch style {
        case .normal: return theme.isDark ? Color(hex: 0x3A3A37) : theme.chassisLo
        case .dark:   return Color.black
        case .orange: return theme.orangeLo
        }
    }
}
