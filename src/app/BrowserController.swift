import AppKit
import SwiftUI

// Owns the window, the spaces/tabs state and the CEF tab windows. A tab is a
// separate frameless CEF window attached as a child of the main window, so
// only the active tab's window is visible and it tracks the content area.
final class BrowserController: NSObject, ObservableObject, NSWindowDelegate,
    ChaTabDelegate
{
    @Published var spaces: [SpaceData]
    @Published var activeSpaceID: UUID
    // Favourites are shared by every space, as in Arc.
    @Published var favorites: [TabData]
    @Published var archive: [ArchivedTab]
    @Published var profiles: [ProfileData]
    @Published var favicons: [UUID: NSImage] = [:]
    @Published var loadingTabs: Set<UUID> = []
    @Published var sidebarVisible = true
    @Published var isFullscreen = false
    @Published var addressText = ""
    @Published var focusAddressToken = 0  // Bumped to move focus to the field.
    @Published var commandQuery = "" { didSet { refreshCommandResults() } }
    @Published var commandResults: [CommandResult] = []
    @Published var commandSelection = 0
    @Published var canGoBack = false
    @Published var canGoForward = false

    // What the sidebar shows in place of the space's tabs.
    enum SidebarPage: Equatable {
        case tabs
        case editSpace(UUID, isNew: Bool)
        case downloads
    }
    @Published var sidebarPage: SidebarPage = .tabs
    @Published var slidingToDownloads = false

    // Space paging: how far the space's page is dragged sideways (points,
    // positive = towards the previous space) and which space sits next to it.
    @Published var pageOffset: CGFloat = 0
    @Published var pageNeighbor: (left: UUID?, right: UUID?) = (nil, nil)
    var pageAnimating = false
    var pageGeneration = 0

    @Published var sidebarWidth: CGFloat = 225
    static let minSidebarWidth: CGFloat = 180
    static let maxSidebarWidth: CGFloat = 420
    static let contentInset: CGFloat = 8
    // Unpinned tabs left alone this long go to the archive at launch.
    static let archiveAfter: TimeInterval = 12 * 3600

    var window: NSWindow!
    var sidebarView: NSView?
    private var tintView: NSView?  // The space's colour behind everything.
    private var contentWell: NSView?  // Drops a shadow under the page card.
    // Made in showWindow, once the sidebar view exists. (It used to be a
    // lazy var: the window's saved frame was restored before the sidebar
    // existed, the resize asked for the constraint, and it was made with no
    // view — the sidebar's width was then held by nothing and the page and
    // the sidebar drifted apart.)
    var sidebarWidthConstraint: NSLayoutConstraint?
    // Slides the sidebar out to the left (−width) and back.
    var sidebarLeadingConstraint: NSLayoutConstraint?
    var sidebarAnimating = false
    static let sidebarDuration: TimeInterval = 0.15
    var commandPanel: CommandPanel?
    var findPanel: CommandPanel?
    var peek: PeekController?
    var peekKeyMonitor: Any?
    let find = FindModel()
    var commandMode: CommandMode = .newTab
    var commandBarOpens = 0  // How many times it opened (the checks).
    @Published var commandFocusToken = 0  // Bumped to focus and select the field.
    var commandKeyMonitor: Any?
    var pinning = false
    var swipeMonitor: Any?
    var swipe = SwipeTracker()
    private var appearanceObservation: NSKeyValueObservation?
    private(set) var liveTabs: [UUID: ChaTab] = [:]
    private var tabIDsByObject: [ObjectIdentifier: UUID] = [:]
    private var saveScheduled = false

    override init() {
        let state = Persistence.load()
        spaces = state.spaces
        favorites = state.favorites ?? []
        archive = state.archive ?? []
        profiles = state.profiles ?? []
        let saved = state.activeSpaceID
        activeSpaceID =
            state.spaces.contains { $0.id == saved } ? saved! : state.spaces[0].id
        sidebarWidth = CGFloat(state.sidebarWidth ?? 225)
        super.init()
        sidebarFraction = CGFloat(state.sidebarFraction ?? Double(sidebarWidth) / 1280)
        loadSavedFavicons()
    }

    // MARK: - Window

    func showWindow() {
        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "cha"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 420)
        // Arc's window moves by any empty part of the sidebar.
        window.isMovableByWindowBackground = true

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        window.contentView = background

        // Arc washes the whole window in the space's colour and sets the page
        // on top of it as a card; both live under the sidebar.
        let tint = NSView(frame: background.bounds)
        tint.layer = CAGradientLayer()  // Layer-hosting: the layer comes first.
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        background.addSubview(tint)
        tintView = tint

        let well = NSView()
        well.wantsLayer = true
        well.layer?.cornerRadius = Self.contentCornerRadius
        well.layer?.shadowColor = NSColor.black.cgColor
        well.layer?.shadowOpacity = 0.22
        well.layer?.shadowRadius = 14
        well.layer?.shadowOffset = CGSize(width: 0, height: -3)
        background.addSubview(well)
        contentWell = well

        let sidebar = NSHostingView(rootView: SidebarView(controller: self))
        let widthConstraint = sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth)
        sidebarWidthConstraint = widthConstraint
        let leading = sidebar.leadingAnchor.constraint(equalTo: background.leadingAnchor)
        sidebarLeadingConstraint = leading
        // The width is ours (sidebarWidth, which follows the window); left to
        // itself the hosting view pins its width to the SwiftUI content's
        // size, wins against the width constraint, and the page and the
        // sidebar drift apart when the window is resized.
        sidebar.sizingOptions = []
        sidebarView = sidebar
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(sidebar)
        NSLayoutConstraint.activate([
            leading,
            sidebar.topAnchor.constraint(equalTo: background.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            widthConstraint,
        ])

        if Diagnostics.headless || Diagnostics.screenMissing {
            if Diagnostics.screenMissing {
                NSLog("SCREEN %d is not connected: running off screen", Diagnostics.screenIndex ?? -1)
            }
            window.setFrameOrigin(Diagnostics.offscreenOrigin)
            window.orderFront(nil)
        } else if let index = Diagnostics.screenIndex {
            let screens = NSScreen.screens
            let screen = screens[index].visibleFrame
            let size = NSSize(
                width: min(1280, screen.width - 40), height: min(820, screen.height - 40))
            window.setFrame(
                NSRect(
                    x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                    width: size.width, height: size.height), display: false)
            // Not active, it would sit under whatever is on that display;
            // a check needs it in view (and its pages painting).
            if Diagnostics.loud {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.level = .floating
                window.orderFront(nil)
            }
            NSLog(
                "SCREEN %d of %d: window at %@ on %@", index, screens.count,
                NSStringFromRect(window.frame), window.screen?.localizedName ?? "-")
        } else {
            if window.frame.origin == .zero { window.center() }
            window.makeKeyAndOrderFront(nil)
        }
        self.window = window
        // Only now, with the sidebar in place, may resizes reach us; the
        // saved frame is restored here for the same reason.
        window.delegate = self
        // A check run must not move the real window's saved frame.
        if !Diagnostics.quiet, ProcessInfo.processInfo.environment["CHA_TEST"] == nil {
            window.setFrameAutosaveName("cha.main")
        }
        followWindowWidth()
        window.placeTrafficLights()
        Diagnostics.mark("window")
        applySpaceTint()
        installSwipeMonitor()
        installReopen()
        window.acceptsMouseMovedEvents = true
        // Spaces' own profiles get ready while the first page loads.
        for profile in profiles { ChaTab.prepareProfile(profile.id.uuidString) }
        appearanceObservation = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applySpaceTint(animated: false) }
        }

        activateTab(activeSpace.activeTabID)
    }

    static let contentCornerRadius: CGFloat = 12

    // Where a tab's window sits, in the main window's own coordinates.
    // The page is a card with a margin and rounded corners, in a window and
    // in full screen alike, while the sidebar shows. Full screen with the
    // sidebar hidden is the page alone: every edge, no corners.
    var pageFillsScreen: Bool { isFullscreen && !sidebarVisible }

    var contentLocalRect: NSRect {
        guard let content = window?.contentView else { return .zero }
        let inset = pageFillsScreen ? 0 : Self.contentInset
        let left = sidebarVisible ? sidebarWidth : inset
        return NSRect(
            x: left, y: inset,
            width: max(content.bounds.width - left - inset, 100),
            height: max(content.bounds.height - 2 * inset, 100))
    }

    var pageCornerRadius: CGFloat { pageFillsScreen ? 0 : Self.contentCornerRadius }

    // Corners and shadow follow the mode, on the card and every page.
    func applyPageShape() {
        contentWell?.layer?.cornerRadius = pageCornerRadius
        contentWell?.layer?.shadowOpacity = pageFillsScreen ? 0 : 0.22
        for tab in liveTabs.values { tab.setCornerRadius(pageCornerRadius) }
    }

    // The same rectangle in screen coordinates, where a CEF window lives.
    var contentScreenRect: NSRect {
        guard window != nil else { return .zero }
        return window.convertToScreen(contentLocalRect)
    }

    func layoutActiveTab() {
        layoutContentWell()
        repositionFindBar()
        peek?.layout()
        guard let id = activeSpace.activeTabID, let tab = liveTabs[id],
            let native = tab.nativeWindow
        else { return }
        native.setFrame(contentScreenRect, display: true)
    }

    // The shadow needs a path of its own: the well itself is transparent, the
    // page's own window covers it.
    private func layoutContentWell() {
        guard let well = contentWell else { return }
        let rect = contentLocalRect
        well.frame = rect
        let radius = pageCornerRadius
        well.layer?.shadowPath =
            CGPath(
                roundedRect: CGRect(origin: .zero, size: rect.size),
                cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    var isDark: Bool {
        (window?.effectiveAppearance ?? NSApp.effectiveAppearance)
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // The window wears the active space's colour, as Arc's does; during a
    // swipe it is a blend of the two spaces.
    func applySpaceTint(_ theme: SpaceTheme? = nil, animated: Bool = true) {
        guard let gradient = tintView?.layer as? CAGradientLayer else { return }
        let tint = (theme ?? activeSpace.theme).color
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.25)
        } else {
            CATransaction.setDisableActions(true)
        }
        let (top, bottom): (CGFloat, CGFloat) = isDark ? (0.42, 0.20) : (0.50, 0.26)
        gradient.colors = [
            tint.withAlphaComponent(top).cgColor,
            tint.withAlphaComponent(bottom).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        CATransaction.commit()
    }

    func windowDidResize(_ notification: Notification) {
        followWindowWidth()
        layoutActiveTab()
        browserWindow?.placeTrafficLights()
    }
    func windowDidMove(_ notification: Notification) { layoutActiveTab() }

    var browserWindow: BrowserWindow? { window as? BrowserWindow }

    // The traffic lights go with the sidebar in a window. In full screen
    // they stay: macOS shows them with the menu bar when the pointer reaches
    // the top.
    func updateTrafficLights() {
        browserWindow?.trafficLightsHidden = !isFullscreen && !sidebarVisible
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        isFullscreen = true
        updateTrafficLights()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isFullscreen = true
        updateTrafficLights()
        applyPageShape()
        layoutActiveTab()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        isFullscreen = false
        applyPageShape()
    }

    // MARK: Full screen, animated by us

    // macOS animates only the main window; the page is a window of its own
    // and used to jump into place afterwards, flashing. With a custom
    // animation the window grows to the screen in 250 ms and every step lays
    // the page out again (windowDidResize), so they move as one.
    static let fullscreenDuration: TimeInterval = 0.25
    private static var frameBeforeFullscreen: [ObjectIdentifier: NSRect] = [:]

    func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? { [window] }
    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? { [window] }

    func window(
        _ window: NSWindow, startCustomAnimationToEnterFullScreenWithDuration duration: TimeInterval
    ) {
        Self.frameBeforeFullscreen[ObjectIdentifier(window)] = window.frame
        let screen = (window.screen ?? NSScreen.main ?? NSScreen.screens[0]).frame
        let level = window.level
        window.level = .mainMenu + 1  // Above the menu bar while it grows.
        window.styleMask.insert(.fullScreen)
        isFullscreen = true
        applyPageShape()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fullscreenDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(screen, display: true)
        } completionHandler: { [weak self] in
            window.level = level
            self?.layoutActiveTab()
        }
    }

    func window(
        _ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval
    ) {
        let target = Self.frameBeforeFullscreen[ObjectIdentifier(window)] ?? window.frame
        window.styleMask.remove(.fullScreen)
        isFullscreen = false
        applyPageShape()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fullscreenDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            self?.layoutActiveTab()
            self?.browserWindow?.placeTrafficLights()
        }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isFullscreen = false
        applyPageShape()
        layoutActiveTab()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullscreen = false
        updateTrafficLights()
        applyPageShape()
        layoutActiveTab()
    }

    // ⌘N, the Dock, hop: the main window in front. It is put back on a screen
    // if its saved place is on none (a monitor since unplugged or asleep).
    func showMainWindow() {
        guard !isQuitting, let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !Diagnostics.quiet,
            !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) })
        {
            let mouse = NSEvent.mouseLocation
            let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0])
                .visibleFrame
            var frame = window.frame
            frame.size.width = min(frame.width, screen.width)
            frame.size.height = min(frame.height, screen.height)
            frame.origin = NSPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
            window.setFrame(frame, display: true)
        }
        if Diagnostics.quiet {
            window.orderFront(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        layoutActiveTab()
        if let id = activeTabID { showOnly(tabID: id) }
        NSLog("WINDOW shown")
    }

    // Activated with no window on screen (hop, the Dock, ⌘-Tab): show it.
    func installReopen() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.isQuitting, let window = self.window else { return }
            if !window.isVisible || window.isMiniaturized { self.showMainWindow() }
        }
    }

    // Closing the only window quits, the same way ⌘Q does.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    // MARK: - Quitting

    private(set) var isQuitting = false
    var pendingCloses = 0
    private var quitCompletion: (() -> Void)?

    // Quitting looks instant: the state is saved and every window disappears
    // at once, then the browsers close behind the scenes. Chromium only lets
    // the message loop end once they have; a tab that never answers gets a
    // couple of seconds.
    func prepareToQuit(_ completion: @escaping () -> Void) {
        guard !isQuitting else { return }
        isQuitting = true
        save()
        closeCommandBar()
        for tab in liveTabs.values {
            if let native = tab.nativeWindow {
                if native.parent != nil { window.removeChildWindow(native) }
                native.orderOut(nil)
            }
        }
        window?.orderOut(nil)
        Diagnostics.mark("windows-hidden")

        quitCompletion = completion
        let little = LittleWindowController.open
        for item in little { item.window.orderOut(nil) }
        let peekTabs = peek.flatMap { $0.closed ? nil : $0.tab }.map { [$0] } ?? []
        pendingCloses = liveTabs.count + little.count + peekTabs.count
        let tabs = Array(liveTabs.values) + little.compactMap(\.tab) + peekTabs
        if tabs.isEmpty { finishQuit() }
        for tab in tabs { tab.close() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.finishQuit()
        }
    }

    func finishQuit() {
        guard let completion = quitCompletion else { return }
        quitCompletion = nil
        Diagnostics.mark("browsers-closed")
        completion()
    }

    // MARK: - Tabs

    var activeSpace: SpaceData {
        get { spaces.first { $0.id == activeSpaceID } ?? spaces[0] }
        set {
            guard let index = spaces.firstIndex(where: { $0.id == newValue.id })
            else { return }
            spaces[index] = newValue
            scheduleSave()
        }
    }

    var activeTabID: UUID? { activeSpace.activeTabID }

    // New tabs go to the top of today's list, as in Arc.
    func newTab(url: String = "about:blank", pinned: Bool = false) {
        var space = activeSpace
        let tab = TabData(url: url, isPinned: pinned)
        let firstUnpinned = space.tabs.firstIndex { !$0.isPinned } ?? space.tabs.count
        space.tabs.insert(tab, at: firstUnpinned)
        space.activeTabID = tab.id
        activeSpace = space
        activateTab(tab.id)
        if url == "about:blank" { focusAddressBar() }
    }

    func activateTab(_ id: UUID?, transition: PageTransition = .fade) {
        if id != activeTabID {
            closeFindBar()
            peek?.close()
            pictureInPictureForSwitch(from: activeTabID, to: id)
        }
        guard let id, let data = tabData(id) else {
            hideAllTabs()
            addressText = ""
            canGoBack = false
            canGoForward = false
            return
        }
        var space = activeSpace
        space.activeTabID = id
        activeSpace = space
        update(tabID: id) { $0.lastActive = Date() }
        addressText = data.url

        let tab = liveTab(id, url: data.url)
        refreshKeepsSite(id)
        contentWell?.isHidden = false
        showOnly(tabID: id, transition: transition)
        canGoBack = tab.canGoBack
        canGoForward = tab.canGoForward
        window?.title = data.displayTitle
        if tab.nativeWindow != nil, !Diagnostics.quiet { tab.focus() }
    }

    // Tabs restored from disk have no browser yet; one is made on demand.
    // The profile a tab opens in: its space's; a favourite, the open space's.
    func profileKey(for id: UUID) -> String? {
        let space = spaceContaining(id) ?? activeSpace
        return space.profileID?.uuidString
    }

    @discardableResult
    func liveTab(_ id: UUID, url: String) -> ChaTab {
        let profile = profileKey(for: id)
        if let existing = liveTabs[id] {
            if existing.profileID == profile { return existing }
            // A favourite opened from a space with another profile loads
            // again in that profile.
            unload(id)
        }
        let tab = ChaTab(url: url, screenFrame: contentScreenRect, profile: profile)
        register(tab, as: id)
        Diagnostics.mark("first-tab-created")
        return tab
    }

    func register(_ tab: ChaTab, as id: UUID) {
        tab.delegate = self
        tab.setCornerRadius(pageCornerRadius)
        liveTabs[id] = tab
        tabIDsByObject[ObjectIdentifier(tab)] = id
        pin(tab)
    }

    // A page may resize or move its own window (window.resizeTo); the shown
    // one snaps back to the content area, the hidden ones don't matter.
    func pin(_ tab: ChaTab) {
        guard let native = tab.nativeWindow else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak tab] in
                if let self, let tab, self.liveTabs.values.contains(where: { $0 === tab }) { self.pin(tab) }
            }
            return
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: native, queue: .main) {
                [weak self, weak native] _ in
                guard let self, let native, !self.pinning, native === self.activeTab?.nativeWindow,
                    native.parent != nil, !self.pageAnimating, !self.sidebarAnimating,
                    self.window?.inLiveResize == false,
                    native.alphaValue > 0.99
                else { return }
                let target = self.contentScreenRect
                // Chromium rounds frames: only a real move counts, and the
                // fix-up itself doesn't come back here.
                guard !native.frame.isClose(to: target) else { return }
                self.pinning = true
                native.setFrame(target, display: true)
                self.pinning = false
            }
        }
    }

    // A little window's page closed while quitting counts towards the wait.
    func littleTabClosed() {
        guard isQuitting else { return }
        pendingCloses -= 1
        if pendingCloses <= 0 { finishQuit() }
    }

    // How the page changes: never a cut, never a show. A tab crossfades in
    // 100 ms, a space's page in 150 ms while the sidebar slides.
    enum PageTransition: Equatable {
        case none
        case fade
        case slide(forward: Bool)
    }

    // The page doesn't travel: moving it drew the eye away from the sidebar.
    static let slideDistance: CGFloat = 0

    func showOnly(tabID: UUID, transition: PageTransition = .none) {
        guard let window else { return }
        let target = contentScreenRect
        var incoming: NSWindow?
        var outgoing: [NSWindow] = []
        for (id, tab) in liveTabs {
            guard let native = tab.nativeWindow else { continue }
            if id == tabID {
                incoming = native
            } else if native.parent != nil || native.isVisible {
                outgoing.append(native)
            }
        }
        guard let incoming else {
            for native in outgoing { hidePage(native) }
            return
        }
        let wasShown = incoming.parent === window && incoming.isVisible && incoming.alphaValue > 0.99
        let animate = transition != .none && !wasShown && !outgoing.isEmpty
        if incoming.parent !== window { window.addChildWindow(incoming, ordered: .above) }

        guard animate else {
            incoming.alphaValue = 1
            incoming.setFrame(target, display: true)
            front(incoming)
            for native in outgoing { hidePage(native) }
            return
        }

        var dx: CGFloat = 0
        if case .slide(let forward) = transition { dx = forward ? Self.slideDistance : -Self.slideDistance }
        incoming.alphaValue = 0
        incoming.setFrame(target.offsetBy(dx: dx, dy: 0), display: true)
        front(incoming)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = transition == .fade ? 0.1 : Self.switchDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            incoming.animator().alphaValue = 1
            if dx != 0 { incoming.animator().setFrame(target, display: true) }
            for native in outgoing {
                native.animator().alphaValue = 0
                if dx != 0 {
                    native.animator().setFrame(native.frame.offsetBy(dx: -dx, dy: 0), display: true)
                }
            }
        } completionHandler: { [weak self] in
            guard let self else { return }
            for native in outgoing where native !== self.activeTab?.nativeWindow {
                self.hidePage(native)
            }
            incoming.alphaValue = 1
        }
    }

    private func front(_ native: NSWindow) {
        if Diagnostics.quiet { native.orderFront(nil) } else { native.makeKeyAndOrderFront(nil) }
    }

    private func hidePage(_ native: NSWindow) {
        if native.parent != nil { window?.removeChildWindow(native) }
        native.orderOut(nil)
        native.alphaValue = 1
    }

    // The space's page slides in as the sidebar starts sliding, not after.
    func revealSpace(_ spaceID: UUID, forward: Bool) {
        guard let space = space(spaceID),
            let id = space.activeTabID,
            let data = tabData(id)
        else {
            hideAllTabs()
            return
        }
        liveTab(id, url: data.url)
        showOnly(tabID: id, transition: .slide(forward: forward))
    }

    // Nothing open: no page, no card, just the window's colour.
    var nothingOpen: Bool { activeTab == nil }

    private func hideAllTabs() {
        contentWell?.isHidden = true
        for tab in liveTabs.values {
            guard let native = tab.nativeWindow else { continue }
            if native.parent != nil { window.removeChildWindow(native) }
            native.orderOut(nil)
        }
    }

    // Drops a tab's browser but keeps the tab: what ⌘W does to pinned tabs
    // and favourites in Arc.
    func unload(_ id: UUID) {
        guard let tab = liveTabs.removeValue(forKey: id) else { return }
        tabIDsByObject.removeValue(forKey: ObjectIdentifier(tab))
        if let native = tab.nativeWindow, native.parent != nil {
            window.removeChildWindow(native)
        }
        tab.end("tab")
        loadingTabs.remove(id)
    }

    func isLoaded(_ id: UUID) -> Bool { liveTabs[id] != nil }

    // ⌘W: unpinned tabs go to the archive; pinned ones and favourites are
    // only unloaded and stay where they are.
    func closeTab(_ id: UUID) {
        if favorites.contains(where: { $0.id == id }) || tabData(id)?.isPinned == true {
            unload(id)
            if activeSpace.activeTabID == id { activateNeighbor(of: id, in: activeSpace) }
            return
        }
        guard var space = spaceContaining(id),
            let index = space.tabs.firstIndex(where: { $0.id == id })
        else { return }
        unload(id)
        recentlyClosed.append(ClosedTab(tab: space.tabs[index], spaceID: space.id, index: index))
        space.tabs.remove(at: index)
        if space.activeTabID == id {
            // The next tab below, or above when it was the last one.
            let unpinned = space.tabs.filter { !$0.isPinned }
            let next = space.tabs[index...].first { !$0.isPinned } ?? unpinned.last
            space.activeTabID = next?.id
        }
        replace(space)
        if space.id == activeSpaceID { activateTab(space.activeTabID) }
    }

    // After ⌘W: the next of today's tabs, or nothing open at all. Pinned tabs
    // and favourites are never opened on their own (closing one after another
    // used to cycle through them forever).
    private func activateNeighbor(of id: UUID, in space: SpaceData) {
        let next = space.unpinnedTabs.first { $0.id != id }
        var space = space
        space.activeTabID = next?.id
        replace(space)
        activateTab(next?.id)
    }

    // ⌘1…⌘9: favourites, then pinned tabs, then today's, as the sidebar
    // lists them.
    func activateTabAtIndex(_ index: Int) {
        let space = activeSpace
        let ordered = favorites + space.pinnedTabs + space.unpinnedTabs
        guard ordered.indices.contains(index) else { return }
        activateTab(ordered[index].id)
    }

    func closeActiveTab() {
        if let id = activeSpace.activeTabID { closeTab(id) }
    }

    // ⌘⇧T: the last tab ⌘W (or Clear) took away comes back where it was, in
    // its own space, with its name and folder. Only the page's address
    // survives, not its back/forward history. Kept for this run only.
    struct ClosedTab {
        var tab: TabData
        var spaceID: UUID
        var index: Int
    }
    var recentlyClosed: [ClosedTab] = [] {
        didSet { if recentlyClosed.count > 50 { recentlyClosed.removeFirst() } }
    }

    func reopenClosedTab() {
        guard let closed = recentlyClosed.popLast() else {
            NSSound.beep()
            return
        }
        var tab = closed.tab
        if tabData(tab.id) != nil { tab.id = UUID() }  // already back some other way
        if tab.folderID != nil,
            !(spaces.first { $0.id == closed.spaceID }?.folders.contains { $0.id == tab.folderID } ?? false)
        {
            tab.folderID = nil
        }
        let home = spaces.contains { $0.id == closed.spaceID } ? closed.spaceID : activeSpaceID
        if home != activeSpaceID { selectSpace(home, animated: false) }
        var space = activeSpace
        // Today's tabs never go above the pinned ones.
        let firstUnpinned = space.tabs.firstIndex { !$0.isPinned } ?? space.tabs.count
        let index = min(max(closed.index, tab.isPinned ? 0 : firstUnpinned), space.tabs.count)
        space.tabs.insert(tab, at: index)
        space.activeTabID = tab.id
        activeSpace = space
        sidebarPage = .tabs
        activateTab(tab.id)
    }

    // Drag and drop in the sidebar: reorder, pinning or unpinning the tab to
    // match where it lands.
    func moveTab(_ id: UUID, before targetID: UUID) {
        guard id != targetID else { return }
        if favorites.contains(where: { $0.id == targetID }) {
            addToFavorites(id, before: targetID)
            return
        }
        guard var tab = takeTab(id), var space = spaceContaining(targetID),
            let target = space.tabs.first(where: { $0.id == targetID })
        else { return }
        tab.isPinned = target.isPinned
        tab.folderID = target.folderID
        if tab.isPinned, tab.pinnedURL == nil { tab.pinnedURL = tab.url }
        let to = space.tabs.firstIndex { $0.id == targetID } ?? space.tabs.count
        space.tabs.insert(tab, at: to)
        replace(space)
    }

    // Drop on the pinned or today section itself, after the last tab there.
    func moveTab(_ id: UUID, toSection pinned: Bool, folder: UUID? = nil) {
        guard var tab = takeTab(id) else { return }
        var space = activeSpace
        tab.isPinned = pinned
        tab.folderID = pinned ? folder : nil
        if pinned, tab.pinnedURL == nil { tab.pinnedURL = tab.url }
        if pinned {
            let lastPinned = space.tabs.lastIndex { $0.isPinned && $0.folderID == folder }
            let firstToday = space.tabs.firstIndex { !$0.isPinned } ?? space.tabs.count
            space.tabs.insert(tab, at: lastPinned.map { $0 + 1 } ?? firstToday)
        } else {
            let firstToday = space.tabs.firstIndex { !$0.isPinned } ?? space.tabs.count
            space.tabs.insert(tab, at: firstToday)
        }
        if space.activeTabID == nil { space.activeTabID = tab.id }
        replace(space)
    }

    // Removes a tab from wherever it is (a space or the favourites) without
    // touching its browser, so it can be put somewhere else.
    private func takeTab(_ id: UUID) -> TabData? {
        if let index = favorites.firstIndex(where: { $0.id == id }) {
            let tab = favorites.remove(at: index)
            scheduleSave()
            return tab
        }
        guard var space = spaceContaining(id),
            let index = space.tabs.firstIndex(where: { $0.id == id })
        else { return nil }
        let tab = space.tabs.remove(at: index)
        replace(space)
        return tab
    }

    func moveTab(_ id: UUID, toSpace spaceID: UUID) {
        guard spaces.contains(where: { $0.id == spaceID }),
            spaceContaining(id)?.id != spaceID
        else { return }
        let wasActive = activeSpace.activeTabID == id
        guard var tab = takeTab(id),
            var destination = spaces.first(where: { $0.id == spaceID })
        else { return }
        tab.folderID = nil
        let firstToday = destination.tabs.firstIndex { !$0.isPinned } ?? destination.tabs.count
        destination.tabs.insert(tab, at: firstToday)
        if destination.activeTabID == nil { destination.activeTabID = tab.id }
        replace(destination)
        if wasActive {
            // The tab's window belongs to the other space now.
            var space = activeSpace
            space.activeTabID = space.unpinnedTabs.first?.id
            replace(space)
            activateTab(space.activeTabID)
        }
    }

    func togglePin(_ id: UUID) {
        if favorites.contains(where: { $0.id == id }) {
            removeFromFavorites(id)
            return
        }
        guard var space = spaceContaining(id),
            let index = space.tabs.firstIndex(where: { $0.id == id })
        else { return }
        var tab = space.tabs.remove(at: index)
        tab.isPinned.toggle()
        tab.folderID = nil
        tab.pinnedURL = tab.isPinned ? tab.url : nil
        let firstToday = space.tabs.firstIndex { !$0.isPinned } ?? space.tabs.count
        space.tabs.insert(tab, at: firstToday)
        replace(space)
        refreshKeepsSite(id)
    }

    func addToFavorites(_ id: UUID, before targetID: UUID? = nil) {
        guard var tab = takeTab(id) else { return }
        tab.isPinned = true
        tab.folderID = nil
        tab.pinnedURL = tab.pinnedURL ?? tab.url
        let index = targetID.flatMap { t in favorites.firstIndex { $0.id == t } } ?? favorites.count
        favorites.insert(tab, at: index)
        scheduleSave()
        refreshKeepsSite(id)
    }

    // A favourite that is let go becomes a pinned tab of the current space.
    func removeFromFavorites(_ id: UUID) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        var tab = favorites.remove(at: index)
        tab.isPinned = true
        var space = activeSpace
        let firstToday = space.tabs.firstIndex { !$0.isPinned } ?? space.tabs.count
        space.tabs.insert(tab, at: firstToday)
        replace(space)
    }

    func resetToPinnedURL(_ id: UUID) {
        guard let pinned = tabData(id)?.pinnedURL else { return }
        update(tabID: id) { $0.url = pinned }
        if let tab = liveTabs[id] { tab.loadURL(pinned) }
        if activeSpace.activeTabID == id { addressText = pinned }
    }

    // Renaming a tab; an empty name gives it back the page's title.
    func renameTab(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(tabID: id) { $0.customTitle = name.isEmpty ? nil : name }
        if activeTabID == id, let tab = tabData(id) { window?.title = tab.displayTitle }
    }

    func duplicateTab(_ id: UUID) {
        guard let tab = tabData(id) else { return }
        newTab(url: tab.url)
    }

    func copyLink(_ id: UUID? = nil) {
        guard let id = id ?? activeSpace.activeTabID, let tab = tabData(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(liveTabs[id]?.currentURL ?? tab.url, forType: .string)
    }

    func navigate(to input: String) {
        let url = normalizedURL(from: input)
        guard let id = activeSpace.activeTabID else {
            newTab(url: url)
            return
        }
        addressText = url
        if let tab = liveTabs[id] {
            tab.loadURL(url)
        } else {
            update(tabID: id) { $0.url = url }
            activateTab(id)
        }
    }

    var activeTab: ChaTab? {
        guard let id = activeSpace.activeTabID else { return nil }
        return liveTabs[id]
    }

    func goBack() { activeTab?.goBack() }
    func goForward() { activeTab?.goForward() }
    func reload() { activeTab?.reload() }

    func focusAddressBar() {
        if !sidebarVisible { toggleSidebar() }
        openCommandBar(mode: .current)
    }

    // Dragging the sidebar's right edge.
    // The sidebar keeps its share of the window: dragging its edge sets the
    // share, resizing the window (or full screen) scales the sidebar with it.
    var sidebarFraction: CGFloat = 0.176

    func setSidebarWidth(_ width: CGFloat) {
        applySidebarWidth(width)
        if let windowWidth = window?.frame.width, windowWidth > 0 {
            sidebarFraction = sidebarWidth / windowWidth
        }
        scheduleSave()
    }

    private func applySidebarWidth(_ width: CGFloat) {
        sidebarWidth = min(max(width.rounded(), Self.minSidebarWidth), Self.maxSidebarWidth)
        sidebarWidthConstraint?.constant = sidebarWidth
        layoutActiveTab()
    }

    func followWindowWidth() {
        guard let windowWidth = window?.frame.width, windowWidth > 0 else { return }
        let target = (sidebarFraction * windowWidth).rounded()
        if abs(target - sidebarWidth) >= 1 { applySidebarWidth(target) }
    }

    // The sidebar slides out to the left while the page widens into its
    // place, and back, in 150 ms on an ease-out curve (quick start, soft
    // landing). One frame clock drives both: on every display refresh the
    // sidebar's offset and the page's frame are set from the same eased
    // progress (two separate AppKit animations drifted apart and stuttered).
    // The page's shape (card or whole screen) and the traffic lights change
    // at the start.
    func toggleSidebar(animated: Bool = true) {
        let showing = !sidebarVisible
        guard animated, let sidebar = sidebarView, let leading = sidebarLeadingConstraint, window != nil
        else {
            stopSidebarSlide()
            sidebarLeadingConstraint?.constant = 0
            sidebarVisible = showing
            sidebarView?.isHidden = !showing
            updateTrafficLights()
            applyPageShape()
            window?.contentView?.layoutSubtreeIfNeeded()
            layoutActiveTab()
            return
        }
        // Mid-slide toggles start from where the sidebar is now.
        let fromOffset = sidebarAnimating ? leading.constant : (showing ? -sidebarWidth : 0)
        let page = activeTab?.nativeWindow
        let fromPage = page?.frame ?? .zero
        stopSidebarSlide()
        leading.constant = fromOffset
        sidebar.isHidden = false
        sidebarVisible = showing
        updateTrafficLights()
        applyPageShape()
        repositionFindBar()
        peek?.layout()
        sidebarSlide = SidebarSlide(
            start: CACurrentMediaTime(), fromOffset: fromOffset, toOffset: showing ? 0 : -sidebarWidth,
            fromPage: fromPage, toPage: contentScreenRect, page: page)
        sidebarAnimating = true
        if Diagnostics.headless || window.screen == nil {
            // Off screen there is no display to sync to: a 120 Hz timer.
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.sidebarTick() }
            RunLoop.main.add(timer, forMode: .common)
            sidebarTimer = timer
        } else {
            let link = window.displayLink(target: self, selector: #selector(sidebarFrame(_:)))
            link.add(to: .main, forMode: .common)
            sidebarLink = link
        }
        sidebarTick()
    }

    struct SidebarSlide {
        let start: CFTimeInterval
        let fromOffset: CGFloat, toOffset: CGFloat
        let fromPage: NSRect, toPage: NSRect
        weak var page: NSWindow?
    }
    private var sidebarSlide: SidebarSlide?
    private var sidebarLink: CADisplayLink?
    private var sidebarTimer: Timer?

    @objc private func sidebarFrame(_ link: CADisplayLink) { sidebarTick() }

    // Ease-out cubic: most of the way early, settling gently.
    static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    private func sidebarTick() {
        guard let slide = sidebarSlide, let leading = sidebarLeadingConstraint else { return }
        let t = min(1, (CACurrentMediaTime() - slide.start) / Self.sidebarDuration)
        let e = CGFloat(Self.easeOut(t))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * e }
        leading.constant = mix(slide.fromOffset, slide.toOffset)
        window?.contentView?.layoutSubtreeIfNeeded()
        if let page = slide.page, slide.fromPage != .zero {
            let f = NSRect(
                x: mix(slide.fromPage.minX, slide.toPage.minX), y: mix(slide.fromPage.minY, slide.toPage.minY),
                width: mix(slide.fromPage.width, slide.toPage.width),
                height: mix(slide.fromPage.height, slide.toPage.height))
            page.setFrame(f.integral, display: true)
        }
        sidebarProgress.append(Double(e))
        if t >= 1 { NSLog("SIDEBAR slide: %d frames (%@)", sidebarProgress.count, sidebarLink != nil ? "display link" : "timer") }
        if t >= 1 { finishSidebarSlide() }
    }

    private func finishSidebarSlide() {
        stopSidebarSlide()
        sidebarLeadingConstraint?.constant = 0
        if !sidebarVisible { sidebarView?.isHidden = true }
        layoutActiveTab()
    }

    private func stopSidebarSlide() {
        sidebarLink?.invalidate()
        sidebarLink = nil
        sidebarTimer?.invalidate()
        sidebarTimer = nil
        sidebarSlide = nil
        sidebarAnimating = false
    }

    // Eased progress of each frame of the last slide (the checks).
    var sidebarProgress: [Double] = []

    func toggleFullscreen() { window.toggleFullScreen(nil) }

    // MARK: - Archive

    func addToArchive(_ tab: TabData, spaceID: UUID?) {
        guard !tab.url.isEmpty, tab.url != "about:blank" else { return }
        archive.insert(
            ArchivedTab(url: tab.url, title: tab.displayTitle, spaceID: spaceID), at: 0)
        if archive.count > 500 { archive.removeLast(archive.count - 500) }
        scheduleSave()
    }

    // Arc's "Clear": today's tabs of the space go to the archive.
    func clearToday(_ spaceID: UUID? = nil) {
        guard var space = spaces.first(where: { $0.id == (spaceID ?? activeSpaceID) })
        else { return }
        for tab in space.unpinnedTabs.reversed() {
            unload(tab.id)
            let index = space.tabs.firstIndex { $0.id == tab.id } ?? space.tabs.count
            recentlyClosed.append(ClosedTab(tab: tab, spaceID: space.id, index: index))
        }
        space.tabs.removeAll { !$0.isPinned }
        if let active = space.activeTabID, !space.tabs.contains(where: { $0.id == active }),
            !favorites.contains(where: { $0.id == active })
        {
            space.activeTabID = nil
        }
        replace(space)
        if space.id == activeSpaceID { activateTab(space.activeTabID) }
    }

    func restoreArchived(_ id: UUID) {
        guard let index = archive.firstIndex(where: { $0.id == id }) else { return }
        let item = archive.remove(at: index)
        if let spaceID = item.spaceID, spaceID != activeSpaceID,
            spaces.contains(where: { $0.id == spaceID })
        {
            selectSpace(spaceID, animated: false)
        }
        newTab(url: item.url)
        update(tabID: activeSpace.activeTabID ?? UUID()) { $0.title = item.title }
        sidebarPage = .tabs
    }

    // Unpinned tabs nobody looked at for 12 hours, except the open one.
    private func archiveStaleTabs() {
        let cutoff = Date().addingTimeInterval(-Self.archiveAfter)
        for index in spaces.indices {
            var space = spaces[index]
            let stale = space.tabs.filter {
                !$0.isPinned && $0.id != space.activeTabID
                    && ($0.lastActive ?? .distantPast) < cutoff
            }
            guard !stale.isEmpty else { continue }
            for tab in stale { addToArchive(tab, spaceID: space.id) }
            let ids = Set(stale.map(\.id))
            space.tabs.removeAll { ids.contains($0.id) }
            spaces[index] = space
        }
        // Tabs from before lastActive existed start counting now.
        for s in spaces.indices {
            for t in spaces[s].tabs.indices where spaces[s].tabs[t].lastActive == nil {
                spaces[s].tabs[t].lastActive = Date()
            }
        }
    }

    // MARK: - Favicons

    private func loadSavedFavicons() {
        var cache: [String: NSImage] = [:]
        for tab in favorites + spaces.flatMap(\.tabs) {
            guard let host = tab.host else { continue }
            if cache[host] == nil { cache[host] = FaviconStore.load(host: host) }
            if let icon = cache[host] { favicons[tab.id] = icon }
        }
    }

    // MARK: - ChaTabDelegate

    func tabDidBecomeReady(_ tab: ChaTab) {
        guard let id = tabIDsByObject[ObjectIdentifier(tab)] else { return }
        if activeSpace.activeTabID == id {
            showOnly(tabID: id)
            if !Diagnostics.quiet { tab.focus() }
        } else if let native = tab.nativeWindow {
            native.orderOut(nil)
        }
    }

    func tabDidUpdate(_ tab: ChaTab) {
        guard let id = tabIDsByObject[ObjectIdentifier(tab)] else { return }
        update(tabID: id) {
            if !tab.title.isEmpty { $0.title = tab.title }
            $0.url = tab.currentURL
        }
        if let icon = tab.favicon, favicons[id] !== icon {
            favicons[id] = icon
            if let host = URL(string: tab.currentURL)?.host { FaviconStore.save(icon, host: host) }
        }
        if tab.isLoading { loadingTabs.insert(id) } else { loadingTabs.remove(id) }
        if activeSpace.activeTabID == id {
            addressText = tab.currentURL
            canGoBack = tab.canGoBack
            canGoForward = tab.canGoForward
            window?.title = tab.title.isEmpty ? "cha" : tab.title
        }
    }

    func tabDidFinishLoad(_ tab: ChaTab) {
        Diagnostics.mark("first-load-end")
        guard let id = tabIDsByObject[ObjectIdentifier(tab)],
            activeSpace.activeTabID == id
        else { return }
        autofillVerificationCode(in: tab)
    }

    func tab(_ tab: ChaTab, requestsNewTabWithURL url: String) {
        NSLog("TAB opened in front: %@", url)
        newTab(url: url)
    }

    // ⌘-click, Open Link in New Tab: the tab goes into today's list (at the
    // top, as new tabs do) and loads when opened; this page stays in front.
    func tab(_ tab: ChaTab, requestsBackgroundTabWithURL url: String) {
        var space = activeSpace
        let data = TabData(url: url)
        let firstToday = space.tabs.firstIndex { !$0.isPinned } ?? space.tabs.count
        space.tabs.insert(data, at: firstToday)
        replace(space)
        NSLog("TAB opened in the background: %@", url)
    }

    func tabDidClose(_ tab: ChaTab) {
        if isQuitting {
            // The tab stays in the saved state; only its browser went away.
            pendingCloses -= 1
            if pendingCloses <= 0 { finishQuit() }
            return
        }
        // Unloading already forgot the tab; only a page closing itself
        // (window.close()) arrives here with the tab still known.
        guard let id = tabIDsByObject[ObjectIdentifier(tab)] else { return }
        liveTabs.removeValue(forKey: id)
        tabIDsByObject.removeValue(forKey: ObjectIdentifier(tab))
        closeTab(id)
    }

    // MARK: - State helpers

    func tabData(_ id: UUID) -> TabData? {
        favorites.first { $0.id == id } ?? spaces.lazy.flatMap(\.tabs).first { $0.id == id }
    }

    func spaceContaining(_ id: UUID) -> SpaceData? {
        spaces.first { $0.tabs.contains { $0.id == id } }
    }

    func replace(_ space: SpaceData) {
        guard let index = spaces.firstIndex(where: { $0.id == space.id })
        else { return }
        spaces[index] = space
        scheduleSave()
    }

    func update(tabID: UUID, _ body: (inout TabData) -> Void) {
        if let index = favorites.firstIndex(where: { $0.id == tabID }) {
            body(&favorites[index])
            scheduleSave()
            return
        }
        for spaceIndex in spaces.indices {
            guard
                let tabIndex = spaces[spaceIndex].tabs.firstIndex(where: {
                    $0.id == tabID
                })
            else { continue }
            body(&spaces[spaceIndex].tabs[tabIndex])
            scheduleSave()
            return
        }
    }

    func scheduleSave() {
        guard !saveScheduled, !isQuitting else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    func save() {
        Persistence.save(
            BrowserState(
                spaces: spaces, activeSpaceID: activeSpaceID,
                sidebarWidth: Double(sidebarWidth), sidebarFraction: Double(sidebarFraction),
                favorites: favorites,
                archive: archive, profiles: profiles))
    }
}
