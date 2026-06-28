import AppKit
import CrateDiggerCore
import SwiftUI

/// Confirm/edit sheet for an album version group: set the release name, the
/// original release year (used for sorting), pick the primary pressing, and edit
/// each pressing's edition label. Pre-filled so it's usually glance-and-confirm.
///
/// Presented via `MainWindowController.presentGroupAlbumsSheet()` which is
/// triggered by a `NSNotification.Name.crateDiggerPresentGroupAlbumsSheet` post.
final class GroupAlbumsSheetController: NSViewController {

    struct VersionRow {
        let album: Album
        let key: AlbumFolderKey
        let formatBadge: String
        var editionLabel: String
    }

    struct Result {
        let name: String
        let originalYear: Int?
        let primaryKey: AlbumFolderKey
        let members: [VersionMember]
    }

    var onDecision: ((Result?) -> Void)?

    private var rows: [VersionRow]
    private var primaryKey: AlbumFolderKey
    private let initialName: String
    private let initialYear: String
    private var hostingController: NSViewController?

    init(name: String, originalYear: Int?, rows: [VersionRow], primaryKey: AlbumFolderKey) {
        self.rows = rows
        self.primaryKey = primaryKey
        self.initialName = name
        self.initialYear = originalYear.map(String.init) ?? ""
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let rootView = GroupAlbumsSheetView(
            initialName: initialName,
            initialYear: initialYear,
            rows: rows,
            initialPrimaryKey: primaryKey
        ) { [weak self] result in
            self?.onDecision?(result)
        }

        let themed = ThemedSheetWrapper { rootView }
        let hc = NSHostingController(rootView: themed)
        self.hostingController = hc
        addChild(hc)
        view = hc.view
    }
}

// MARK: - SwiftUI body

private struct GroupAlbumsSheetView: View {
    @Environment(\.carbon) private var theme

    let onDecision: (GroupAlbumsSheetController.Result?) -> Void

    @State private var name: String
    @State private var yearText: String
    @State private var primaryKey: AlbumFolderKey
    @State private var editionLabels: [String]

    private let rows: [GroupAlbumsSheetController.VersionRow]

    init(
        initialName: String,
        initialYear: String,
        rows: [GroupAlbumsSheetController.VersionRow],
        initialPrimaryKey: AlbumFolderKey,
        onDecision: @escaping (GroupAlbumsSheetController.Result?) -> Void
    ) {
        self.rows = rows
        self.onDecision = onDecision
        _name = State(initialValue: initialName)
        _yearText = State(initialValue: initialYear)
        _primaryKey = State(initialValue: initialPrimaryKey)
        _editionLabels = State(initialValue: rows.map(\.editionLabel))
    }

    private var canConfirm: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 16)

            nameRow
                .padding(.bottom, 12)

            yearRow
                .padding(.bottom, 16)

            Divider()
                .padding(.bottom, 16)

            versionsSection
                .padding(.bottom, 16)

            Divider()
                .padding(.bottom, 16)

            primaryRow
                .padding(.bottom, 20)

            actionBar
        }
        .padding(20)
        .frame(minWidth: 500)
        .background(theme.chassis)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(theme.orange)
                .frame(width: 7, height: 7)
            Text("GROUP ALBUM VERSIONS")
                .font(CarbonFont.mono(11, weight: .bold))
                .tracking(2)
                .foregroundStyle(theme.ink)
            Spacer()
        }
    }

    // MARK: Name

    private var nameRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RELEASE NAME")
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(theme.ink3)
            TextField("Album title…", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(CarbonFont.mono(12))
        }
    }

    // MARK: Year

    private var yearRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ORIGINAL YEAR")
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(theme.ink3)
            TextField("e.g. 1975", text: $yearText)
                .textFieldStyle(.roundedBorder)
                .font(CarbonFont.mono(12))
                .frame(maxWidth: 120)
        }
    }

    // MARK: Versions table

    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VERSION")
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(theme.ink3)
                    .frame(width: 200, alignment: .leading)
                Text("EDITION LABEL")
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(theme.ink3)
            }

            ForEach(rows.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 10) {
                    versionIdentity(rows[i])
                        .frame(width: 200, alignment: .leading)

                    TextField("Edition label (optional)…", text: $editionLabels[i])
                        .textFieldStyle(.roundedBorder)
                        .font(CarbonFont.mono(11))
                }
            }
        }
    }

    /// The left-hand cell identifying a pressing: title + its year (the fields that
    /// make it a distinct version) over the format badge + source folder, so two
    /// same-format rips are still tellable apart.
    private func versionIdentity(_ row: GroupAlbumsSheetController.VersionRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.album.title)
                .font(CarbonFont.mono(11, weight: .medium))
                .foregroundStyle(theme.ink)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(row.formatBadge)
                    .font(CarbonFont.mono(9, weight: .medium))
                    .foregroundStyle(theme.cyan)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(theme.cyan.opacity(0.12))
                    )
                    .lineLimit(1)
                if let year = row.album.year {
                    Text(String(year))
                        .font(CarbonFont.mono(9))
                        .foregroundStyle(theme.ink3)
                }
            }
        }
    }

    /// Title plus year — the per-pressing identity used as the Primary picker label
    /// when no edition label is set (always distinct between two grouped versions,
    /// since identical artist/title/year would be one album).
    private func identityTitle(_ album: Album) -> String {
        if let year = album.year { return "\(album.title) · \(year)" }
        return album.title
    }

    // MARK: Primary picker

    private var primaryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PRIMARY VERSION")
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(theme.ink3)

            Picker("Primary", selection: $primaryKey) {
                ForEach(rows.indices, id: \.self) { i in
                    let row = rows[i]
                    let label = editionLabels[i].isEmpty ? identityTitle(row.album) : editionLabels[i]
                    Text(label).tag(row.key)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 300)
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Cancel") {
                onDecision(nil)
            }
            .keyboardShortcut(.cancelAction)

            Button("Group") {
                confirm()
            }
            .disabled(!canConfirm)
            .keyboardShortcut(.defaultAction)
            .tint(theme.orange)
        }
    }

    // MARK: Confirm

    private func confirm() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let year = Int(yearText.trimmingCharacters(in: .whitespaces))
        let members = zip(rows, editionLabels).map { row, label in
            VersionMember(
                key: row.key,
                editionLabel: label.isEmpty ? nil : label
            )
        }
        onDecision(GroupAlbumsSheetController.Result(
            name: trimmedName,
            originalYear: year,
            primaryKey: primaryKey,
            members: members
        ))
    }
}
