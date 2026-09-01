import Foundation

/// The ID3v1 genre table, for tags that carry the number instead of the name.
///
/// Old rippers wrote "17"; ID3v2.3 allowed "(17)" and "(17)Rock". Every one of
/// those means Rock, and a Genre column that lists "17" between "Alternative"
/// and "Ambient" is not one anybody can browse. This maps the number and
/// leaves everything else exactly as tagged — it is not a normalizer.
public enum ID3Genre {

    /// The tag's genre as a name: the ID3v1 name for a bare or parenthesised
    /// number, the text after a "(n)" prefix if there is one, else the tag
    /// unchanged. An unknown number stays a number rather than guessing.
    public static func name(for tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("("), let close = trimmed.firstIndex(of: ")") {
            let code = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
            if let number = Int(code), let name = names[safe: number] { return name }
            return tag
        }
        if let number = Int(trimmed), let name = names[safe: number] { return name }
        return tag
    }

    /// 0–79 from the ID3v1 specification, 80–147 the Winamp extensions every
    /// tagger since has honoured.
    static let names: [String] = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop",
        "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap",
        "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks",
        "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance",
        "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock",
        "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream",
        "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
        "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi",
        "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
        "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebop", "Latin", "Revival",
        "Celtic", "Bluegrass", "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock",
        "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech", "Chanson", "Opera",
        "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam",
        "Club", "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle",
        "Duet", "Punk Rock", "Drum Solo", "A cappella", "Euro-House", "Dance Hall", "Goa", "Drum & Bass",
        "Club-House", "Hardcore", "Terror", "Indie", "BritPop", "Negerpunk", "Polsk Punk", "Beat",
        "Christian Gangsta Rap", "Heavy Metal", "Black Metal", "Crossover", "Contemporary Christian", "Christian Rock", "Merengue", "Salsa",
        "Thrash Metal", "Anime", "JPop", "Synthpop",
    ]
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
