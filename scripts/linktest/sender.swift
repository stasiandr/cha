// A stand-in for Slack: a window over a whole display whose only job is to
// send one link to a given cha bundle, as a click in another app does.
//   sender <display index> <cha.app path> <url> [fullscreen]
import AppKit

let args = CommandLine.arguments
let screenIndex = Int(args[1]) ?? 1
let chaApp = URL(fileURLWithPath: args[2])
let link = URL(string: args[3])!
let fullScreen = args.count > 4 && args[4] == "fullscreen"

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.screens[min(screenIndex, NSScreen.screens.count - 1)]
let window = NSWindow(
    contentRect: screen.visibleFrame, styleMask: [.titled, .resizable, .closable],
    backing: .buffered, defer: false)
window.title = "cha link sender"
window.backgroundColor = NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.3, alpha: 1)
window.collectionBehavior = [.fullScreenPrimary]
window.setFrame(screen.visibleFrame, display: true)
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
print("SENDER pid \(ProcessInfo.processInfo.processIdentifier) on \(screen.localizedName)")
if fullScreen {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { window.toggleFullScreen(nil) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + (fullScreen ? 3.5 : 1.5)) {
    app.activate(ignoringOtherApps: true)
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.open([link], withApplicationAt: chaApp, configuration: config) { _, error in
        print("SENDER sent \(link) \(error.map { "\($0)" } ?? "ok")")
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
app.run()
