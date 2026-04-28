import Foundation
import os

public enum AppLog {
    public static let subsystem = "com.cratedigger.app"

    public static let scan       = Logger(subsystem: subsystem, category: "scan")
    public static let playback   = Logger(subsystem: subsystem, category: "playback")
    public static let conversion = Logger(subsystem: subsystem, category: "conversion")
    public static let tools      = Logger(subsystem: subsystem, category: "tools")
    public static let ui         = Logger(subsystem: subsystem, category: "ui")
    public static let library    = Logger(subsystem: subsystem, category: "library")
    public static let prefs      = Logger(subsystem: subsystem, category: "prefs")
}
