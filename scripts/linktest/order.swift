// The windows on the second display, front to back: is cha's little window
// over the sender, and the sender over cha's main window?
import AppKit
let cha = Int32(CommandLine.arguments[1])!, sender = Int32(CommandLine.arguments[2])!
let screen = NSScreen.screens[1].frame
let top = NSScreen.screens[0].frame.maxY
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
var order: [String] = []
for info in list {
    guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid == cha || pid == sender,
          let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let r = NSRect(x: b["X"]!, y: top - b["Y"]! - b["Height"]!, width: b["Width"]!, height: b["Height"]!)
    guard screen.intersects(r), r.width > 300 else { continue }
    let layer = info[kCGWindowLayer as String] as? Int ?? 0
    // The little window floats (layer > 0); main and its pages sit at 0.
    let kind = pid == sender ? "sender" : (layer > 0 ? "little" : "main")
    order.append(kind)
    print(kind, "layer", layer, NSStringFromRect(r))
}
let little = order.firstIndex(of: "little"), main = order.firstIndex(of: "main"), s = order.firstIndex(of: "sender")
if let little, let s, little < s, main.map({ $0 > s }) ?? true {
    print("PASS little over the sender, cha's main window behind it")
} else {
    print("FAIL order:", order.joined(separator: " > "))
}
