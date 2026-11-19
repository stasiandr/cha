import AppKit
import SwiftUI

// A little window, as Arc's Little Arc: links from other apps open in a small
// window that floats above everything, to read, sign in or click through and
// close (⌘W, the close button), or to keep: "Open in cha" (⌘O) moves the
// page, as it is, into the main window as a new tab of the current space.
// ⌥⌘N opens an empty one.
//
// The page is a ChaTab like any tab: its frameless CEF window is a child of
// this window, below a 40 pt bar with the site and the button.
final class LittleWindowController: NSObject, ObservableObject, NSWindowDelegate, ChaTabDelegate {
    static var open: [LittleWindowController] = []
    // One line with the traffic lights, whose centres are 22 pt down.
    static let barHeight: CGFloat = 44
    static let inset: CGFloat = 8

    @Published var url: String
    @Published var title = ""
    @Published var favicon: NSImage?
    @Published var loading = true

    let window: BrowserWindow
    private(set) var tab: ChaTab!
    private weak var main: BrowserController?
    private var movedToMain = false

    // The window for |url|, centred on the screen under the pointer.
    @discardableResult
    static func show(_ url: String, main: BrowserController, over caller: NSRect? = nil)
        -> LittleWindowController
    {
        let little = LittleWindowController(url: url, main: main, over: caller)
        open.append(little)
        return little
    }

    // The little window whose page (or itself) has the keyboard.
    static var key: LittleWindowController? {
        guard let keyWindow = NSApp.keyWindow else { return nil }
        return open.first { $0.window === keyWindow || $0.window === keyWindow.parent }
    }

    // Where it opens: centred over the window the link came from, at most
    // 960×700 and 90 % of that window (420×300 at least), kept on that
    // window's screen. Without one, centred on the screen under the pointer.
    static func frame(over caller: NSRect?, screens: [NSScreen] = NSScreen.screens) -> NSRect {
        let anchor = caller ?? {
            let mouse = NSEvent.mouseLocation
            return (screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? screens[0]).visibleFrame
        }()
        let centre = NSPoint(x: anchor.midX, y: anchor.midY)
        // The screen holding most of that window (its centre may sit right
        // on a screen's edge).
        func overlap(_ s: NSScreen) -> CGFloat {
            let i = s.frame.intersection(anchor)
            return i.isNull ? 0 : i.width * i.height
        }
        let screen = (screens.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil }
            ?? NSScreen.main ?? screens[0]).visibleFrame
        var size = NSSize(width: min(960, anchor.width * 0.9), height: min(700, anchor.height * 0.9))
        size.width = min(max(size.width, 420), screen.width)
        size.height = min(max(size.height, 300), screen.height)
        var frame = NSRect(
            x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width,
            height: size.height)
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        return frame.integral
    }

    static func screenName(_ rect: NSRect) -> String {
        NSScreen.screens.max { a, b in
            a.frame.intersection(rect).width * a.frame.intersection(rect).height
                < b.frame.intersection(rect).width * b.frame.intersection(rect).height
        }?.localizedName ?? "-"
    }

    private init(url: String, main: BrowserController, over caller: NSRect?) {
        self.url = url
        self.main = main
        let frame = Self.frame(over: caller)
        window = BrowserWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 420, height: 300)
        window.delegate = self
        // It floats over the app the link came from until it is dealt with,
        // on whatever desktop that is: a full-screen app's included, rather
        // than taking you to cha's own desktop.
        // It must open on the caller's display: .moveToActiveSpace sent it to
        // the "active" desktop instead, which with a display per desktop
        // could be the other monitor (where cha's main window is). Joining
        // every desktop shows it right where its frame is, a full-screen
        // app's desktop included; once on screen it settles into that one.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        window.contentView = background
        let tint = NSView(frame: background.bounds)
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        if let theme = main.activeSpace.theme.color.usingColorSpace(.sRGB) {
            tint.layer?.backgroundColor = theme.withAlphaComponent(0.32).cgColor
        }
        background.addSubview(tint)
        let bar = NSHostingView(rootView: LittleBar(controller: self))
        bar.sizingOptions = []
        bar.frame = NSRect(
            x: 0, y: background.bounds.height - Self.barHeight, width: background.bounds.width,
            height: Self.barHeight)
        bar.autoresizingMask = [.width, .minYMargin]
        background.addSubview(bar)

        if Diagnostics.headless {
            window.setFrameOrigin(NSPoint(x: Diagnostics.offscreenOrigin.x, y: Diagnostics.offscreenOrigin.y + 2000))
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
            // Only this window comes forward, over the app the link came
            // from: activating the whole app also raised the main window,
            // so the little one sat over cha instead of over Slack.
            NSRunningApplication.current.activate(options: [])
            // Activation may still shift it (and the log says where it went).
            for delay in [0.05, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    let moved = !self.window.frame.isClose(to: frame)
                    Diagnostics.linkLog(String(
                        format: "little +%.2fs want %@ (%@) got %@ (%@)%@", delay,
                        NSStringFromRect(frame), Self.screenName(frame),
                        NSStringFromRect(self.window.frame), Self.screenName(self.window.frame),
                        moved ? " → put back" : ""))
                    if moved { self.window.setFrame(frame, display: true) }
                    if delay > 0.1 { self.window.collectionBehavior = [.fullScreenAuxiliary] }
                }
            }
        }
        window.placeTrafficLights()

        // The open space's profile: sign-ins as that space has them.
        let tab = ChaTab(url: url, screenFrame: pageScreenRect, profile: main.activeSpace.profileID?.uuidString)
        tab.delegate = self
        tab.setCornerRadius(10)
        self.tab = tab
        attachPage()
        pinPage()
    }

    // A page may resize or move its own window (window.resizeTo, sign-in
    // pages do), and Chromium lets it: the window snaps back to its place.
    private var pinObservers: [NSObjectProtocol] = []
    private func pinPage() {
        guard pinObservers.isEmpty, let native = tab?.nativeWindow else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.pinPage() }
            return
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            pinObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: native, queue: .main) {
                    [weak self] _ in self?.layoutPage()
                })
        }
        layoutPage()
    }

    private var laying = false
    func layoutPage() {
        guard !laying, let native = tab?.nativeWindow else { return }
        let target = pageScreenRect
        guard !native.frame.isClose(to: target) else { return }
        laying = true
        native.setFrame(target, display: true)
        laying = false
    }

    var pageScreenRect: NSRect {
        guard let content = window.contentView else { return .zero }
        let inset = Self.inset
        let local = NSRect(
            x: inset, y: inset, width: content.bounds.width - 2 * inset,
            height: content.bounds.height - Self.barHeight - inset)
        return window.convertToScreen(local)
    }

    private func attachPage() {
        guard let native = tab?.nativeWindow else { return }
        if native.parent !== window { window.addChildWindow(native, ordered: .above) }
        native.setFrame(pageScreenRect, display: true)
        if Diagnostics.quiet { native.orderFront(nil) } else { native.makeKeyAndOrderFront(nil) }
        if !Diagnostics.quiet { tab.focus() }
    }

    // MARK: Actions

    // The page moves to the main window as it is: same browser, no reload.
    func openInMain() {
        guard let main, let tab else { return }
        movedToMain = true
        if let native = tab.nativeWindow, native.parent != nil { window.removeChildWindow(native) }
        // The little window goes first, then the page moves: closing it
        // after the move left the page hidden to Chromium, which drew
        // nothing until the tab was switched away and back.
        let url = tab.currentURL.isEmpty ? self.url : tab.currentURL
        let title = tab.title, favicon = self.favicon
        window.close()
        main.adopt(tab, url: url, title: title, favicon: favicon)
    }

    func close() { window.close() }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        layoutPage()
        window.placeTrafficLights()
    }

    func windowDidMove(_ notification: Notification) { layoutPage() }

    func windowWillClose(_ notification: Notification) {
        if !movedToMain {
            if let native = tab?.nativeWindow, native.parent != nil { window.removeChildWindow(native) }
            tab?.close()
        }
        for observer in pinObservers { NotificationCenter.default.removeObserver(observer) }
        pinObservers = []
        Self.open.removeAll { $0 === self }
    }

    // MARK: ChaTabDelegate

    func tabDidBecomeReady(_ tab: ChaTab) { attachPage() }

    func tabDidUpdate(_ tab: ChaTab) {
        layoutPage()
        if !tab.currentURL.isEmpty { url = tab.currentURL }
        title = tab.title
        if let icon = tab.favicon { favicon = icon }
        loading = tab.isLoading
        window.title = title
    }

    func tabDidFinishLoad(_ tab: ChaTab) {}

    // A page in the little window that opens another window: that goes to
    // the main window, the little one stays for the task at hand.
    func tab(_ tab: ChaTab, requestsNewTabWithURL url: String) {
        main?.newTab(url: url)
    }

    func tabDidClose(_ tab: ChaTab) {
        main?.littleTabClosed()
        if !movedToMain, window.isVisible { window.close() }
    }
}

struct LittleBar: View {
    @ObservedObject var controller: LittleWindowController

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 64, height: 1)  // The traffic lights.
            Group {
                if let icon = controller.favicon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                }
            }
            .frame(width: 14, height: 14)
            Text(displayHost(controller.url) ?? controller.url)
                .font(.system(size: 13, weight: .medium))
                .uiFrame("littleHost")
                .lineLimit(1)
                .truncationMode(.middle)
            if !controller.title.isEmpty {
                Text(controller.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                controller.openInMain()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("Open in cha")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.08)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Move this page into the main window (⌘O)")
            .uiFrame("littleOpen")
        }
        .padding(.horizontal, 10)
        // A 44 pt line from the top, centred on the traffic lights (22 pt).
        .frame(maxWidth: .infinity)
        .frame(height: LittleWindowController.barHeight)
        .frame(maxHeight: .infinity, alignment: .top)
        // The bar sits in the title bar's place: no extra inset for it.
        .ignoresSafeArea()
        .uiFrame("littleBar")
    }
}

extension BrowserController {
    // A page from a little window becomes a tab here, browser and all.
    func adopt(_ tab: ChaTab, url: String, title: String, favicon: NSImage?) {
        var data = TabData(url: url, title: title)
        data.lastActive = Date()
        var space = activeSpace
        let firstToday = space.tabs.firstIndex { !$0.isPinned } ?? space.tabs.count
        space.tabs.insert(data, at: firstToday)
        replace(space)
        register(tab, as: data.id)
        if let favicon { favicons[data.id] = favicon }
        activateTab(data.id, transition: .none)
        if !Diagnostics.quiet {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        // What a switch to the tab does, which is what woke the page up by
        // hand: off the screen and back, once the move has settled.
        let id = data.id
        DispatchQueue.main.async { [weak self] in self?.reshowPage(id) }
    }

    func reshowPage(_ id: UUID) {
        guard activeTabID == id, let native = liveTabs[id]?.nativeWindow else { return }
        if native.parent != nil { window.removeChildWindow(native) }
        native.orderOut(nil)
        showOnly(tabID: id)
        if !Diagnostics.quiet { liveTabs[id]?.focus() }
        NSLog("ADOPT shown: visible=%d child=%d alpha=%.1f", native.isVisible ? 1 : 0,
            native.parent === window ? 1 : 0, native.alphaValue)
    }

    func openLittleWindow(_ url: String, over caller: NSRect? = nil) {
        LittleWindowController.show(url, main: self, over: caller)
    }
}
