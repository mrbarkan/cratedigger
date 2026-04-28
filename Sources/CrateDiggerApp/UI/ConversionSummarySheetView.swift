import SwiftUI

struct ConversionSummarySheetView: View {
    @Environment(\.carbon) private var theme

    let report: ConversionReport
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(report.title)
                .font(CarbonFont.sans(26, weight: .bold))
                .foregroundStyle(theme.ink)

            Text(report.statusLine)
                .font(CarbonFont.mono(13, weight: .medium))
                .foregroundStyle(theme.statusColor(for: report.tone))
                .accessibilityLabel("Conversion status: \(report.statusLine)")

            ScrollView {
                Text(report.details)
                    .font(CarbonFont.mono(13))
                    .foregroundStyle(theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme.paper)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(theme.hair.opacity(0.5), lineWidth: 1)
                    )
                    .accessibilityLabel("Conversion details")
            }

            HStack {
                Spacer()
                Button("Close") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .tint(theme.orange)
                .accessibilityHint("Dismiss the conversion summary.")
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 420)
        .background(theme.chassis)
    }
}
