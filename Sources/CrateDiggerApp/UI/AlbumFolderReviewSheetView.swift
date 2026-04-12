import CrateDiggerCore
import SwiftUI

private struct EditableAlbumFolderRow: Identifiable {
    let key: AlbumFolderKey
    let albumLabel: String
    var destinationSubpath: String

    var id: String {
        "\(key.year)|\(key.artistBucket)|\(key.album)"
    }
}

struct AlbumFolderReviewSheetView: View {
    let onDecision: ([AlbumFolderKey: String]?) -> Void

    @State private var rows: [EditableAlbumFolderRow]

    init(rows: [AlbumFolderReviewRow], onDecision: @escaping ([AlbumFolderKey: String]?) -> Void) {
        self.onDecision = onDecision
        _rows = State(initialValue: rows.map {
            EditableAlbumFolderRow(
                key: $0.key,
                albumLabel: $0.albumLabel,
                destinationSubpath: $0.proposedSubpath
            )
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Album Folders")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(Color(nsColor: ModernRetroTheme.textPrimary))

            Text("Confirm the destination subfolder for each album before conversion starts.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(nsColor: ModernRetroTheme.textSecondary))

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($rows) { $row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.albumLabel)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(nsColor: ModernRetroTheme.textPrimary))

                            TextField("Destination subfolder", text: $row.destinationSubpath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, weight: .regular))
                                .accessibilityLabel("Destination subfolder for \(row.albumLabel)")
                                .accessibilityHint("Edit the destination path that will be used for this album during conversion.")
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(nsColor: ModernRetroTheme.surfaceElevated))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color(nsColor: ModernRetroTheme.separator).opacity(0.35), lineWidth: 1)
                        )
                    }
                }
                .padding(.trailing, 4)
            }

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") {
                    onDecision(nil)
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Close this review without changing album folder destinations.")

                Button("Continue") {
                    var reviewed: [AlbumFolderKey: String] = [:]
                    for row in rows {
                        let cleaned = sanitizeRelativeSubpath(row.destinationSubpath, fallback: row.albumLabel.replacingOccurrences(of: " • ", with: "/"))
                        reviewed[row.key] = cleaned
                    }
                    onDecision(reviewed)
                }
                .keyboardShortcut(.defaultAction)
                .tint(Color(nsColor: ModernRetroTheme.accentInfo))
                .accessibilityHint("Confirm the reviewed album folder destinations and continue with conversion.")
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 460)
        .background(Color(nsColor: ModernRetroTheme.surfaceBase))
    }

    private func sanitizeRelativeSubpath(_ rawPath: String, fallback: String) -> String {
        let components = rawPath
            .split(separator: "/")
            .map {
                $0
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: "\\", with: "-")
            }
            .filter { !$0.isEmpty }

        if components.isEmpty {
            return fallback
        }

        return components.joined(separator: "/")
    }
}
