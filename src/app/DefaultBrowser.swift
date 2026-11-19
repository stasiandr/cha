import AppKit

// cha as the default browser: links from other apps arrive as the GetURL
// Apple event, files (.html, .webloc) as open-documents; each opens in a new
// tab of the current space. What arrives before the window exists (the link
// that launched cha) waits for it. Info.plist declares http/https and the
// document types; "Make cha the Default Browser" asks macOS to switch, which
// shows the system's own confirmation.
final class URLOpener: NSObject {
    static let shared = URLOpener()
    weak var controller: BrowserController? {
        didSet { flush() }
    }
    private var pending: [String] = []

    // Installed before the app finishes launching (the launch link is
    // already queued then) and again once CEF is up, in case it set its own.
    func install() {
        let manager = NSAppleEventManager.shared()
        manager.setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        manager.setEventHandler(
            self, andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        // Who sent the link: its window is where the little window goes.
        let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        callerFrame = Self.frontWindowFrame(of: sender.map { pid_t($0) })
        let senderApp = sender.flatMap { NSRunningApplication(processIdentifier: pid_t($0))?.localizedName }
        Diagnostics.linkLog(String(
            format: "link from %@ (pid %d), front %@, caller window %@, mouse %@", senderApp ?? "-",
            sender ?? 0, NSWorkspace.shared.frontmostApplication?.localizedName ?? "-",
            callerFrame.map { NSStringFromRect($0) } ?? "none", NSStringFromPoint(NSEvent.mouseLocation)))
        open(url)
    }

    // The app the link came from and its front window, in AppKit screen
    // coordinates: the sender of the event, else the app in front then.
    private(set) var callerFrame: NSRect?

    static func frontWindowFrame(of pid: pid_t?) -> NSRect? {
        let own = ProcessInfo.processInfo.processIdentifier
        var candidates: [pid_t] = []
        if let pid, pid > 0, pid != own { candidates.append(pid) }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != own {
            candidates.append(front)
        }
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        for pid in candidates {
            // The list is front to back: the first normal, sizeable window.
            for info in list {
                guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                    (info[kCGWindowLayer as String] as? Int) == 0,
                    let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                    let w = b["Width"], let h = b["Height"], w >= 200, h >= 150
                else { continue }
                return NSRect(x: b["X"] ?? 0, y: top - (b["Y"] ?? 0) - h, width: w, height: h)
            }
        }
        return nil
    }

    @objc func handleOpenDocuments(
        _ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor
    ) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        let count = list.numberOfItems
        // A single file comes as the descriptor itself, several as a list.
        let items = count > 0 ? (1...count).compactMap { list.atIndex($0) } : [list]
        for item in items {
            if let file = item.coerce(toDescriptorType: typeFileURL)?.stringValue {
                open(Self.target(forFile: file))
            }
        }
    }

    // A .webloc is a saved link: open where it points, not the file.
    static func target(forFile fileURL: String) -> String {
        guard let url = URL(string: fileURL), url.pathExtension.lowercased() == "webloc",
            let plist = NSDictionary(contentsOf: url), let link = plist["URL"] as? String
        else { return fileURL }
        return link
    }

    func open(_ url: String) {
        pending.append(url)
        flush()
    }

    private func flush() {
        guard let controller, controller.window != nil, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        // Like Little Arc: each link opens in a little window over the app
        // it came from; "Open in cha" moves it into the main window.
        for url in urls { controller.openLittleWindow(url, over: callerFrame) }
        callerFrame = nil
        NSLog("OPENED %@", urls.joined(separator: " "))
    }

    // MARK: Default browser

    static let probe = URL(string: "https://example.com")!

    static var isDefault: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    // macOS asks the user to confirm; nothing changes until they do.
    static func makeDefault() {
        let app = Bundle.main.bundleURL
        for scheme in ["http", "https"] {
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) {
                error in
                if let error { NSLog("DEFAULT %@: %@", scheme, error.localizedDescription) }
            }
        }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .html) { _ in }
    }
}
