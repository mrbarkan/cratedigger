import AppKit
import CrateDiggerCore

/// Playback ▸ Ambient. It is the target and validator of its own items, and
/// rebuilds the Microphone list each time that submenu opens, so a mic plugged
/// in a moment ago is already there. `AppDelegate` only inserts the item.
@MainActor
final class AmbientMenuController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = AmbientMenuController()

    private var model: @MainActor () -> LibraryViewModel? = { nil }
    private let microphoneMenu = NSMenu(title: "Microphone")

    func makeMenuItem(model: @escaping @MainActor () -> LibraryViewModel?) -> NSMenuItem {
        self.model = model

        let menu = NSMenu(title: "Ambient")
        let toggle = item("Ambient", #selector(toggleAmbient(_:)), key: "a")
        toggle.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(toggle)
        menu.addItem(.separator())

        microphoneMenu.delegate = self
        let microphone = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphone.submenu = microphoneMenu
        menu.addItem(microphone)
        menu.addItem(submenu("Delay", AmbientDelay.allCases.map { ($0.title, $0.rawValue) }, #selector(setDelay(_:))))
        menu.addItem(item("Low Cut", #selector(toggleLowCut(_:))))
        menu.addItem(submenu("Engine", AmbientEngineKind.allCases.map { ($0.title, $0.rawValue) }, #selector(setEngine(_:))))

        let root = NSMenuItem(title: "Ambient", action: nil, keyEquivalent: "")
        root.submenu = menu
        return root
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === microphoneMenu else { return }
        menu.removeAllItems()
        let systemDefault = item("System Default", #selector(setMicrophone(_:)))
        systemDefault.representedObject = ""
        menu.addItem(systemDefault)
        let inputs = model()?.ambientInputDevices() ?? []
        if !inputs.isEmpty { menu.addItem(.separator()) }
        for device in inputs {
            let entry = item(device.name, #selector(setMicrophone(_:)))
            entry.representedObject = device.uid
            menu.addItem(entry)
        }
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let model = model() else { return false }
        let settings = model.ambientSettings
        let represented = menuItem.representedObject as? String
        switch menuItem.action {
        case #selector(toggleAmbient(_:)):
            menuItem.state = model.ambientState == .off ? .off : .on
        case #selector(setMicrophone(_:)):
            menuItem.state = represented == model.ambientEffectiveInputUID ? .on : .off
        case #selector(setDelay(_:)):
            menuItem.state = represented == settings.delay.rawValue ? .on : .off
        case #selector(toggleLowCut(_:)):
            menuItem.state = settings.lowCut ? .on : .off
        case #selector(setEngine(_:)):
            menuItem.state = represented == settings.engine.rawValue ? .on : .off
        default:
            break
        }
        return true
    }

    // MARK: - Actions

    @objc private func toggleAmbient(_ sender: NSMenuItem) { model()?.toggleAmbient() }

    @objc private func setMicrophone(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String ?? ""
        model()?.setAmbientInput(uid: uid.isEmpty ? nil : uid)
    }

    @objc private func setDelay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let delay = AmbientDelay(rawValue: raw) else { return }
        model()?.setAmbientDelay(delay)
    }

    @objc private func toggleLowCut(_ sender: NSMenuItem) {
        guard let model = model() else { return }
        model.setAmbientLowCut(!model.ambientSettings.lowCut)
    }

    @objc private func setEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = AmbientEngineKind(rawValue: raw) else { return }
        model()?.setAmbientEngine(kind)
    }

    // MARK: - Building

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func submenu(_ title: String, _ choices: [(String, String)], _ action: Selector) -> NSMenuItem {
        let menu = NSMenu(title: title)
        for (choiceTitle, raw) in choices {
            let entry = item(choiceTitle, action)
            entry.representedObject = raw
            menu.addItem(entry)
        }
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        root.submenu = menu
        return root
    }
}
