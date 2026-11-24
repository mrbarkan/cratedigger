import CoreGraphics
import Foundation
let owner = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == owner {
    let b = w[kCGWindowBounds as String] as! [String: Any]
    let layer = w[kCGWindowLayer as String] as! Int
    print(w[kCGWindowNumber as String]!, layer, b["Width"]!, b["Height"]!, w[kCGWindowName as String] ?? "")
}
