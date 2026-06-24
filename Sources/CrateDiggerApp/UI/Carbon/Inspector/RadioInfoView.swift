import CrateDiggerCore
import SwiftUI

/// Inspector INFO content for a selected stream — mirrors the v7 `.insp-radio-info`.
/// Replaces the album caption/specs/tools block while in radio mode.
struct RadioInfoView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    let stream: StreamSource

    private var isLive: Bool { stream.isLive }
    private var isNative: Bool { model.radioEngineKind == .native }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header
                specs
                chips
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            StreamThumbnail(stream: stream)
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.4), radius: 2)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.15), lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text(stream.title)
                    .font(CarbonFont.sans(15, weight: .heavy))
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(stream.channel)
                    .font(CarbonFont.mono(9.5, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(theme.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var specs: some View {
        VStack(spacing: 0) {
            specRow("Source", "YouTube")
            specRow("Type", isLive ? "Live Stream" : stream.kind.rawValue.capitalized)
            specRow("Codec", isNative ? (isLive ? "HLS" : "AAC · M4A") : "Embedded")
            specRow("Bitrate", isNative ? "VBR" : "—")
            specRow("Sample", isNative ? "48.0 kHz" : "—")
            specRow("Latency", isLive ? (isNative ? "~2.4 s" : "—") : "—")
            specRow("Added", addedString)
        }
        .padding(.vertical, 4)
    }

    private func specRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key.uppercased())
                .font(CarbonFont.mono(9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(theme.ink3)
            Spacer()
            Text(value)
                .font(CarbonFont.mono(10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var chips: some View {
        HStack(spacing: 8) {
            chip(isLive ? "LIVE" : stream.kind.rawValue.uppercased(), dark: true)
            chip("NO DRM", dark: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private func chip(_ text: String, dark: Bool) -> some View {
        Text(text)
            .font(CarbonFont.mono(8.5, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(dark ? Color(hex: 0xFFF1EC) : theme.ink2)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(dark
                    ? (isLive ? Color(red: 1, green: 0.36, blue: 0.29) : theme.indigo)
                    : theme.ink.opacity(theme.isDark ? 0.10 : 0.06))
            )
    }

    private var addedString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM yyyy"
        return fmt.string(from: stream.addedAt)
    }
}
