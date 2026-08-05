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
/// Closes the enclosing panel.
///
/// SwiftUI's `\.dismiss` only understands presentations it owns — a sheet, a
/// `WindowGroup` scene. It does nothing inside a hand-built `NSWindow`, so every
/// Cancel and Close button silently stopped working when these tools moved off
/// sheets. Content calls this instead; it falls back to `\.dismiss` so the same
/// views still close correctly if they're ever presented as a sheet again.
struct CarbonPanelDismissKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var carbonPanelDismiss: (() -> Void)? {
        get { self[CarbonPanelDismissKey.self] }
        set { self[CarbonPanelDismissKey.self] = newValue }
    }
}

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
            rootView: AnyView(
                panelContent()
                    // Content closes the panel through this, not \.dismiss.
                    .environment(\.carbonPanelDismiss, { isPresented = false })
                    .carbonThemed(mode: AppearanceMode.current)
            ),
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

        // Order matters. Restore any remembered frame FIRST, then correct it —
        // doing it the other way round let a stale or degenerate saved frame win,
        // which is how a panel could come up a few points tall.
        let restored = window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
        if !restored {
            window.setContentSize(initialSize)
        }

        // A window must never open larger than the screen it lands on — the
        // cleanup panel's content is as tall as the library, and without this it
        // opened taller than the display with its footer off the bottom.
        clampToScreen(window, minSize: minSize, maxSize: maxSize, fallback: initialSize)
        if !restored { window.center() }
    }

    /// Fit `window` inside its screen's visible frame, honouring the panel's own
    /// size limits. Leaves a margin so the panel never sits flush to the edges.
    private func clampToScreen(_ window: NSWindow, minSize: NSSize, maxSize: NSSize?, fallback: NSSize) {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(origin: .zero, size: fallback)
        let margin: CGFloat = 24
        let ceilingWidth = min(maxSize?.width ?? .greatestFiniteMagnitude, visible.width - margin * 2)
        let ceilingHeight = min(maxSize?.height ?? .greatestFiniteMagnitude, visible.height - margin * 2)

        var size = window.frame.size
        size.width = min(max(size.width, minSize.width), max(minSize.width, ceilingWidth))
        size.height = min(max(size.height, minSize.height), max(minSize.height, ceilingHeight))
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)

        // And keep it on-screen after the resize.
        var origin = window.frame.origin
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        window.setFrameOrigin(origin)
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
