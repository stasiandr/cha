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

    @Published var sidebarWidth: CGFloat = 250
    static let minSidebarWidth: CGFloat = 180
    static let maxSidebarWidth: CGFloat = 420
    static let contentInset: CGFloat = 8

    var window: NSWindow!
    var sidebarView: NSView?
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
    private var liveTabs: [UUID: ChaTab] = [:]
    private var tabIDsByObject: [ObjectIdentifier: UUID] = [:]
    private var saveScheduled = false

    override init() {
        let state = Persistence.load()
        spaces = state.spaces
        activeSpaceID = state.activeSpaceID ?? state.spaces[0].id
        sidebarWidth = CGFloat(state.sidebarWidth ?? 250)
        super.init()
    }

    // MARK: - Window

    func showWindow() {
        let window = NSWindow(
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

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        window.contentView = background

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

        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        activateTab(activeSpace.activeTabID ?? activeSpace.tabs.first?.id)
    }

    // Where a tab's window sits, in screen coordinates.
    var contentScreenRect: NSRect {
        guard let content = window?.contentView else { return .zero }
        let inset = Self.contentInset
        let left = sidebarVisible ? sidebarWidth : inset
        let top = isFullscreen ? inset : 0  // The titlebar area stays clickable.
        let local = NSRect(
            x: left, y: inset,
            width: max(content.bounds.width - left - inset, 100),
            height: max(content.bounds.height - inset - top - inset, 100))
        return window.convertToScreen(local)
    }

    private func layoutActiveTab() {
        guard let id = activeSpace.activeTabID, let tab = liveTabs[id],
            let native = tab.nativeWindow
        else { return }
        native.setFrame(contentScreenRect, display: true)
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        save()
        for tab in liveTabs.values { tab.close() }
        ChaEngine.shared.quit()
        return true
    }

    // MARK: - Spaces

    var activeSpace: SpaceData {
        get { spaces.first { $0.id == activeSpaceID } ?? spaces[0] }
        set {
            guard let index = spaces.firstIndex(where: { $0.id == newValue.id })
            else { return }
            spaces[index] = newValue
            scheduleSave()
        }
    }

    func selectSpace(_ id: UUID) {
        guard id != activeSpaceID, spaces.contains(where: { $0.id == id })
        else { return }
        hideTabs(of: activeSpace)
        activeSpaceID = id
        let space = activeSpace
        activateTab(space.activeTabID ?? space.tabs.first?.id)
        scheduleSave()
    }

    func cycleSpace(by delta: Int) {
        guard spaces.count > 1,
            let index = spaces.firstIndex(where: { $0.id == activeSpaceID })
        else { return }
        let next = (index + delta + spaces.count) % spaces.count
        selectSpace(spaces[next].id)
    }

    func addSpace() {
        let palette = TintColor.allCases
        let symbols = ["person", "briefcase", "book", "gamecontroller", "cart"]
        let index = spaces.count
        var space = SpaceData(
            name: "Space \(index + 1)", symbol: symbols[index % symbols.count],
            tint: palette[index % palette.count])
        let tab = TabData(url: "https://example.com")
        space.tabs = [tab]
        space.activeTabID = tab.id
        spaces.append(space)
        selectSpace(space.id)
    }

    func renameSpace(_ id: UUID, to name: String) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].name = name
        scheduleSave()
    }

    private func hideTabs(of space: SpaceData) {
        for tab in space.tabs {
            guard let native = liveTabs[tab.id]?.nativeWindow else { continue }
            if native.parent != nil { window.removeChildWindow(native) }
            native.orderOut(nil)
        }
    }

    // MARK: - Tabs

    func newTab(url: String = "https://example.com", pinned: Bool = false) {
        var space = activeSpace
        let tab = TabData(url: url, isPinned: pinned)
        space.tabs.append(tab)
        space.activeTabID = tab.id
        activeSpace = space
        activateTab(tab.id)
    }

    func activateTab(_ id: UUID?) {
        guard let id, let data = tabData(id) else { return }
        var space = activeSpace
        space.activeTabID = id
        activeSpace = space
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
        }
        showOnly(tabID: id)
        canGoBack = tab.canGoBack
        canGoForward = tab.canGoForward
        if tab.nativeWindow != nil { tab.focus() }
    }

    func showOnly(tabID: UUID) {
        for (id, tab) in liveTabs {
            guard let native = tab.nativeWindow else { continue }
            if id == tabID {
                if native.parent !== window {
                    window.addChildWindow(native, ordered: .above)
                }
                native.setFrame(contentScreenRect, display: true)
                native.makeKeyAndOrderFront(nil)
            } else if native.parent != nil {
                window.removeChildWindow(native)
                native.orderOut(nil)
            }
        }
    }

    func closeTab(_ id: UUID) {
        guard var space = spaceContaining(id),
            let index = space.tabs.firstIndex(where: { $0.id == id })
        else { return }
        if let tab = liveTabs.removeValue(forKey: id) {
            tabIDsByObject.removeValue(forKey: ObjectIdentifier(tab))
            if let native = tab.nativeWindow, native.parent != nil {
                window.removeChildWindow(native)
            }
            tab.close()
        }
        space.tabs.remove(at: index)
        if space.activeTabID == id {
            space.activeTabID = space.tabs[max(0, index - 1)...].first?.id
                ?? space.tabs.last?.id
        }
        replace(space)
        if space.id == activeSpaceID {
            if let next = space.activeTabID {
                activateTab(next)
            } else {
                newTab()
            }
        }
    }

    // ⌘1…⌘9: pinned tabs first, matching the sidebar order.
    func activateTabAtIndex(_ index: Int) {
        let space = activeSpace
        let ordered = space.pinnedTabs + space.unpinnedTabs
        guard ordered.indices.contains(index) else { return }
        activateTab(ordered[index].id)
    }

    func closeActiveTab() {
        if let id = activeSpace.activeTabID { closeTab(id) }
    }

    // Drag and drop in the sidebar: reorder within a space, or move to another.
    func moveTab(_ id: UUID, before targetID: UUID) {
        guard var space = spaceContaining(id), space.tabs.contains(where: { $0.id == targetID }),
            let from = space.tabs.firstIndex(where: { $0.id == id })
        else { return }
        var tab = space.tabs.remove(at: from)
        guard let to = space.tabs.firstIndex(where: { $0.id == targetID }) else {
            space.tabs.insert(tab, at: from)
            return
        }
        // A tab dropped into the pinned section becomes pinned, and vice versa.
        if let target = space.tabs.first(where: { $0.id == targetID }) {
            tab.isPinned = target.isPinned
        }
        space.tabs.insert(tab, at: to)
        replace(space)
    }

    func moveTab(_ id: UUID, toSpace spaceID: UUID) {
        guard var source = spaceContaining(id), source.id != spaceID,
            let index = source.tabs.firstIndex(where: { $0.id == id }),
            var destination = spaces.first(where: { $0.id == spaceID })
        else { return }
        let tab = source.tabs.remove(at: index)
        if source.activeTabID == id { source.activeTabID = source.tabs.first?.id }
        destination.tabs.append(tab)
        replace(source)
        replace(destination)
        if source.id == activeSpaceID {
            // The tab's window belongs to the other space now.
            if let native = liveTabs[id]?.nativeWindow {
                if native.parent != nil { window.removeChildWindow(native) }
                native.orderOut(nil)
            }
            if let next = activeSpace.activeTabID { activateTab(next) }
        }
    }

    func togglePin(_ id: UUID) {
        guard var space = spaceContaining(id),
            let index = space.tabs.firstIndex(where: { $0.id == id })
        else { return }
        space.tabs[index].isPinned.toggle()
        replace(space)
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
        if !sidebarVisible { sidebarVisible = true }
        focusAddressToken += 1
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
            $0.title = tab.title
            $0.url = tab.currentURL
        }
        if let icon = tab.favicon { favicons[id] = icon }
        if tab.isLoading { loadingTabs.insert(id) } else { loadingTabs.remove(id) }
        if activeSpace.activeTabID == id {
            addressText = tab.currentURL
            canGoBack = tab.canGoBack
            canGoForward = tab.canGoForward
            window?.title = tab.title.isEmpty ? "cha" : tab.title
        }
    }

    func tab(_ tab: ChaTab, requestsNewTabWithURL url: String) {
        newTab(url: url)
    }

    func tabDidClose(_ tab: ChaTab) {
        guard let id = tabIDsByObject[ObjectIdentifier(tab)] else { return }
        liveTabs.removeValue(forKey: id)
        tabIDsByObject.removeValue(forKey: ObjectIdentifier(tab))
        closeTab(id)
    }

    // MARK: - State helpers

    func tabData(_ id: UUID) -> TabData? {
        spaces.flatMap(\.tabs).first { $0.id == id }
    }

    private func spaceContaining(_ id: UUID) -> SpaceData? {
        spaces.first { $0.tabs.contains { $0.id == id } }
    }

    private func replace(_ space: SpaceData) {
        guard let index = spaces.firstIndex(where: { $0.id == space.id })
        else { return }
        spaces[index] = space
        scheduleSave()
    }

    private func update(tabID: UUID, _ body: (inout TabData) -> Void) {
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

    private func scheduleSave() {
        guard !saveScheduled else { return }
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
                sidebarWidth: Double(sidebarWidth)))
    }
}
