import AppKit
import SwiftUI

final class CarbonHostingController: NSHostingController<CarbonRootView> {
    let model: LibraryViewModel

    init() {
        let model = LibraryViewModel()
        self.model = model
        super.init(rootView: CarbonRootView(model: model))
        // The window owns its size; the content must never set it. By default an
        // NSHostingController pushes SwiftUI's measured size up as the window's
        // preferred content size, so anything that grew the content grew the
        // window — the radio FIX panel pushed it from 892pt to 1249pt, past the
        // bottom of the display, taking the transport footer off-screen with it.
        // The frame comes from WindowFramePlanner and the saved frame instead.
        sizingOptions = []
    }

    @available(*, unavailable)
    @objc required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Edit ▸ Select All (⌘A) routes here through the responder chain when no text
    /// field is editing (a focused field editor handles ⌘A first). Selects every
    /// album (or every track, in the flat track layout) so the whole source can be
    /// batch-added to a crate.
    override func selectAll(_ sender: Any?) {
        model.selectAllInSource()
    }
}
