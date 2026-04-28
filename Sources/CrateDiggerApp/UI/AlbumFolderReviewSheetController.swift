import AppKit
import CrateDiggerCore
import SwiftUI

struct AlbumFolderReviewRow: Identifiable, Hashable {
    let key: AlbumFolderKey
    let albumLabel: String
    let proposedSubpath: String

    var id: String {
        "\(key.year)|\(key.artistBucket)|\(key.album)"
    }
}

final class AlbumFolderReviewSheetController: NSViewController {
    var onDecision: (([AlbumFolderKey: String]?) -> Void)?

    private let rows: [AlbumFolderReviewRow]
    private var hostingController: NSViewController?

    init(rows: [AlbumFolderReviewRow]) {
        self.rows = rows
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = AlbumFolderReviewSheetView(rows: rows) { [weak self] reviewedFolders in
            self?.onDecision?(reviewedFolders)
        }

        let themed = ThemedSheetWrapper { rootView }
        let hostingController = NSHostingController(rootView: themed)
        self.hostingController = hostingController
        addChild(hostingController)
        view = hostingController.view
    }
}
