import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var aboutWindowController: AboutWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let windowController = MainWindowController()
        self.mainWindowController = windowController
        windowController.showWindow(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func openFolder(_ sender: Any?) {
        mainWindowController?.openFolder()
    }

    @objc private func showAbout(_ sender: Any?) {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.showWindow(self)
        aboutWindowController?.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About CrateDigger", action: #selector(showAbout(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit CrateDigger", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Open Folder...", action: #selector(openFolder(_:)), keyEquivalent: "o"))
        fileMenuItem.submenu = fileMenu

        NSApp.mainMenu = mainMenu
    }
}
