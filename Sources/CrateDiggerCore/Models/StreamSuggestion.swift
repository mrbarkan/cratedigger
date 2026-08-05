import Foundation

/// A curated station you can add in one tap, so Radio isn't an empty box with a
/// URL field. These are long-running public YouTube live channels — the kind
/// that stay up for years — grouped the way the sidebar groups saved streams.
///
/// A dead entry is a cosmetic problem, not a functional one: adding it still
/// works, and the stream simply won't resolve. `StreamFailureAdvisor` explains
/// that case rather than blaming the app.
public struct StreamSuggestion: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let channel: String
    public let url: String
    public let kind: StreamKind
    public let category: RadioCategory
    /// One line on why you'd pick this one.
    public let blurb: String

    public init(
        id: String,
        title: String,
        channel: String,
        url: String,
        kind: StreamKind,
        category: RadioCategory,
        blurb: String
    ) {
        self.id = id
        self.title = title
        self.channel = channel
        self.url = url
        self.kind = kind
        self.category = category
        self.blurb = blurb
    }

    public static let catalog: [StreamSuggestion] = [
        StreamSuggestion(
            id: "suggest.lofigirl.beats",
            title: "lofi hip hop radio — beats to relax/study to",
            channel: "Lofi Girl",
            url: "https://www.youtube.com/watch?v=jfKfPfyJRdk",
            kind: .live, category: .youtubeLive,
            blurb: "The one that never goes down. Instrumental hip hop, 24/7."
        ),
        StreamSuggestion(
            id: "suggest.lofigirl.sleep",
            title: "sleep lofi radio — beats to fall asleep to",
            channel: "Lofi Girl",
            url: "https://www.youtube.com/watch?v=rUxyKA_-grg",
            kind: .live, category: .youtubeLive,
            blurb: "Slower and quieter than the main channel. Pairs with the sleep timer."
        ),
        StreamSuggestion(
            id: "suggest.chillhop",
            title: "Chillhop Radio — jazzy & lofi hip hop beats",
            channel: "Chillhop Music",
            url: "https://www.youtube.com/watch?v=5yx6BWlEVcY",
            kind: .live, category: .youtubeLive,
            blurb: "Jazzier than Lofi Girl, heavier on live instrumentation."
        ),
        StreamSuggestion(
            id: "suggest.nightride",
            title: "Nightride FM — synthwave",
            channel: "Nightride FM",
            url: "https://www.youtube.com/watch?v=Ola5bfAdCJI",
            kind: .live, category: .youtubeLive,
            blurb: "Synthwave and retrowave, continuous."
        ),
        StreamSuggestion(
            id: "suggest.deephouse",
            title: "Deep House Radio",
            channel: "The Good Life Radio",
            url: "https://www.youtube.com/watch?v=36YnV9STBqc",
            kind: .live, category: .youtubeLive,
            blurb: "Deep and tropical house, mixed continuously."
        ),
        StreamSuggestion(
            id: "suggest.classical",
            title: "Classical Music Radio",
            channel: "Halidon Music",
            url: "https://www.youtube.com/watch?v=jgpJVI3tDbY",
            kind: .live, category: .youtubeLive,
            blurb: "Orchestral and chamber repertoire, around the clock."
        ),
        StreamSuggestion(
            id: "suggest.jazz",
            title: "Relaxing Jazz Radio",
            channel: "Cafe Music BGM",
            url: "https://www.youtube.com/watch?v=Dx5qFachd3A",
            kind: .live, category: .youtubeLive,
            blurb: "Café jazz and bossa nova."
        ),
        StreamSuggestion(
            id: "suggest.ambient",
            title: "Ambient Space Music",
            channel: "Space Ambient",
            url: "https://www.youtube.com/watch?v=tNkZsRW7h2c",
            kind: .live, category: .youtubeLive,
            blurb: "Long-form ambient with no beat. Good behind work."
        ),
        StreamSuggestion(
            id: "suggest.nts",
            title: "NTS Radio",
            channel: "NTS Radio",
            url: "https://www.youtube.com/@NTSRadio",
            kind: .playlist, category: .youtubeRecords,
            blurb: "London station — shows and mixes across everything."
        ),
        StreamSuggestion(
            id: "suggest.boilerroom",
            title: "Boiler Room",
            channel: "Boiler Room",
            url: "https://www.youtube.com/@boilerroom",
            kind: .playlist, category: .youtubeRecords,
            blurb: "Club sets, recorded live. Long, and mostly beat-driven."
        ),
        StreamSuggestion(
            id: "suggest.colors",
            title: "COLORS",
            channel: "COLORS",
            url: "https://www.youtube.com/@COLORSxSTUDIOS",
            kind: .playlist, category: .youtubeRecords,
            blurb: "Single-take studio performances, one artist at a time."
        ),
        StreamSuggestion(
            id: "suggest.kexp",
            title: "KEXP Live Sessions",
            channel: "KEXP",
            url: "https://www.youtube.com/@kexp",
            kind: .playlist, category: .youtubeRecords,
            blurb: "Full band sessions from the Seattle station."
        )
    ]

    public static func catalog(for category: RadioCategory) -> [StreamSuggestion] {
        catalog.filter { $0.category == category }
    }
}
