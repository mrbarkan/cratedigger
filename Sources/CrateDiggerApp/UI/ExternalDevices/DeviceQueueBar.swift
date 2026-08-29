import CrateDiggerCore
import SwiftUI

/// The "what's going to this device" strip, pinned above the device browser.
///
/// A queue is otherwise invisible: it lives in a JSON file, its files may not be
/// on this Mac at all, and a convert-mode hand-off sits inside the CNVRT cockpit
/// two panes away. This line answers what's waiting and what to press. Detail
/// stays in the tooltip — the strip is a status light, not a paragraph.
struct DeviceQueueBar: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    let profile: ExternalDeviceProfile

    /// A cockpit hand-off for *this* device outranks its queue: it's the send
    /// you're in the middle of.
    private var routed: PendingDeviceConversion? {
        guard let pending = model.pendingDeviceConversion, pending.profileID == profile.id else { return nil }
        return pending
    }

    private var summary: DeviceSyncQueueSummary { model.syncQueueSummary(profileID: profile.id) }
    private var isConnected: Bool { model.isDeviceConnected(profileID: profile.id) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isIdle ? theme.ink4 : theme.orange)

            Text(profile.name.uppercased())
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(theme.ink2)

            Text(headline)
                .font(CarbonFont.sans(12, weight: .semibold))
                .foregroundStyle(theme.ink)
                .lineLimit(1)

            if summary.missingSourceCount > 0 {
                warnBadge("\(summary.missingSourceCount) WILL FAIL")
            }
            if !isConnected && !isIdle {
                warnBadge("NOT CONNECTED")
            }

            Spacer(minLength: 8)

            // KeyButton's background fills whatever it is given, so the group is
            // sized here — left to itself it eats half the strip.
            HStack(spacing: 8) { actions }
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.isDark ? Color.black.opacity(0.28) : Color.black.opacity(0.035))
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.08))
                .frame(height: 1),
            alignment: .bottom
        )
        .carbonTip(detail)
    }

    // MARK: - State

    /// Nothing routed and nothing queued — the strip is only here because
    /// you're standing on the device.
    private var isIdle: Bool { routed == nil && summary.isEmpty }

    private var icon: String {
        if routed != nil { return "arrow.right.circle.fill" }
        return summary.isEmpty ? "tray" : "tray.full.fill"
    }

    private var headline: String {
        if let routed {
            let n = routed.tracks.count
            return "\(n) track\(n == 1 ? "" : "s") ready to send"
        }
        return summary.headline
    }

    /// The long form, on hover only.
    private var detail: String {
        if routed != nil {
            let queued = summary.isEmpty ? "" : " · \(summary.totalCount) also queued"
            return "Waiting in CNVRT — set the format there, then press SEND\(queued)"
        }
        if let detail = summary.detail {
            return summary.pendingConversionCount > 0
                ? "\(detail) at \(profile.transferSettings.summary) — Settings opens Conversion to pre-convert or change it"
                : detail
        }
        return "Send tracks here with Transfer to Device; they wait until you press SYNC."
    }

    private func warnBadge(_ text: String) -> some View {
        Text(text)
            .font(CarbonFont.mono(8, weight: .bold))
            .tracking(1)
            .foregroundStyle(theme.orange)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(theme.orange.opacity(0.6), lineWidth: 0.8)
            )
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        if routed != nil {
            // Visual assist, not a second cockpit: the strip says a send is
            // waiting and walks you to where the button lives.
            KeyButton(style: .selected, action: { model.oledView = .conversion }) {
                Text("OPEN CNVRT")
            }
            .frame(width: 104, height: 22)
            .carbonTip("Show the conversion holding this send")
        } else if !summary.isEmpty {
            // Everything about *how* this queue converts belongs in one place,
            // and that place is the conversion panel — including pre-converting it.
            KeyButton(style: .normal, action: { model.oledView = .conversion }) {
                Text("SETTINGS")
            }
            .frame(width: 88, height: 22)
            .carbonTip("Open Conversion: format, folder layout, and PRE-CONVERT for this queue")

            KeyButton(style: isConnected ? .selected : .disabled,
                      action: { model.syncQueuedTransfers(profileID: profile.id) }) {
                Text("SYNC NOW")
            }
            .frame(width: 92, height: 22)
            .disabled(!isConnected)
            .carbonTip(isConnected
                       ? "Copy the queue to \(profile.name)"
                       : "Connect \(profile.name) to sync")

            KeyButton(style: .normal, action: { model.clearSyncQueue(profileID: profile.id) }) {
                Text("CLEAR")
            }
            .frame(width: 66, height: 22)
            .carbonTip("Empty the queue and delete anything staged for it")
        }
    }
}
