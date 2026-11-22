import AppKit
#if DEBUG
import CrateDiggerCore
import Foundation

// CRATEDIGGER_PODBOX_DRYRUN=<volume path>: print what CrateDigger reads on
// that device and what a cleanup would remove, then exit before any window
// opens. Read-only: it probes and plans, and builds no executor and no
// journal. CRATEDIGGER_PODBOX_MUSIC names the music folder (default "Music").
if let volume = ProcessInfo.processInfo.environment["CRATEDIGGER_PODBOX_DRYRUN"] {
    let music = ProcessInfo.processInfo.environment["CRATEDIGGER_PODBOX_MUSIC"] ?? "Music"
    print(PodBoxDryRun.report(volumeRoot: URL(fileURLWithPath: volume, isDirectory: true), musicSubpath: music),
          terminator: "")
    exit(0)
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
