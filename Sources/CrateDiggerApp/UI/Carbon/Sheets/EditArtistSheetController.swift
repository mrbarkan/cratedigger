import AppKit
import CrateDiggerCore
import SwiftUI
import UniformTypeIdentifiers

/// The Edit Artist sheet (spec §4, Correcting a match, and §5): who the
/// artist is on MusicBrainz, every fact with the looked-up value as its
/// placeholder, and their photos.
///
/// The facts and the identity are a draft (`ArtistEditDraft`) that Save
/// writes in one store write; Cancel leaves the profile as it was. Photos are
/// files, so adding, removing and choosing the default act at once, through
/// the same view model calls as the page and the viewer, and the sheet shows
/// the profile as it now stands.
final class EditArtistSheetController: ThemedSheetHostingController {
    private let name: String
    private let model: LibraryViewModel
    private let maxBodyHeight: CGFloat

    init(name: String, model: LibraryViewModel, maxBodyHeight: CGFloat) {
        self.name = name
        self.model = model
        self.maxBodyHeight = maxBodyHeight
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        setThemedRoot(EditArtistSheetView(name: name, model: model, maxBodyHeight: maxBodyHeight) { [weak self] in
            self?.dismiss(nil)
        })
    }

    /// Presents the sheet for `name` on `host`'s window.
    @MainActor
    static func present(name: String, model: LibraryViewModel, from host: NSViewController) {
        let height = DeviceReviewSheetController.maxListHeight(for: host.view.window)
        host.presentAsSheet(EditArtistSheetController(name: name, model: model, maxBodyHeight: height))
    }
}

// MARK: - SwiftUI body

private struct EditArtistSheetView: View {
    @Environment(\.carbon) private var theme
    let name: String
    @ObservedObject var model: LibraryViewModel
    let maxBodyHeight: CGFloat
    let onClose: () -> Void

    @State private var draft: ArtistEditDraft
    private let original: ArtistEditDraft
    @State private var genresText: String
    @State private var membersText: String
    @State private var linksText: String
    @State private var pasteText = ""
    @State private var photoDropTargeted = false

    private static let sheetWidth: CGFloat = 640
    private static let keyWidth: CGFloat = 92
    private static let kinds = ["Person", "Group", "Orchestra", "Choir", "Character", "Other"]

    init(name: String, model: LibraryViewModel, maxBodyHeight: CGFloat, onClose: @escaping () -> Void) {
        self.name = name
        self.model = model
        self.maxBodyHeight = maxBodyHeight
        self.onClose = onClose
        let profile = model.artistProfile(named: name)
            ?? ArtistProfile(foldedKey: PodBoxArtName.folded(name), displayName: name)
        let draft = ArtistEditDraft(profile: profile)
        original = draft
        _draft = State(initialValue: draft)
        _genresText = State(initialValue: draft.owner.genres.map(ArtistEditDraft.genresText) ?? "")
        _membersText = State(initialValue: draft.owner.members.map(ArtistEditDraft.membersText) ?? "")
        _linksText = State(initialValue: draft.owner.links.map(ArtistEditDraft.linksText) ?? "")
    }

    private var profile: ArtistProfile? { model.artistProfile(named: name) }
    private var fetched: ArtistFacts { draft.fetched }
    private var canSave: Bool { draft != original && draft.pasteIsReadable }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 14)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    identitySection
                    photosSection
                    factsSection
                }
                .padding(.trailing, 6)
                .padding(.bottom, 4)
            }
            .frame(maxHeight: maxBodyHeight)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
                .padding(.vertical, 14)
            actionBar
        }
        .padding(20)
        .frame(width: Self.sheetWidth)
        .background(theme.chassis)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Edit Artist")
                .font(CarbonFont.sans(22, weight: .bold))
                .foregroundStyle(theme.ink)
            Text("What you type here is kept over anything CrateDigger looks up for \(name). "
                 + "A grey value is the looked-up one, and is used until you type your own.")
                .font(CarbonFont.sans(12.5))
                .foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Who they are

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("On MusicBrainz")
            Text(identityLine)
                .font(CarbonFont.mono(11))
                .foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Paste a MusicBrainz artist link or id", text: Binding(
                    get: { pasteText },
                    set: { pasteText = $0; draft.pastedMusicBrainz = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(CarbonFont.mono(11.5))
                if draft.confirmedMusicBrainzID != nil {
                    Button(draft.rejectsIdentity ? "Keep This Artist" : "Not This Artist") {
                        draft.rejectsIdentity.toggle()
                    }
                    .help("This MusicBrainz artist is someone else: forget their facts and photos, and look again")
                }
            }
            if !draft.pasteIsReadable {
                note("That is not a link to a MusicBrainz artist, or an artist id.", lit: true)
            } else if let id = draft.pastedMusicBrainzID, id != draft.confirmedMusicBrainzID {
                note("Save makes \(id) this artist, and looks up their facts.", lit: true)
            } else if draft.rejectsIdentity {
                note("Save forgets this match and its facts, then looks \(name) up again.", lit: true)
            }
            if case .uncertain(let candidates)? = profile?.identity, !candidates.isEmpty,
               draft.pastedMusicBrainzID == nil {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(candidates, id: \.musicBrainzID) { candidate in
                        candidateRow(candidate)
                    }
                }
            }
        }
    }

    private var identityLine: String {
        switch profile?.identity ?? .unknown {
        case .confirmed(let id, _): return "Matched to artist \(id)."
        case .uncertain(let candidates): return "Not sure which of \(candidates.count) artists this is. Pick one, or paste a link."
        case .notFound: return "Not found. Paste a link to their MusicBrainz page if they are there."
        case .rejected: return "None of the matches was right. Paste a link to their MusicBrainz page."
        case .unknown: return "Not looked up yet."
        }
    }

    private func candidateRow(_ candidate: ArtistIdentityCandidate) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text([candidate.name, candidate.disambiguation].compactMap { $0 }.joined(separator: " · "))
                    .font(CarbonFont.sans(12, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                let detail = ([candidate.origin].compactMap { $0 } + candidate.releaseTitles.prefix(3))
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · "))
                        .font(CarbonFont.sans(10.5))
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("This One") {
                pasteText = candidate.musicBrainzID
                draft.pastedMusicBrainz = candidate.musicBrainzID
            }
            .controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    // MARK: Facts

    private var factsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Facts")
            row("Kind", path: \ArtistFacts.kind) { kindPicker }
            row("Origin", path: \ArtistFacts.origin) {
                textField(\.origin, lookedUp: fetched.origin)
            }
            row("Began", path: \ArtistFacts.begin) {
                textField(\.begin, lookedUp: fetched.begin)
            }
            row("Ended", path: \ArtistFacts.end) {
                textField(\.end, lookedUp: fetched.end ?? (fetched.begin != nil ? "Still going" : nil))
            }
            row("Genres", path: \ArtistFacts.genres, reset: { genresText = "" }) {
                TextField(listPlaceholder(draft.owner.genres, lookedUp: fetched.genres.map(ArtistEditDraft.genresText)),
                          text: Binding(get: { genresText },
                                        set: { genresText = $0; draft.owner.genres = ArtistEditDraft.genres(fromText: $0) }))
                    .textFieldStyle(.roundedBorder)
                    .font(CarbonFont.mono(11.5))
            }
            row("Bio", path: \ArtistFacts.bio) {
                textEditor(Binding(get: { draft.owner.bio ?? "" },
                                   set: { if $0 != (draft.owner.bio ?? "") { draft.owner.bio = $0 } }),
                           placeholder: placeholder(draft.owner.bio, lookedUp: fetched.bio), height: 96)
            }
            row("Members", path: \ArtistFacts.members, reset: { membersText = "" }) {
                textEditor(Binding(get: { membersText },
                                   set: { membersText = $0; draft.owner.members = ArtistEditDraft.members(fromText: $0) }),
                           placeholder: listPlaceholder(draft.owner.members,
                                                        lookedUp: fetched.members.map(ArtistEditDraft.membersText))
                               + (draft.owner.members == nil && fetched.members == nil
                                  ? "\nOne a line: Name (1991 to now)" : ""),
                           height: 76)
            }
            row("Links", path: \ArtistFacts.links, reset: { linksText = "" }) {
                textEditor(Binding(get: { linksText },
                                   set: { linksText = $0; draft.owner.links = ArtistEditDraft.links(fromText: $0) }),
                           placeholder: listPlaceholder(draft.owner.links,
                                                        lookedUp: fetched.links.map(ArtistEditDraft.linksText)),
                           height: 52)
            }
        }
    }

    private var kindPicker: some View {
        Picker("", selection: Binding(get: { draft.owner.kind }, set: { draft.owner.kind = $0 })) {
            Text(lookedUpKindLabel).tag(String?.none)
            Divider()
            ForEach(Self.kinds, id: \.self) { kind in
                Text(ArtistPageText.kind(kind) ?? kind).tag(String?.some(kind))
            }
            if let custom = draft.owner.kind, !custom.isEmpty, !Self.kinds.contains(custom) {
                Text(custom).tag(String?.some(custom))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 220, alignment: .leading)
    }

    private var lookedUpKindLabel: String {
        guard let kind = ArtistPageText.kind(fetched.kind) else { return "Not known" }
        return "\(kind) (looked up)"
    }

    /// One labelled field, with "Use the looked-up value" while the owner
    /// has a value of their own there.
    private func row<Field: View>(_ label: String, path: PartialKeyPath<ArtistFacts>, reset: (() -> Void)? = nil,
                                  @ViewBuilder field: () -> Field) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.uppercased())
                .font(CarbonFont.mono(9, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(theme.ink3)
                .frame(width: Self.keyWidth, alignment: .leading)
            field()
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                draft.useLookedUp(path)
                reset?()
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(theme.ink3)
            }
            .buttonStyle(.plain)
            .help("Use the looked-up value")
            .opacity(ownerHasValue(path) ? 1 : 0)
            .disabled(!ownerHasValue(path))
            .accessibilityLabel("Use the looked-up \(label.lowercased())")
        }
    }

    private func ownerHasValue(_ path: PartialKeyPath<ArtistFacts>) -> Bool {
        // Every field is optional: nil is "use the looked-up value".
        let mirror = Mirror(reflecting: draft.owner[keyPath: path])
        return mirror.displayStyle != .optional || !mirror.children.isEmpty
    }

    private func textField(_ path: WritableKeyPath<ArtistFacts, String?>, lookedUp: String?) -> some View {
        TextField(placeholder(draft.owner[keyPath: path], lookedUp: lookedUp), text: Binding(
            get: { draft.owner[keyPath: path] ?? "" },
            set: { if $0 != (draft.owner[keyPath: path] ?? "") { draft.owner[keyPath: path] = $0 } }))
            .textFieldStyle(.roundedBorder)
            .font(CarbonFont.mono(11.5))
    }

    /// The looked-up value as the placeholder; "Left empty" when the owner
    /// cleared the field, which is what the page then shows.
    private func placeholder(_ owner: String?, lookedUp: String?) -> String {
        if owner?.isEmpty == true { return "Left empty" }
        return lookedUp?.isEmpty == false ? lookedUp! : "Not known"
    }

    private func listPlaceholder<T>(_ owner: [T]?, lookedUp: String?) -> String {
        if owner?.isEmpty == true { return "Left empty" }
        return lookedUp?.isEmpty == false ? lookedUp! : "Not known"
    }

    private func textEditor(_ text: Binding<String>, placeholder: String, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(CarbonFont.sans(12))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 3)
            .padding(.vertical, 4)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(theme.hair, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(CarbonFont.sans(12))
                        .foregroundStyle(theme.ink4)
                        .lineLimit(Int(height / 16))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: Photos

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Photos")
                Spacer()
                Toggle("No photo", isOn: Binding(get: { profile?.noPhoto ?? false },
                                                 set: { model.setArtistNoPhoto(name, $0) }))
                    .toggleStyle(.checkbox)
                    .font(CarbonFont.sans(11.5))
                    .help("Show the initials instead, here and on the iPod")
                Button("Add Photos…") { model.chooseArtistPhotos(name) }
                    .controlSize(.small)
            }
            let photos = profile?.photos ?? []
            if photos.isEmpty {
                Text("No photos yet. Add your own, or drop pictures here.")
                    .font(CarbonFont.mono(10.5))
                    .foregroundStyle(theme.ink3)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 110), spacing: 10, alignment: .top)],
                          alignment: .leading, spacing: 10) {
                    ForEach(photos, id: \.hash) { photo in
                        EditArtistPhotoTile(name: name, photo: photo, model: model,
                                            isDefault: profile?.defaultPhoto == photo.hash)
                    }
                }
                note("Click a photo to make it the default: the one the page shows and the iPod gets.", lit: false)
            }
            let found = profile?.photoCandidates ?? []
            if !found.isEmpty {
                sectionHeader("Found by the lookup")
                    .padding(.top, 4)
                HStack(spacing: 8) {
                    ForEach(found.prefix(8), id: \.self) { candidate in
                        EditArtistCandidateTile(name: name, candidate: candidate, model: model)
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.orange, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .opacity(photoDropTargeted ? 1 : 0)
        )
        .padding(-8)
        .onDrop(of: [.fileURL], isTargeted: $photoDropTargeted) { providers in
            ArtistPhotoDrop.load(providers) { model.addArtistPhotos(name, urls: $0) }
        }
    }

    // MARK: Buttons

    private var actionBar: some View {
        HStack(spacing: 12) {
            Text(draft == original ? "Photos are saved as you change them." : "Your changes are saved when you press Save.")
                .font(CarbonFont.mono(10.5))
                .foregroundStyle(theme.ink3)
            Spacer(minLength: 12)
            Button("Cancel") { onClose() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                model.saveArtistEdit(name, draft: draft)
                onClose()
            }
            .keyboardShortcut(.defaultAction)
            .tint(theme.orange)
            .disabled(!canSave)
        }
    }

    // MARK: Pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(CarbonFont.mono(9, weight: .bold))
            .tracking(1.8)
            .foregroundStyle(theme.ink3)
    }

    private func note(_ text: String, lit: Bool) -> some View {
        Text(text)
            .font(CarbonFont.mono(10))
            .foregroundStyle(lit ? theme.orange : theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One of the artist's photos: click makes it the default, which carries a
/// mark; the corner key removes it.
private struct EditArtistPhotoTile: View {
    @Environment(\.carbon) private var theme
    let name: String
    let photo: ArtistPhoto
    @ObservedObject var model: LibraryViewModel
    let isDefault: Bool

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Button { model.setDefaultArtistPhoto(name, hash: photo.hash) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.well)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "person.crop.square")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(theme.ink4)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isDefault ? theme.orange : theme.hair.opacity(0.6), lineWidth: isDefault ? 2 : 1)
            )
            .overlay(alignment: .bottomLeading) {
                if isDefault { ArtistDefaultMark().padding(5) }
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button { model.removeArtistPhoto(name, hash: photo.hash) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(4)
            .opacity(hovering ? 1 : 0)
            .help("Remove this photo")
        }
        .onHover { hovering = $0 }
        .animation(CarbonMotion.hover, value: hovering)
        .help(isDefault ? "The default photo" : "Make this the default photo")
        .contextMenu {
            Button("Make Default") { model.setDefaultArtistPhoto(name, hash: photo.hash) }
                .disabled(isDefault)
            Button("Remove") { model.removeArtistPhoto(name, hash: photo.hash) }
        }
        .task(id: photo.hash) { image = await model.artistPhotoThumbnail(hash: photo.hash, maxPixel: 240) }
        .accessibilityLabel(isDefault ? "Default photo of \(name)" : "Photo of \(name)")
    }
}

/// A photo the lookup found and did not download: its thumbnail fetched on
/// demand; a click downloads it into the artist's photos.
private struct EditArtistCandidateTile: View {
    @Environment(\.carbon) private var theme
    let name: String
    let candidate: ArtistPictureRecord.HeldCandidate
    @ObservedObject var model: LibraryViewModel

    @State private var image: NSImage?

    var body: some View {
        Button { model.addArtistPhotoCandidate(name, candidate) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.well)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").foregroundStyle(theme.ink4)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, theme.orange)
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
        .help("Add this photo, from \(ArtistPhotoCredit.sourceName(candidate.source))"
              + (candidate.credit.map { ": " + ArtistPhotoCredit.line($0) } ?? ""))
        .task(id: candidate.imageURL) { image = await model.artistCandidateThumbnail(candidate.imageURL) }
    }
}

/// The small mark on the default photo, in the sheet and the viewer.
struct ArtistDefaultMark: View {
    @Environment(\.carbon) private var theme

    var body: some View {
        Text("DEFAULT")
            .font(CarbonFont.mono(7.5, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.orange))
    }
}

/// Where a photo came from and its credit, in words.
enum ArtistPhotoCredit {
    static func sourceName(_ source: ArtistPictureSourceID) -> String {
        switch source {
        case .userFile: return "your file"
        case .libraryFolder: return "your library"
        case .deezer: return "Deezer"
        case .commons: return "Wikimedia Commons"
        case .fanartTV: return "fanart.tv"
        case .discogs: return "Discogs"
        case .theAudioDB: return "TheAudioDB"
        }
    }

    static func sourceName(_ source: ArtistPhoto.Source) -> String {
        switch source {
        case .owner: return "your file"
        case .library: return "your library"
        case .deezer: return "Deezer"
        case .commons: return "Wikimedia Commons"
        case .migrated: return "the iPod pictures"
        }
    }

    static func line(_ credit: ArtistPictureCredit) -> String {
        [credit.fileName, credit.licence, credit.author.map { "by \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Image files dropped on the portrait, the sheet or the viewer.
enum ArtistPhotoDrop {
    /// Loads the dropped file URLs, then hands them over on the main queue.
    static func load(_ providers: [NSItemProvider], _ completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !providers.isEmpty else { return false }
        var urls: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let dropped = urls
            Task { @MainActor in completion(dropped) }
        }
        return true
    }
}
