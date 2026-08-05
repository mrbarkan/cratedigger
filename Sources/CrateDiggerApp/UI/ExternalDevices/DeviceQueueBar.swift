import CrateDiggerCore
import SwiftUI

/// The "what's going to this device" strip, shown above the browser while an
/// offline device is selected.
///
/// A queue for an unplugged device is otherwise invisible: the files aren't on
/// the device, and for copy-mode profiles they aren't staged on this Mac either.
/// The only prior signal was a PENDING badge per row, which doesn't answer how
/// much is queued, how big it is, or whether anything is broken.
struct DeviceQueueBar: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        let summary = model.offlineDeviceQueueSummary
        HStack(spacing: 10) {
            Image(systemName: summary.isEmpty ? "tray" : "tray.full.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(summary.isEmpty ? theme.ink4 : theme.orange)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.headline)
                        .font(CarbonFont.sans(12, weight: .semibold))
                        .foregroundStyle(theme.ink)
                    if summary.missingSourceCount > 0 {
                        Text("\(summary.missingSourceCount) WILL FAIL")
                            .font(CarbonFont.mono(8, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(theme.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(theme.orange.opacity(0.6), lineWidth: 0.8)
                            )
                    }
                }
                if let detail = summary.detail {
                    Text(detail)
                        .font(CarbonFont.mono(8.5))
                        .foregroundStyle(theme.ink4)
                        .lineLimit(1)
                } else {
                    Text("Queue tracks with Transfer to Device while it's unplugged.")
                        .font(CarbonFont.mono(8.5))
                        .foregroundStyle(theme.ink4)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if !summary.isEmpty {
                // SYNC is only meaningful once the device is actually mounted;
                // the label says which of the two states you're in.
                KeyButton(style: model.offlineDeviceIsConnected ? .selected : .disabled,
                          action: { model.syncBrowsedOfflineDevice() }) {
                    Text(model.offlineDeviceIsConnected ? "SYNC NOW" : "NOT CONNECTED")
                        .font(CarbonFont.mono(8.5, weight: .bold))
                        .tracking(1)
                        .padding(.horizontal, 8)
                }
                .frame(height: 22)
                .disabled(!model.offlineDeviceIsConnected)
                .carbonTip(model.offlineDeviceIsConnected
                           ? "Copy the queue to \(model.offlineDeviceProfile?.name ?? "the device")"
                           : "Connect \(model.offlineDeviceProfile?.name ?? "the device") to sync")

                KeyButton(style: .normal, action: { model.clearOfflineDeviceQueue() }) {
                    Text("CLEAR")
                        .font(CarbonFont.mono(8.5, weight: .bold))
                        .tracking(1)
                        .padding(.horizontal, 8)
                }
                .frame(height: 22)
                .carbonTip("Empty the queue and delete anything staged for it")
            }
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
    }
}
