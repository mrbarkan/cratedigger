// Click a point inside the CrateDigger window, in window-relative points.
//
//   swift scripts/uiclick.swift <x> <y>
//
// Run as a script rather than built into a binary: it is a dozen lines, it is
// only used by scripts/shot.sh, and a compiled helper would be one more thing
// to keep in step with the app.
//
// System Events "click at" was tried first and is not reliable against
// SwiftUI controls: it reports success, resolves to whatever AXImage happens
// to be under the cursor, and leaves the real button unpressed. Posting the
// events through the HID tap is what actually works.

import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3, let rx = Double(args[1]), let ry = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: swift scripts/uiclick.swift <x> <y>\n".utf8))
    exit(2)
}

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                         kCGNullWindowID) as? [[String: Any]] ?? []
// The app also vends small panels and a titlebar accessory; the main window is
// the only tall one, so height is what tells them apart.
let main = windows.first { w in
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner.contains("CrateDigger"),
          let bounds = w[kCGWindowBounds as String] as? [String: Any],
          let height = bounds["Height"] as? Double else { return false }
    return height > 200
}

guard let window = main,
      let bounds = window[kCGWindowBounds as String] as? [String: Any],
      let ox = bounds["X"] as? Double, let oy = bounds["Y"] as? Double else {
    FileHandle.standardError.write(Data("CrateDigger window not found\n".utf8))
    exit(1)
}

for app in NSWorkspace.shared.runningApplications where app.localizedName?.contains("CrateDigger") == true {
    app.activate()
}
usleep(400_000)

let point = CGPoint(x: ox + rx, y: oy + ry)
let source = CGEventSource(stateID: .hidSystemState)
// Move first: a click posted without a preceding move lands with a stale
// hover state, and controls that key off hover render mid-transition.
CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
    .post(tap: .cghidEventTap)
usleep(120_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
    .post(tap: .cghidEventTap)
usleep(90_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
    .post(tap: .cghidEventTap)
usleep(500_000)
