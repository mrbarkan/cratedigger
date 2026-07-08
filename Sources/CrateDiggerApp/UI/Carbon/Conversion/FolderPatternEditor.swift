import SwiftUI
import CrateDiggerCore

/// The freeform folder-pattern editor in the Convert patch bay. Each folder tag is
/// a draggable chip; the pill between two chips toggles `/` (new folder) ↔ `·`
/// (same folder, space-joined), so the user can shape any folder tree — e.g. put
/// Year and Album in one "1998 Album" folder. A `+` menu adds tags, hovering a chip
/// reveals `✕` to remove it, and the presets menu loads a starting layout.
///
/// It edits the bindings directly (no mirrored @State) so it can never drift from
/// the model. The underlying `tokenOrder` stays in the app's 5-slot `.disabled`-
/// padded shape so the older Picker sheet and device transfer keep working; the
/// editor just presents the enabled tags. Any edit forks the preset to `.custom`.
struct FolderPatternEditor: View {
    @Environment(\.carbon) private var theme
    @Binding var tokenOrder: [FolderToken]
    @Binding var separators: [FolderSeparator]
    @Binding var preset: TemplatePreset

    @State private var draggingToken: FolderToken?
    @State private var dragTranslation: CGSize = .zero
    @State private var chipCenters: [FolderToken: CGFloat] = [:]
    @State private var hovered: FolderToken?

    /// The folder tags a user can place, in menu order.
    private static let allTokens: [FolderToken] = [.albumArtist, .year, .album, .compilation, .genre]
    private static let rowSpace = "folderPatternRow"

    // MARK: - Effective (preset-aware) model

    private var effectiveTokens: [FolderToken] {
        preset == .custom ? tokenOrder : preset.defaultTokenOrder
    }
    private var effectiveSeparators: [FolderSeparator] {
        preset == .custom ? separators : []
    }
    /// The enabled tags in order — the chips shown.
    private var chips: [FolderToken] { effectiveTokens.filter { !$0.isDisabled } }
    /// Trailing separator per chip (defaults to `/` when unset).
    private var chipSeparators: [FolderSeparator] {
        (0..<chips.count).map { i in effectiveSeparators.indices.contains(i) ? effectiveSeparators[i] : .slash }
    }
    private var addable: [FolderToken] { Self.allTokens.filter { !chips.contains($0) } }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Chips + separators wrap to new lines if the row runs out of width,
            // so tags never get squeezed into vertical letter stacks.
            FlowLayout(spacing: 5, lineSpacing: 5) {
                ForEach(Array(chips.enumerated()), id: \.element) { index, token in
                    chipView(token)
                        .background(chipCenterReader(token))
                        .offset(draggingToken == token ? dragTranslation : .zero)
                        .zIndex(draggingToken == token ? 1 : 0)
                        .opacity(draggingToken == token ? 0.9 : 1)
                        .gesture(chipDrag(token))

                    if index < chips.count - 1 {
                        separatorPill(at: index)
                    }
                }

                if !addable.isEmpty { addMenu }
            }
            .coordinateSpace(name: Self.rowSpace)
            .onPreferenceChange(ChipCenterKey.self) { chipCenters = $0 }

            HStack(spacing: 8) {
                Text(previewPath())
                    .font(CarbonFont.mono(9, weight: .medium))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                presetMenu
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(theme.isDark ? Color.black.opacity(0.28) : Color.black.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Chip

    private func chipView(_ token: FolderToken) -> some View {
        Text(chipLabel(token))
            .font(CarbonFont.mono(10, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(theme.orange)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.isDark ? Color.white.opacity(0.07) : Color.white.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.14), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if hovered == token {
                    Button { remove(token) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.ink2, theme.isDark ? Color.black : Color.white)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .help("Remove \(token.title)")
                }
            }
            // The main window is movable-by-background; without this a click-drag on
            // a plain-Text chip moves the whole window instead of starting the drag.
            .background(WindowDragGuard())
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? token : (hovered == token ? nil : hovered) }
            .help("Drag to reorder")
    }

    /// Publishes each chip's horizontal center so a drop can be resolved to an
    /// insertion index without any fly-back animation.
    private func chipCenterReader(_ token: FolderToken) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ChipCenterKey.self,
                value: [token: geo.frame(in: .named(Self.rowSpace)).midX]
            )
        }
    }

    /// Direct drag-to-reorder: the chip follows the pointer, and on release it
    /// drops instantly into the slot nearest the drop point (no drag-and-drop
    /// fly-back). The tag carries its trailing separator so groupings survive.
    private func chipDrag(_ token: FolderToken) -> some Gesture {
        DragGesture(coordinateSpace: .named(Self.rowSpace))
            .onChanged { value in
                if draggingToken != token { draggingToken = token }
                dragTranslation = value.translation
            }
            .onEnded { value in
                let dropX = value.location.x
                let source = chips.firstIndex(of: token)
                var destination = 0
                for other in chips where other != token {
                    if let center = chipCenters[other], center < dropX { destination += 1 }
                }
                withAnimation(.easeInOut(duration: 0.16)) {
                    draggingToken = nil
                    dragTranslation = .zero
                    if let source, source != destination {
                        moveChip(from: source, to: destination)
                    }
                }
            }
    }

    private func chipLabel(_ token: FolderToken) -> String {
        switch token {
        case .albumArtist: return "ARTIST"
        case .year:        return "YEAR"
        case .album:       return "ALBUM"
        case .compilation: return "COMP"
        case .genre:       return "GENRE"
        case .disabled:    return ""
        }
    }

    // MARK: - Separator pill

    private func separatorPill(at index: Int) -> some View {
        let isSlash = chipSeparators[index] == .slash
        return Button { toggleSeparator(at: index) } label: {
            Text(isSlash ? "/" : "·")
                .font(CarbonFont.mono(11, weight: .bold))
                .foregroundStyle(isSlash ? theme.ink2 : theme.cyan)
                .frame(width: 16, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
        .help(isSlash ? "New folder — tap to keep in the same folder" : "Same folder — tap to split into a new folder")
    }

    // MARK: - Add / presets menus

    private var addMenu: some View {
        Menu {
            ForEach(addable, id: \.self) { token in
                Button(token.title) { add(token) }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.ink2)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a folder tag")
    }

    private var presetMenu: some View {
        Menu {
            ForEach([TemplatePreset.artistYearAlbum, .yearArtistAlbum, .artistAlbumYear], id: \.self) { preset in
                Button(preset.title) { apply(preset) }
            }
        } label: {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.ink3)
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Load a preset layout")
    }

    // MARK: - Live preview (mirrors OutputPathPlanner.buildOutputSubpath grouping)

    private func previewPath() -> String {
        let sample: [FolderToken: String] = [
            .albumArtist: "Artist", .year: "1998", .album: "Album",
            .compilation: "Compilation", .genre: "Genre",
        ]
        let tokens = chips
        let seps = chipSeparators
        var levels: [[String]] = [[]]
        for (i, token) in tokens.enumerated() {
            if let value = sample[token] { levels[levels.count - 1].append(value) }
            if i < tokens.count - 1, seps[i] == .slash { levels.append([]) }
        }
        let path = levels.map { $0.joined(separator: " ") }.filter { !$0.isEmpty }.joined(separator: "/")
        return path.isEmpty ? "—" : path
    }

    // MARK: - Mutations (all commit through the 5-slot model)

    /// `to` is the insertion index within the list *excluding* the moved tag,
    /// exactly what the drop math produces. The tag's trailing separator moves with
    /// it, so a grouping set up before the drag isn't scrambled by reordering.
    private func moveChip(from: Int, to: Int) {
        var tokens = chips
        var seps = chipSeparators
        guard tokens.indices.contains(from), seps.indices.contains(from) else { return }
        let movedToken = tokens.remove(at: from)
        let movedSeparator = seps.remove(at: from)
        let clamped = max(0, min(to, tokens.count))
        tokens.insert(movedToken, at: clamped)
        seps.insert(movedSeparator, at: clamped)
        commit(tokens: tokens, separators: seps)
    }

    private func toggleSeparator(at index: Int) {
        var seps = chipSeparators
        guard seps.indices.contains(index) else { return }
        seps[index] = seps[index] == .slash ? .space : .slash
        commit(tokens: chips, separators: seps)
    }

    private func add(_ token: FolderToken) {
        commit(tokens: chips + [token], separators: chipSeparators + [.slash])
    }

    private func remove(_ token: FolderToken) {
        var tokens = chips
        var seps = chipSeparators
        guard let index = tokens.firstIndex(of: token) else { return }
        tokens.remove(at: index)
        seps.remove(at: index)
        commit(tokens: tokens, separators: seps)
    }

    private func apply(_ newPreset: TemplatePreset) {
        preset = newPreset
        tokenOrder = FolderTokenOrder.normalize(newPreset.defaultTokenOrder)
        separators = []   // presets are always one-folder-per-tag
    }

    /// Write the enabled tags back into the 5-slot `.disabled`-padded shape the rest
    /// of the app expects, and fork to `.custom` so the edit sticks.
    private func commit(tokens: [FolderToken], separators newSeparators: [FolderSeparator]) {
        let slots = FolderTokenOrder.tokenCount
        var paddedTokens = Array(tokens.prefix(slots))
        var paddedSeparators = Array(newSeparators.prefix(slots))
        while paddedTokens.count < slots { paddedTokens.append(.disabled) }
        while paddedSeparators.count < slots { paddedSeparators.append(.slash) }

        preset = .custom
        tokenOrder = paddedTokens
        self.separators = paddedSeparators
    }
}

/// A minimal left-to-right flow layout: lays subviews in a row, wrapping to the
/// next line when the proposed width runs out. Used so pattern chips wrap instead
/// of being squeezed. (macOS 13+ `Layout`.)
private struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: maxWidth == .infinity ? width : min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty, projected > maxWidth {
                rows.append(current)
                current = Row(items: [index], width: size.width, height: size.height)
            } else {
                current.width = projected
                current.height = max(current.height, size.height)
                current.items.append(index)
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

/// Collects each chip's horizontal center (in the row's coordinate space) so a
/// release can be resolved to an insertion index.
private struct ChipCenterKey: PreferenceKey {
    static var defaultValue: [FolderToken: CGFloat] = [:]
    static func reduce(value: inout [FolderToken: CGFloat], nextValue: () -> [FolderToken: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
