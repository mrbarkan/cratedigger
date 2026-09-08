import CrateDiggerCore
import SwiftUI

/// What a conversion, transfer or sync just did.
///
/// It used to print the raw log into one monospace block: an eighteen-file sync
/// arrived as a wrapping paragraph of repeated folder paths with the one line
/// that mattered — a failure — buried in it. The report is a list of files, so
/// it is drawn as one: a status band that answers the question on its own, and
/// per-file rows that lead with the filename and keep the folder dim behind it.
struct ConversionSummarySheetView: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry

    let report: ConversionReport
    let onClose: () -> Void

    private var lines: [TransferLogLine] { TransferLogLine.parse(report.details) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if report.showsDetailsButton, !lines.isEmpty {
                log
            } else {
                Spacer(minLength: 0)
            }
            footer
        }
        .frame(minWidth: 620, idealWidth: 660, minHeight: 380, idealHeight: 460)
        .background(theme.chassis)
        .onExitCommand(perform: onClose)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(tone.opacity(0.14))
                Image(systemName: glyph)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tone)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 5) {
                Text(report.title)
                    .font(CarbonFont.sans(19, weight: .bold))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(report.statusLine)
                    .font(CarbonFont.mono(10, weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(tone)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Status: \(report.statusLine)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var tone: Color { theme.statusColor(for: report.tone) }

    private var glyph: String {
        switch report.tone {
        case .success:          return "checkmark.circle.fill"
        case .warning:          return "exclamationmark.triangle.fill"
        case .error:            return "xmark.octagon.fill"
        case .info, .neutral:   return "info.circle.fill"
        }
    }

    // MARK: - Per-file log

    private var log: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("FILES")
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(theme.ink4)
                Spacer(minLength: 0)
                Text("\(lines.count)")
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.ink4)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(lines) { line in
                        LogRow(line: line)
                    }
                }
            }
            // Selectable so a failure reason can still be copied into a bug
            // report — the old block's one real virtue.
            .textSelection(.enabled)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.well)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.hair.opacity(0.6), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel("Per-file results")
        }
        .padding(.horizontal, 22)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            KeyButton(style: .glowingFilled, action: onClose) { Text("CLOSE") }
                .frame(width: 104, height: geometry.keyHeight)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Dismiss the summary.")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }
}

/// One file: its badge, its name, and the folder it went to underneath.
private struct LogRow: View {
    @Environment(\.carbon) private var theme
    let line: TransferLogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            if let badge = line.outcome.badge {
                Text(badge)
                    .font(CarbonFont.mono(7.5, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(color)
                    .frame(width: 34)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(color.opacity(0.55), lineWidth: 0.8)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(line.name)
                    .font(CarbonFont.sans(11.5, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !line.parent.isEmpty {
                    Text(line.parent)
                        .font(CarbonFont.mono(8.5))
                        .foregroundStyle(theme.ink4)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let note = line.note {
                    Text(note)
                        .font(CarbonFont.mono(9))
                        .foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.035) : Color.black.opacity(0.05))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var color: Color {
        switch line.outcome {
        case .ok:        return theme.statusColor(for: .success)
        case .skipped:   return theme.ink3
        case .failed:    return theme.statusColor(for: .error)
        case .cancelled: return theme.statusColor(for: .warning)
        case .other:     return theme.ink3
        }
    }
}
