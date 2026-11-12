import Foundation

/// What the Edit Artist sheet edits (spec §4, Correcting a match, and §5):
/// the owner's facts, with the looked-up ones as placeholders, and who the
/// artist is. Nothing here reaches a profile until `apply`, which the sheet's
/// Save runs once, inside one `ArtistProfileStore.update`.
///
/// The owner's facts follow `ArtistProfile.facts`: nil is "not set, show the
/// looked-up value", an empty string or list is "the owner cleared it".
/// Changing the identity (a pasted MusicBrainz link or id, a picked
/// candidate, Not This Artist) goes through `ArtistProfile.confirmIdentity`
/// and `rejectConfirmedIdentity`, so the old identity's fetched facts and
/// fetched photos go and the owner's data stays, exactly as from the page.
public struct ArtistEditDraft: Equatable, Sendable {
    /// The looked-up facts when the sheet opened: the placeholders.
    public let fetched: ArtistFacts
    /// What the sheet edits.
    public var owner: ArtistFacts
    /// A MusicBrainz artist link or bare id the owner pasted (or a candidate
    /// they picked). nil or blank: no change.
    public var pastedMusicBrainz: String?
    /// Not This Artist: the confirmed id is rejected on Save.
    public var rejectsIdentity = false
    /// The confirmed MusicBrainz id when the sheet opened, if there was one.
    public let confirmedMusicBrainzID: String?

    public init(profile: ArtistProfile) {
        fetched = profile.fetched ?? ArtistFacts()
        owner = profile.owner ?? ArtistFacts()
        if case .confirmed(let id, _) = profile.identity { confirmedMusicBrainzID = id } else { confirmedMusicBrainzID = nil }
    }

    /// "Use the looked-up value": the owner's value for `field` goes, so the
    /// page shows the looked-up one again. A path that is not one of the
    /// facts' fields changes nothing.
    public mutating func useLookedUp(_ field: PartialKeyPath<ArtistFacts>) {
        if let path = field as? WritableKeyPath<ArtistFacts, String?> {
            owner[keyPath: path] = nil
            if path == \ArtistFacts.bio { owner.bioSourceURL = nil }
        } else if let path = field as? WritableKeyPath<ArtistFacts, [ArtistMember]?> {
            owner[keyPath: path] = nil
        } else if let path = field as? WritableKeyPath<ArtistFacts, [String]?> {
            owner[keyPath: path] = nil
        } else if let path = field as? WritableKeyPath<ArtistFacts, [ArtistLink]?> {
            owner[keyPath: path] = nil
        }
    }

    /// False when something is pasted that is not a MusicBrainz artist link
    /// or id: the sheet says so and Save waits.
    public var pasteIsReadable: Bool {
        guard let text = pastedMusicBrainz, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        return Self.musicBrainzID(from: text) != nil
    }

    /// The id the paste names, when it names one.
    public var pastedMusicBrainzID: String? {
        pastedMusicBrainz.flatMap(Self.musicBrainzID(from:))
    }

    /// Whether Save would change who `profile`'s artist is, so the page
    /// looks them up again afterwards.
    public func changesIdentity(of profile: ArtistProfile) -> Bool {
        var copy = profile
        applyIdentity(to: &copy)
        return copy.identity != profile.identity
    }

    /// Writes the owner's facts into `profile` (trimmed; none left is no
    /// owner set at all) and then any identity change. Touches nothing
    /// else: not the fetched facts unless the identity changes, not the
    /// photos, the default, `noPhoto` or `notOnIPod`.
    public func apply(to profile: inout ArtistProfile) {
        let cleaned = Self.trimmed(owner)
        profile.owner = cleaned == ArtistFacts() ? nil : cleaned
        applyIdentity(to: &profile)
    }

    private func applyIdentity(to profile: inout ArtistProfile) {
        let before = profile.identity
        if rejectsIdentity { profile.rejectConfirmedIdentity() }
        if let id = pastedMusicBrainzID { profile.confirmIdentity(musicBrainzID: id) }
        // A new identity's facts are looked up by its id; none of the old one's stay.
        if profile.identity != before { profile.fetched = nil }
    }

    private static func trimmed(_ facts: ArtistFacts) -> ArtistFacts {
        func clean(_ text: String?) -> String? { text?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ArtistFacts(kind: clean(facts.kind), origin: clean(facts.origin), begin: clean(facts.begin),
                           end: clean(facts.end), bio: clean(facts.bio), bioSourceURL: nil,
                           members: facts.members, genres: facts.genres, links: facts.links)
    }

    // MARK: - MusicBrainz ids

    /// The MusicBrainz artist id in `text`, lowercase: a bare id, or an
    /// artist page link on musicbrainz.org (any subdomain, with or without
    /// the scheme, anything after the id). nil for anything else, including
    /// a release or recording link.
    public static func musicBrainzID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let id = bareID(trimmed) { return id }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              host == "musicbrainz.org" || host.hasSuffix(".musicbrainz.org") else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0].lowercased() == "artist" else { return nil }
        return bareID(parts[1])
    }

    private static func bareID(_ text: String) -> String? {
        guard text.count == 36, UUID(uuidString: text) != nil else { return nil }
        return text.lowercased()
    }

    // MARK: - List fields as text

    /// "trip hop, dub".
    public static func genresText(_ genres: [String]) -> String {
        genres.joined(separator: ", ")
    }

    /// Comma-separated, each trimmed, blanks dropped.
    public static func genres(fromText text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// One member a line: "Robert Del Naja (1988 to now)", "Andrew Vowles
    /// (1988 to 1999)", "Tricky (former)", "Someone (until 1995)", and a
    /// bare name for a current member with no years.
    public static func membersText(_ members: [ArtistMember]) -> String {
        members.map { member in
            let years: String?
            switch (member.isCurrent, nonBlank(member.begin), nonBlank(member.end)) {
            case (true, let begin?, _): years = "\(begin) to now"
            case (true, nil, _): years = nil
            case (false, let begin?, let end?): years = "\(begin) to \(end)"
            case (false, let begin?, nil): years = "\(begin), former"
            case (false, nil, let end?): years = "until \(end)"
            case (false, nil, nil): years = "former"
            }
            return years.map { "\(member.name) (\($0))" } ?? member.name
        }.joined(separator: "\n")
    }

    /// Reads `membersText`'s lines back; also "1988-2001" and "1988 – now".
    /// Parentheses that are not years stay in the name.
    public static func members(fromText text: String) -> [ArtistMember] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasSuffix(")"), let open = line.lastIndex(of: "(") {
                let name = line[..<open].trimmingCharacters(in: .whitespaces)
                let inner = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
                if !name.isEmpty, let member = member(name: name, years: inner) { return member }
            }
            return ArtistMember(name: line, isCurrent: true)
        }
    }

    private static let date = #"\d{3,4}(?:-\d{2}){0,2}"#
    private static let span = try! NSRegularExpression(
        pattern: "^(\(date))\\s*(?:\\s+to\\s+|[-–])\\s*(now|\(date))$", options: .caseInsensitive)
    private static let until = try! NSRegularExpression(pattern: "^until\\s+(\(date))$", options: .caseInsensitive)
    private static let formerSince = try! NSRegularExpression(pattern: "^(\(date)),\\s*former$", options: .caseInsensitive)

    private static func member(name: String, years raw: String) -> ArtistMember? {
        let years = raw.trimmingCharacters(in: .whitespaces)
        if years.caseInsensitiveCompare("former") == .orderedSame { return ArtistMember(name: name, isCurrent: false) }
        if let groups = match(span, years) {
            if groups[1].lowercased() == "now" { return ArtistMember(name: name, begin: groups[0], isCurrent: true) }
            return ArtistMember(name: name, begin: groups[0], end: groups[1], isCurrent: false)
        }
        if let groups = match(until, years) { return ArtistMember(name: name, end: groups[0], isCurrent: false) }
        if let groups = match(formerSince, years) { return ArtistMember(name: name, begin: groups[0], isCurrent: false) }
        return nil
    }

    private static func match(_ expression: NSRegularExpression, _ text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let result = expression.firstMatch(in: text, range: range) else { return nil }
        return (1..<result.numberOfRanges).compactMap { Range(result.range(at: $0), in: text).map { String(text[$0]) } }
    }

    /// One link a line.
    public static func linksText(_ links: [ArtistLink]) -> String {
        links.map(\.url.absoluteString).joined(separator: "\n")
    }

    /// One web address a line; a MusicBrainz or Wikipedia address is known
    /// as one. Anything that is not an http or https address is dropped.
    public static func links(fromText text: String) -> [ArtistLink] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: line), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http", let host = url.host?.lowercased(), !host.isEmpty
            else { return nil }
            let kind: ArtistLink.Kind
            if host == "musicbrainz.org" || host.hasSuffix(".musicbrainz.org") {
                kind = .musicBrainz
            } else if host == "wikipedia.org" || host.hasSuffix(".wikipedia.org") {
                kind = .wikipedia
            } else {
                kind = .other
            }
            return ArtistLink(kind: kind, url: url)
        }
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
