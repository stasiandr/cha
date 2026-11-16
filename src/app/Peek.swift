import AppKit
import SwiftUI

// Peek, as Arc does it: a link to another site from a pinned tab or a
// favourite (which keep their site, like apps), or any ⇧-clicked link, opens
// as a card over the page inside the window instead of a tab. Close it (Esc,
// ⌘W, the ✕, a click on the dimmed page) and the tab is as it was; expand it
// (the ⤢, ⌘O) and the page, as it is, becomes a tab of the space.
//
// The card is a ChaTab of its own, its window a child of the main window,
// above a dimming window over the page and below a small panel with the two
// buttons.
final class PeekController: NSObject, ObservableObject, ChaTabDelegate {
    @Published var url: String
    @Published var title = ""
    @Published var favicon: NSImage?

    private weak var main: BrowserController?
    private(set) var tab: ChaTab!
    private let dim: NSWindow
    private let buttons: NSPanel
    private var expanded = false
    private(set) var closed = false

    init(url: String, main: BrowserController) {
        self.url = url
        self.main = main
        dim = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        buttons = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        super.init()

        dim.isOpaque = false
        dim.backgroundColor = .clear
        dim.hasShadow = false
        dim.isReleasedWhenClosed = false
        let shade = PeekShade { [weak self] in self?.close() }
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        shade.layer?.cornerRadius = main.pageCornerRadius
        dim.contentView = shade

        buttons.isOpaque = false
        buttons.backgroundColor = .clear
        buttons.hasShadow = false
        buttons.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: PeekButtons(peek: self))
        hosting.sizingOptions = []
        buttons.contentView = hosting

        let tab = ChaTab(url: url, screenFrame: cardFrame, profile: main.activeSpace.profileID?.uuidString)
        tab.delegate = self
        tab.setCornerRadius(12)
        self.tab = tab
        show()
        pinCard()
    }

    // Chromium moves a window it has just shown back onto the screen, and a
    // page may move or resize its own (window.resizeTo): the card snaps back.
    private var pinObservers: [NSObjectProtocol] = []
    private var placing = false
    private func pinCard() {
        guard let native = tab?.nativeWindow else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            pinObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: native, queue: .main) {
                    [weak self] _ in self?.placeCard()
                })
        }
        placeCard()
    }

    private func placeCard() {
        guard !closed, !placing, let native = tab?.nativeWindow else { return }
        let target = cardFrame
        guard !native.frame.isClose(to: target) else { return }
        placing = true
        native.setFrame(target, display: true)
        placing = false
    }

    // The card: most of the page, a little room above for the buttons.
    var cardFrame: NSRect {
        guard let main else { return .zero }
        let page = main.contentScreenRect
        let side = (page.width * 0.075).rounded()
        return NSRect(
            x: page.minX + side, y: page.minY + 20, width: page.width - 2 * side,
            height: page.height - 20 - 46)
    }

    private var buttonsFrame: NSRect {
        let card = cardFrame
        return NSRect(x: card.maxX - 70, y: card.maxY + 8, width: 70, height: 30)
    }

    private func show() {
        guard let main, let window = main.window else { return }
        dim.setFrame(main.contentScreenRect, display: true)
        dim.alphaValue = 0
        window.addChildWindow(dim, ordered: .above)
        dim.orderFront(nil)
        attachCard()
        buttons.setFrame(buttonsFrame, display: true)
        window.addChildWindow(buttons, ordered: .above)
        buttons.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            dim.animator().alphaValue = 1
        }
    }

    private func attachCard() {
        guard let native = tab?.nativeWindow, let window = main?.window else { return }
        if native.parent !== window { window.addChildWindow(native, ordered: .above) }
        native.hasShadow = true
        native.setFrame(cardFrame, display: true)
        if Diagnostics.quiet { native.orderFront(nil) } else { native.makeKeyAndOrderFront(nil) }
        // The buttons stay above the card.
        if buttons.parent === window {
            window.removeChildWindow(buttons)
            window.addChildWindow(buttons, ordered: .above)
        }
        if !Diagnostics.quiet { tab.focus() }
    }

    func layout() {
        guard !closed, let main else { return }
        dim.setFrame(main.contentScreenRect, display: true)
        (dim.contentView)?.layer?.cornerRadius = main.pageCornerRadius
        placeCard()
        buttons.setFrame(buttonsFrame, display: true)
    }

    // MARK: Actions

    func close() {
        guard !closed else { return }
        closed = true
        teardown()
        if !expanded { tab?.close() }
        main?.peekDidClose(self)
    }

    // The page becomes a tab of the open space, browser and all.
    func expand() {
        guard !closed, let main, let tab else { return }
        expanded = true
        if let native = tab.nativeWindow, native.parent != nil { main.window.removeChildWindow(native) }
        tab.nativeWindow?.hasShadow = false
        closed = true
        teardown()
        main.peekDidClose(self)
        main.adopt(tab, url: tab.currentURL.isEmpty ? url : tab.currentURL, title: tab.title, favicon: favicon)
    }

    private func teardown() {
        for observer in pinObservers { NotificationCenter.default.removeObserver(observer) }
        pinObservers = []
        for window in [dim, buttons] {
            if let parent = window.parent { parent.removeChildWindow(window) }
            window.orderOut(nil)
        }
        if !expanded, let native = tab?.nativeWindow {
            if let parent = native.parent { parent.removeChildWindow(native) }
            native.orderOut(nil)
        }
    }

    // MARK: ChaTabDelegate

    func tabDidBecomeReady(_ tab: ChaTab) { attachCard() }

    func tabDidUpdate(_ tab: ChaTab) {
        if !tab.currentURL.isEmpty { url = tab.currentURL }
        title = tab.title
        if let icon = tab.favicon { favicon = icon }
    }

    func tabDidFinishLoad(_ tab: ChaTab) {}

    func tab(_ tab: ChaTab, requestsNewTabWithURL url: String) { main?.newTab(url: url) }

    // A Peek in a Peek just goes there.
    func tab(_ tab: ChaTab, requestsPeekWithURL url: String) { tab.loadURL(url) }

    func tabDidClose(_ tab: ChaTab) {
        main?.littleTabClosed()
        if !closed {
            closed = true
            teardown()
            main?.peekDidClose(self)
        }
    }
}

// The dimmed page: a click on it closes the Peek.
final class PeekShade: NSView {
    let onClick: () -> Void
    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onClick() }
}

struct PeekButtons: View {
    let peek: PeekController

    var body: some View {
        HStack(spacing: 6) {
            button("arrow.up.left.and.arrow.down.right", help: "Open as a tab (⌘O)") { peek.expand() }
            button("xmark", help: "Close (Esc)") { peek.close() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.regularMaterial))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension BrowserController {
    func openPeek(_ url: String) {
        peek?.close()
        peek = PeekController(url: url, main: self)
        installPeekKeys()
        NSLog("PEEK %@", url)
    }

    func peekDidClose(_ closing: PeekController) {
        if peek === closing { peek = nil }
        if let monitor = peekKeyMonitor {
            NSEvent.removeMonitor(monitor)
            peekKeyMonitor = nil
        }
        if !Diagnostics.quiet { activeTab?.focus() }
    }

    // Esc closes it from anywhere in the app while it is open.
    private func installPeekKeys() {
        guard peekKeyMonitor == nil else { return }
        peekKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.peek != nil, event.keyCode == 53 else { return event }
            self.peek?.close()
            return nil
        }
    }

    // Pinned tabs and favourites keep their site: other sites go to a Peek.
    func refreshKeepsSite(_ id: UUID) {
        guard let tab = liveTabs[id] else { return }
        tab.keepsItsSite = favorites.contains { $0.id == id } || tabData(id)?.isPinned == true
    }

    func tab(_ tab: ChaTab, requestsPeekWithURL url: String) {
        openPeek(url)
    }
}
