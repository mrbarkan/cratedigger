import Foundation

/// One album of the "Already on <device>" sheet, as text: what the device
/// holds next to what would be sent, why the row is there, and what Replace
/// would do to it. Pure so the words the user decides on are tested.
public struct DeviceReviewRow: Identifiable, Sendable {
    public let id: DeviceAlbumIdentity
    public let title: String
    public let artist: String
    /// "MP3 128k · 5 tracks · art 600 px"
    public let onDevice: String
    /// "FLAC 44.1 kHz · 11 tracks · art 1400 px"
    public let sending: String
    /// "2 copies on device", "A different file already uses this name", or nil.
    public let note: String?
    /// "Replaces 5 of 11 tracks" / "Replaces the whole album, 11 tracks removed"
    public let replaceEffect: String
    /// The user chose Leave it for this album on this device before. Such a row
    /// only shows when the sheet is asked to show albums left alone, and starts
    /// out answered Leave it, its recorded answer.
    public let isLeftAlone: Bool

    /// Audio form shows only on a copy-mode device, the only kind where it is
    /// compared: a convert-mode device writes the profile's format whatever
    /// the source, so a format there says nothing about the difference.
    public init(_ comparison: DeviceAlbumComparison, settings: ExternalDeviceTransferSettings) {
        id = comparison.identity
        title = comparison.displayAlbum
        artist = comparison.displayArtist
        isLeftAlone = comparison.isLeftAlone

        let showsForm = settings.mode == .copyOriginals
        if comparison.deviceTracks.isEmpty {
            onDevice = "None of its tracks"
        } else {
            onDevice = Self.describe(
                comparison.deviceTracks,
                art: comparison.deviceArtPixels,
                showsForm: showsForm
            )
        }
        sending = Self.describe(comparison.sent, art: comparison.sentArtPixels, showsForm: showsForm)

        var notes: [String] = []
        if comparison.deviceCopyCount > 1 {
            notes.append("\(comparison.deviceCopyCount) copies on device")
        }
        if comparison.differences.contains(.pathTaken) {
            notes.append("A different file already uses this name")
        }
        note = notes.isEmpty ? nil : notes.joined(separator: " · ")

        replaceEffect = Self.replaceEffect(of: comparison)
    }

    // MARK: - A review's rows

    /// The rows the sheet shows: every album asked about, in sending order,
    /// then (on request) the albums left alone before.
    public static func rows(
        for review: DeviceTransferReview,
        settings: ExternalDeviceTransferSettings,
        includingLeftAlone: Bool
    ) -> [DeviceReviewRow] {
        let asked = review.needingDecision
        let remembered = includingLeftAlone ? leftAlone(in: review) : []
        return (asked + remembered).map { DeviceReviewRow($0, settings: settings) }
    }

    /// Differing albums the sheet does not ask about because the user left
    /// them alone before: the "Show N albums left alone" count.
    public static func leftAloneCount(in review: DeviceTransferReview) -> Int {
        leftAlone(in: review).count
    }

    /// The rest of the batch, which needs no decision:
    /// "120 new · 14 already there · 6 albums to finish". New and already
    /// there count tracks; finishing counts albums (Gaps filled in).
    public static func summary(of review: DeviceTransferReview) -> String {
        var parts: [String] = []
        if review.newTrackCount > 0 { parts.append("\(review.newTrackCount) new") }
        if review.presentTrackCount > 0 { parts.append("\(review.presentTrackCount) already there") }
        if review.gapAlbumCount > 0 {
            parts.append("\(review.gapAlbumCount) \(review.gapAlbumCount == 1 ? "album" : "albums") to finish")
        }
        return parts.isEmpty ? "Nothing else to send" : parts.joined(separator: " · ")
    }

    private static func leftAlone(in review: DeviceTransferReview) -> [DeviceAlbumComparison] {
        review.albums.filter { $0.status == .differs && $0.isLeftAlone }
    }

    // MARK: - Text

    /// Mirrors what `DeviceTransferResolver` does for Replace: a different
    /// release takes the whole device copy's place; otherwise only the
    /// changed tracks are swapped and missing ones added; an album that only
    /// differs because its name is taken overwrites that file.
    private static func replaceEffect(of comparison: DeviceAlbumComparison) -> String {
        let real = comparison.differences.subtracting([.pathTaken])
        if real.contains(.differentRelease) {
            let removed = comparison.deviceTracks.count
            return "Replaces the whole album, \(tracks(removed)) removed"
        }
        if real.isEmpty {
            return "Overwrites the file already using that name"
        }
        let swapped = comparison.changed.count
        let held = comparison.deviceTracks.count
        var text = swapped == held && held > 1
            ? "Replaces all \(held) tracks"
            : "Replaces \(swapped) of \(tracks(held))"
        if !comparison.missing.isEmpty {
            text += ", adds \(comparison.missing.count)"
        }
        return text
    }

    private static func describe(_ tracks: [LoadedTrack], art: Int?, showsForm: Bool) -> String {
        var parts: [String] = []
        if showsForm, let form = formLabel(tracks) { parts.append(form) }
        parts.append(Self.tracks(tracks.count))
        parts.append(art.map { "art \($0) px" } ?? "no art")
        return parts.joined(separator: " · ")
    }

    private static func tracks(_ count: Int) -> String {
        "\(count) \(count == 1 ? "track" : "tracks")"
    }

    /// One label for the album's audio form, "Mixed formats" when its tracks
    /// disagree, nil when no track says what it is.
    private static func formLabel(_ tracks: [LoadedTrack]) -> String? {
        let labels = tracks.compactMap { formLabel($0.track) }
        guard let first = labels.first else { return nil }
        return labels.allSatisfy { $0 == first } ? first : "Mixed formats"
    }

    /// "MP3 128k", "FLAC 44.1 kHz", "WAV 16/44.1". Lossy formats show the
    /// sample rate only when it is not the usual 44.1 kHz. Only PCM names
    /// its bit depth (`pcm_s16le`), so only PCM shows one.
    static func formLabel(_ track: AudioTrack) -> String? {
        guard let raw = track.formatName?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let name = raw.lowercased()
        let rate = track.sampleRateHz.flatMap { $0 > 0 ? kilohertz($0) : nil }

        if name.hasPrefix("pcm_") {
            let container = name.hasSuffix("be") ? "AIFF" : "WAV"
            let depth = Int(name.dropFirst("pcm_".count).filter(\.isNumber))
            switch (depth, rate) {
            case let (depth?, rate?): return "\(container) \(depth)/\(rate)"
            case let (nil, rate?): return "\(container) \(rate) kHz"
            case let (depth?, nil): return "\(container) \(depth)-bit"
            case (nil, nil): return container
            }
        }

        let codec = raw.uppercased()
        if VersionLabel.isLossless(name) {
            return rate.map { "\(codec) \($0) kHz" } ?? codec
        }
        var label = codec
        if let kbps = track.bitrateKbps, kbps > 0 { label += " \(kbps)k" }
        if let hz = track.sampleRateHz, hz > 0, hz != 44_100, let rate { label += " \(rate) kHz" }
        return label
    }

    /// 44100 → "44.1", 48000 → "48".
    private static func kilohertz(_ hz: Int) -> String {
        let khz = Double(hz) / 1000
        return khz == khz.rounded() ? String(Int(khz)) : String(format: "%.1f", khz)
    }
}

/// The sheet's decidable state: the answer chosen for each row so far.
/// Nothing is pre-selected, except a row the user left alone before, which
/// starts on its recorded answer once shown.
public struct DeviceReviewState: Sendable, Equatable {
    public var decisions: [DeviceAlbumIdentity: DeviceAlbumDecision]

    public init(decisions: [DeviceAlbumIdentity: DeviceAlbumDecision] = [:]) {
        self.decisions = decisions
    }

    /// Every row shown has an answer.
    public func canConfirm(rows: [DeviceReviewRow]) -> Bool {
        rows.allSatisfy { decisions[$0.id] != nil }
    }

    /// "Set all to…": one answer for every row shown.
    public mutating func setAll(_ decision: DeviceAlbumDecision, rows: [DeviceReviewRow]) {
        for row in rows { decisions[row.id] = decision }
    }

    /// Rows left alone before start on Leave it when they come into view,
    /// unless the user already answered them.
    public mutating func presetLeftAlone(rows: [DeviceReviewRow]) {
        for row in rows where row.isLeftAlone && decisions[row.id] == nil {
            decisions[row.id] = .leave
        }
    }

    /// The answers for the rows shown. A row hidden again (the left-alone
    /// toggle turned off) keeps its remembered answer, not one picked while
    /// it was showing.
    public func result(rows: [DeviceReviewRow]) -> [DeviceAlbumIdentity: DeviceAlbumDecision] {
        var result: [DeviceAlbumIdentity: DeviceAlbumDecision] = [:]
        for row in rows {
            if let decision = decisions[row.id] { result[row.id] = decision }
        }
        return result
    }
}
