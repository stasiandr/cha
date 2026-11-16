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
        case archive
    }
    @Published var sidebarPage: SidebarPage = .tabs

    // Space paging: how far the space's page is dragged sideways (points,
    // positive = towards the previous space) and which space sits next to it.
    @Published var pageOffset: CGFloat = 0
    @Published var pageNeighbor: (left: UUID?, right: UUID?) = (nil, nil)
    var pageAnimating = false
    var pageGeneration = 0

    @Published var sidebarWidth: CGFloat = 250
    static let minSidebarWidth: CGFloat = 180
    static let maxSidebarWidth: CGFloat = 420
    static let contentInset: CGFloat = 8
    // Unpinned tabs left alone this long go to the archive at launch.
    static let archiveAfter: TimeInterval = 12 * 3600

    var window: NSWindow!
    var sidebarView: NSView?
    private var tintView: NSView?  // The space's colour behind everything.
    private var contentWell: NSView?  // Drops a shadow under the page card.
    lazy var sidebarWidthConstraint: NSLayoutConstraint = {
        let constraint = NSLayoutConstraint(
            item: sidebarView as Any, attribute: .width, relatedBy: .equal,
            toItem: nil, attribute: .notAnAttribute, multiplier: 1,
            constant: sidebarWidth)
        return constraint
    }()
    var commandPanel: CommandPanel?
    var commandMode: CommandMode = .newTab
    var commandKeyMonitor: Any?
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
        let saved = state.activeSpaceID
        activeSpaceID =
            state.spaces.contains { $0.id == saved } ? saved! : state.spaces[0].id
        sidebarWidth = CGFloat(state.sidebarWidth ?? 250)
        super.init()
        archiveStaleTabs()
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
        window.delegate = self
        window.minSize = NSSize(width: 700, height: 420)
        window.setFrameAutosaveName("cha.main")

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
        sidebarView = sidebar
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: background.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            sidebarWidthConstraint,
        ])

        if Diagnostics.headless {
            window.setFrameOrigin(Diagnostics.offscreenOrigin)
            window.orderFront(nil)
        } else {
            if window.frame.origin == .zero { window.center() }
            window.makeKeyAndOrderFront(nil)
        }
        self.window = window
        Diagnostics.mark("window")
        applySpaceTint()
        installSwipeMonitor()
        appearanceObservation = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applySpaceTint(animated: false) }
        }

        activateTab(activeSpace.activeTabID ?? activeSpace.tabs.first?.id)
    }

    static let contentCornerRadius: CGFloat = 12

    // Where a tab's window sits, in the main window's own coordinates.
    var contentLocalRect: NSRect {
        guard let content = window?.contentView else { return .zero }
        let inset = Self.contentInset
        let left = sidebarVisible ? sidebarWidth : inset
        let top = isFullscreen ? inset : 0  // The titlebar area stays clickable.
        return NSRect(
            x: left, y: inset,
            width: max(content.bounds.width - left - inset, 100),
            height: max(content.bounds.height - inset - top - inset, 100))
    }

    // The same rectangle in screen coordinates, where a CEF window lives.
    var contentScreenRect: NSRect {
        guard window != nil else { return .zero }
        return window.convertToScreen(contentLocalRect)
    }

    private func layoutActiveTab() {
        layoutContentWell()
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
        let radius = Self.contentCornerRadius
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

    func windowDidResize(_ notification: Notification) { layoutActiveTab() }
    func windowDidMove(_ notification: Notification) { layoutActiveTab() }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isFullscreen = true
        layoutActiveTab()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullscreen = false
        layoutActiveTab()
    }

    // Closing the only window quits, the same way ⌘Q does.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    // MARK: - Quitting

    private(set) var isQuitting = false
    private var pendingCloses = 0
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
        pendingCloses = liveTabs.count
        let tabs = Array(liveTabs.values)
        if tabs.isEmpty { finishQuit() }
        for tab in tabs { tab.close() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.finishQuit()
        }
    }

    private func finishQuit() {
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

    func activateTab(_ id: UUID?) {
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

        // Tabs restored from disk have no browser yet; create one on demand.
        let tab: ChaTab
        if let existing = liveTabs[id] {
            tab = existing
        } else {
            tab = ChaTab(url: data.url, screenFrame: contentScreenRect)
            tab.delegate = self
            liveTabs[id] = tab
            tabIDsByObject[ObjectIdentifier(tab)] = id
            Diagnostics.mark("first-tab-created")
        }
        showOnly(tabID: id)
        canGoBack = tab.canGoBack
        canGoForward = tab.canGoForward
        window?.title = data.displayTitle
        if tab.nativeWindow != nil, !Diagnostics.headless { tab.focus() }
    }

    func showOnly(tabID: UUID) {
        for (id, tab) in liveTabs {
            guard let native = tab.nativeWindow else { continue }
            if id == tabID {
                if native.parent !== window {
                    window.addChildWindow(native, ordered: .above)
                }
                native.setFrame(contentScreenRect, display: true)
                if Diagnostics.headless {
                    native.orderFront(nil)
                } else {
                    native.makeKeyAndOrderFront(nil)
                }
            } else if native.parent != nil || native.isVisible {
                if native.parent != nil { window.removeChildWindow(native) }
                native.orderOut(nil)
            }
        }
    }

    private func hideAllTabs() {
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
        tab.close()
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
        let tab = space.tabs.remove(at: index)
        addToArchive(tab, spaceID: space.id)
        if space.activeTabID == id {
            // The next tab below, or above when it was the last one.
            let unpinned = space.tabs.filter { !$0.isPinned }
            let next = space.tabs[index...].first { !$0.isPinned } ?? unpinned.last
            space.activeTabID = next?.id
        }
        replace(space)
        if space.id == activeSpaceID { activateTab(space.activeTabID) }
    }

    private func activateNeighbor(of id: UUID, in space: SpaceData) {
        let next = space.unpinnedTabs.first ?? space.pinnedTabs.first { $0.id != id }
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
            space.activeTabID = space.unpinnedTabs.first?.id ?? space.pinnedTabs.first?.id
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
    }

    func addToFavorites(_ id: UUID, before targetID: UUID? = nil) {
        guard var tab = takeTab(id) else { return }
        tab.isPinned = true
        tab.folderID = nil
        tab.pinnedURL = tab.pinnedURL ?? tab.url
        let index = targetID.flatMap { t in favorites.firstIndex { $0.id == t } } ?? favorites.count
        favorites.insert(tab, at: index)
        scheduleSave()
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
    func setSidebarWidth(_ width: CGFloat) {
        sidebarWidth = min(max(width, Self.minSidebarWidth), Self.maxSidebarWidth)
        sidebarWidthConstraint.constant = sidebarWidth
        layoutActiveTab()
        scheduleSave()
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
        sidebarView?.isHidden = !sidebarVisible
        layoutActiveTab()
    }

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
        for tab in space.unpinnedTabs {
            unload(tab.id)
            addToArchive(tab, spaceID: space.id)
        }
        space.tabs.removeAll { !$0.isPinned }
        if let active = space.activeTabID, !space.tabs.contains(where: { $0.id == active }),
            !favorites.contains(where: { $0.id == active })
        {
            space.activeTabID = space.pinnedTabs.first?.id
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
            tab.focus()
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
        newTab(url: url)
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
                sidebarWidth: Double(sidebarWidth), favorites: favorites,
                archive: archive))
    }
}
