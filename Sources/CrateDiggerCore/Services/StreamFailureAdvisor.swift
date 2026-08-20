import Foundation

/// Turns a raw stream failure into something the user can act on.
///
/// yt-dlp fails in a handful of recognisable ways, and they call for different
/// responses: a broken YouTube extractor needs an update, a private video needs
/// a different source, a rate-limit needs a wait. Reporting "stream failed" for
/// all of them sends people to reinstall things that were never broken, so the
/// message is matched to the cause.
public enum StreamFailureAdvisor {

    /// What the app should offer to *do*, alongside the explanation.
    public enum Remedy: Equatable, Sendable {
        /// Run the yt-dlp update (brew upgrade / `-U`).
        case updateYtDlp
        /// yt-dlp isn't installed at all.
        case installYtDlp
        /// Nothing mechanical to fix — the source itself is the problem.
        case tryAnotherSource
        /// Transient; the same URL should work later.
        case waitAndRetry
        /// The saved URL isn't a stream we can resolve.
        case fixURL
        /// Fall back to the embedded WebView player, which needs no yt-dlp.
        case useWebViewEngine
    }

    public struct Diagnosis: Equatable, Sendable {
        /// One line naming the cause, in the user's terms.
        public let summary: String
        /// What to do about it, most likely to help first.
        public let remedies: [Remedy]
        /// The raw yt-dlp line, kept for the details view.
        public let detail: String?

        public init(summary: String, remedies: [Remedy], detail: String? = nil) {
            self.summary = summary
            self.remedies = remedies
            self.detail = detail
        }

        public var primaryRemedy: Remedy? { remedies.first }
    }

    /// Classify a failure. `detail` is yt-dlp's stderr (or a resolver error);
    /// `ytdlpInstalled` distinguishes "broken" from "absent".
    public static func diagnose(detail: String?, ytdlpInstalled: Bool) -> Diagnosis {
        guard ytdlpInstalled else {
            return Diagnosis(
                summary: "yt-dlp isn’t installed. It’s what turns a YouTube link into playable audio.",
                remedies: [.installYtDlp, .useWebViewEngine],
                detail: detail
            )
        }

        let haystack = (detail ?? "").lowercased()
        func mentions(_ needles: [String]) -> Bool {
            needles.contains { haystack.contains($0) }
        }

        // Order matters: the most specific causes are checked first, because
        // several of these strings co-occur in one stderr dump.
        if mentions(["sign in to confirm you’re not a bot", "sign in to confirm you're not a bot",
                     "confirm you are not a bot"]) {
            return Diagnosis(
                summary: "YouTube is challenging this request as automated traffic. A newer yt-dlp usually gets past it.",
                remedies: [.updateYtDlp, .waitAndRetry, .useWebViewEngine],
                detail: detail
            )
        }
        if mentions(["age-restricted", "age restricted", "confirm your age", "inappropriate for some users"]) {
            return Diagnosis(
                summary: "This video is age-restricted, so YouTube won’t serve it without a signed-in session.",
                remedies: [.tryAnotherSource, .useWebViewEngine],
                detail: detail
            )
        }
        if mentions(["private video", "video unavailable", "removed by the uploader",
                     "account associated with this video has been terminated",
                     "this live event has ended", "video has been removed"]) {
            return Diagnosis(
                summary: "The video is gone or private — the stream itself is the problem, not CrateDigger.",
                remedies: [.tryAnotherSource],
                detail: detail
            )
        }
        if mentions(["nsig extraction failed", "unable to extract", "signature extraction failed",
                     "player response", "failed to extract any player response",
                     // yt-dlp's stderr says "HTTP Error 403"; ChunkedStreamLoader
                     // reports the status it saw as "HTTP 403".
                     "http error 403", "http 403"]) {
            return Diagnosis(
                summary: "yt-dlp can’t read YouTube’s player right now — this is what a YouTube-side change looks like, and an update almost always fixes it.",
                remedies: [.updateYtDlp, .useWebViewEngine],
                detail: detail
            )
        }
        if mentions(["http error 429", "too many requests", "rate limit"]) {
            return Diagnosis(
                summary: "YouTube is rate-limiting this machine. It clears on its own — try again in a few minutes.",
                remedies: [.waitAndRetry, .useWebViewEngine],
                detail: detail
            )
        }
        if mentions(["is not a valid url", "unsupported url", "unable to download webpage: http error 404"]) {
            return Diagnosis(
                summary: "That link isn’t a stream yt-dlp can open.",
                remedies: [.fixURL, .tryAnotherSource],
                detail: detail
            )
        }
        if mentions(["temporary failure in name resolution", "network is unreachable", "connection refused",
                     "timed out", "could not resolve host", "no address associated"]) {
            return Diagnosis(
                summary: "Couldn’t reach YouTube. Check the network connection.",
                remedies: [.waitAndRetry],
                detail: detail
            )
        }

        return Diagnosis(
            summary: "The stream wouldn’t start. An outdated yt-dlp is the usual cause.",
            remedies: [.updateYtDlp, .tryAnotherSource, .useWebViewEngine],
            detail: detail
        )
    }

    /// Diagnose a doctor verdict. `.working` means the pipeline is healthy and
    /// whatever failed is specific to that one stream.
    public static func diagnose(_ verdict: StreamEngineDoctor.Verdict) -> Diagnosis? {
        switch verdict {
        case .working:
            return nil
        case .broken(_, let detail):
            return diagnose(detail: detail, ytdlpInstalled: true)
        }
    }
}

public extension StreamFailureAdvisor.Remedy {
    /// Button title for this remedy.
    var actionTitle: String {
        switch self {
        case .updateYtDlp:      return "Update yt-dlp"
        case .installYtDlp:     return "Install yt-dlp"
        case .tryAnotherSource: return "Browse Suggested Stations"
        case .waitAndRetry:     return "Try Again"
        case .fixURL:           return "Edit URL"
        case .useWebViewEngine: return "Switch to WebView Player"
        }
    }
}
