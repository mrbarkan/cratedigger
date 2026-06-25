import AppKit
import SwiftUI

final class CarbonHostingController: NSHostingController<CarbonRootView> {
    let model: LibraryViewModel

    init() {
        let model = LibraryViewModel()
        self.model = model
        super.init(rootView: CarbonRootView(model: model))
    }

    @available(*, unavailable)
    @objc required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Edit ▸ Select All (⌘A) routes here through the responder chain when no text
    /// field is editing (a focused field editor handles ⌘A first). Selects every
    /// track in the browser so the whole source can be batch-added to a crate.
    override func selectAll(_ sender: Any?) {
        model.selectAllTracksInSource()
    }
}
