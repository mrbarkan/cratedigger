import SwiftUI

struct ConversionSummarySheetView: View {
    let report: ConversionReport
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(report.title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(Color(nsColor: ModernRetroTheme.textPrimary))

            Text(report.statusLine)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(nsColor: ModernRetroTheme.statusColor(for: report.tone)))
                .accessibilityLabel("Conversion status: \(report.statusLine)")

            ScrollView {
                Text(report.details)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(Color(nsColor: ModernRetroTheme.textPrimary))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: ModernRetroTheme.surfaceElevated))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(nsColor: ModernRetroTheme.separator).opacity(0.35), lineWidth: 1)
                    )
                    .accessibilityLabel("Conversion details")
            }

            HStack {
                Spacer()
                Button("Close") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .tint(Color(nsColor: ModernRetroTheme.accentInfo))
                .accessibilityHint("Dismiss the conversion summary.")
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 420)
        .background(Color(nsColor: ModernRetroTheme.surfaceBase))
    }
}
