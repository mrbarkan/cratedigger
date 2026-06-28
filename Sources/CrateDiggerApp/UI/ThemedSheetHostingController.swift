import AppKit
import SwiftUI

/// Base class for the AppKit sheet controllers whose content is a SwiftUI view
/// wrapped in `ThemedSheetWrapper`. Centralizes the otherwise-duplicated
/// `loadView` boilerplate (wrap → host → addChild → install) so each subclass
/// only builds its root view and wires `onDecision`.
class ThemedSheetHostingController: NSViewController {
    private var hostingController: NSViewController?

    /// Installs `rootView` (themed) as this controller's view. Call from the
    /// subclass's `loadView`.
    func setThemedRoot<Content: View>(_ rootView: Content) {
        let themed = ThemedSheetWrapper { rootView }
        let hostingController = NSHostingController(rootView: themed)
        self.hostingController = hostingController
        addChild(hostingController)
        view = hostingController.view
    }
}
