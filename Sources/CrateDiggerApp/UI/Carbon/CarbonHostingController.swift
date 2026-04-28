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
}
