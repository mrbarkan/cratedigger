import AppKit
import SwiftUI

/// Presents SwiftUI content in a real window instead of a sheet.
///
/// A macOS sheet is physically attached to its parent — it cannot be moved, and
/// it cannot be resized unless the sheet window itself opts in, which SwiftUI's
/// `.sheet` never does. Tools you work *in* (tag editors, cleanup, artwork
/// search) want both, so they get a titled, resizable panel instead.
///
/// Call sites keep their existing `isPresented` binding; only the modifier name
/// changes. The panel writes `false` back to the binding when the user closes it,
/// so model-driven presentation (`!conflicts.isEmpty`) still tears down correctly.
///
/// A new window does NOT inherit the presenting view's SwiftUI environment, so
/// the content closure must inject whatever it needs — `.environmentObject(model)`
/// in practice. Theming is applied here so every panel matches the app.
extension View {
    func carbonPanel<PanelContent: View>(
        isPresented: Binding<Bool>,
        title: String,
        minSize: NSSize,
        initialSize: NSSize? = nil,
        maxSize: NSSize? = nil,
        autosaveName: String,
        @ViewBuilder content: @escaping () -> PanelContent
    ) -> some View {
        modifier(CarbonPanelModifier(
            isPresented: isPresented,
            title: title,
            minSize: minSize,
            initialSize: initialSize ?? minSize,
            maxSize: maxSize,
            autosaveName: autosaveName,
            panelContent: content
        ))
    }
}

private struct CarbonPanelModifier<PanelContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let minSize: NSSize
    let initialSize: NSSize
    let maxSize: NSSize?
    let autosaveName: String
    @ViewBuilder let panelContent: () -> PanelContent

    @State private var controller: CarbonPanelController?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { presented in
                presented ? present() : dismiss()
            }
            .onDisappear(perform: dismiss)
    }

    private func present() {
        guard controller == nil else { return }
        let panel = CarbonPanelController(
            title: title,
            minSize: minSize,
            initialSize: initialSize,
            maxSize: maxSize,
            autosaveName: autosaveName,
            rootView: AnyView(panelContent().carbonThemed(mode: AppearanceMode.current)),
            onClose: {
                // Closing the window is a dismissal like any other — write it
                // back so model-driven bindings clear their state.
                if isPresented { isPresented = false }
            }
        )
        controller = panel
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
    }

    private func dismiss() {
        controller?.closeWithoutCallback()
        controller = nil
    }
}

/// The window itself. Sized between `minSize` and `maxSize`, position and size
/// remembered per `autosaveName` so a panel reopens where you left it.
private final class CarbonPanelController: NSWindowController, NSWindowDelegate {
    private var onClose: (() -> Void)?

    init(
        title: String,
        minSize: NSSize,
        initialSize: NSSize,
        maxSize: NSSize?,
        autosaveName: String,
        rootView: AnyView,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = minSize
        if let maxSize { window.contentMaxSize = maxSize }
        window.appearance = AppearanceMode.currentConcrete.nsAppearance

        super.init(window: window)
        window.delegate = self

        // setFrameAutosaveName restores a remembered frame if there is one; the
        // explicit size below only applies on first open.
        window.setContentSize(initialSize)
        window.setFrameAutosaveName(autosaveName)
        if window.frame.size.width < minSize.width || window.frame.size.height < minSize.height {
            window.setContentSize(initialSize)
        }
        if !window.setFrameUsingName(autosaveName) {
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Tear down without re-entering the binding — used when the *binding* was
    /// what dismissed us, so we don't write `false` over a fresh `true`.
    func closeWithoutCallback() {
        onClose = nil
        window?.delegate = nil
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }
}
