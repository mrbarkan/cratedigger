import AppKit
import SwiftUI

final class CarbonHostingController: NSHostingController<CarbonRootView> {
    init() {
        super.init(rootView: CarbonRootView())
    }

    @available(*, unavailable)
    @objc required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
