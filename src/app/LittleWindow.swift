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
    static let barHeight: CGFloat = 40
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
    static func show(_ url: String, main: BrowserController) -> LittleWindowController {
        let little = LittleWindowController(url: url, main: main)
        open.append(little)
        return little
    }

    // The little window whose page (or itself) has the keyboard.
    static var key: LittleWindowController? {
        guard let keyWindow = NSApp.keyWindow else { return nil }
        return open.first { $0.window === keyWindow || $0.window === keyWindow.parent }
    }

    private init(url: String, main: BrowserController) {
        self.url = url
        self.main = main
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: min(960, screen.visibleFrame.width * 0.7), height: min(700, screen.visibleFrame.height * 0.8))
        let frame = NSRect(
            x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2,
            width: size.width, height: size.height)
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
        // It floats over the app the link came from until it is dealt with.
        window.level = .floating

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
            NSApp.activate(ignoringOtherApps: true)
        }
        window.placeTrafficLights()

        let tab = ChaTab(url: url, screenFrame: pageScreenRect)
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
        main.adopt(tab, url: tab.currentURL.isEmpty ? url : tab.currentURL, title: tab.title, favicon: favicon)
        window.close()
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
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        activateTab(data.id)
        if !Diagnostics.quiet {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func openLittleWindow(_ url: String) {
        LittleWindowController.show(url, main: self)
    }
}
