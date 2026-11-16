import AppKit
import SwiftUI

// Spaces: switching (with Arc's sideways slide and the two-finger swipe),
// making, editing, deleting and reordering them, and folders inside them.
extension BrowserController {
    var activeSpaceIndex: Int { spaces.firstIndex { $0.id == activeSpaceID } ?? 0 }

    func space(_ id: UUID?) -> SpaceData? {
        guard let id else { return nil }
        return spaces.first { $0.id == id }
    }

    // The spaces either side of the open one, for the pager.
    var leftSpace: SpaceData? {
        if let id = pageNeighbor.left { return space(id) }
        let index = activeSpaceIndex
        return index > 0 ? spaces[index - 1] : nil
    }

    var rightSpace: SpaceData? {
        if let id = pageNeighbor.right { return space(id) }
        let index = activeSpaceIndex
        return index + 1 < spaces.count ? spaces[index + 1] : nil
    }

    // MARK: Switching

    // Clicking an icon, ⌃1…⌃9 and ⌥⌘←/→ slide the sidebar over to the
    // space, the way a swipe would.
    func selectSpace(_ id: UUID, animated: Bool = true) {
        guard id != activeSpaceID, let target = spaces.firstIndex(where: { $0.id == id })
        else { return }
        if sidebarPage != .tabs { sidebarPage = .tabs }
        let width = sidebarWidth
        guard animated, sidebarVisible, !pageAnimating else {
            commitSpace(id)
            return
        }
        let forward = target > activeSpaceIndex
        pageNeighbor = forward ? (nil, id) : (id, nil)
        applySpaceTint(spaces[target].theme)
        slidePage(to: forward ? -width : width, duration: 0.32, then: id)
    }

    // Animates the page to |offset|, then opens |space| (or just settles when
    // nil). Each slide has a number; only the latest may finish, so a late
    // completion from an earlier slide can't open the wrong space.
    func slidePage(to offset: CGFloat, duration: Double, then space: UUID?) {
        pageGeneration += 1
        let generation = pageGeneration
        pageAnimating = true
        let finish: () -> Void = { [weak self] in
            guard let self, self.pageGeneration == generation, self.pageAnimating else { return }
            if let space { self.commitSpace(space) } else { self.settlePage() }
        }
        withAnimation(.spring(duration: duration, bounce: 0.0)) {
            pageOffset = offset
        } completion: {
            finish()
        }
        // SwiftUI reports the end of an animation from the display's refresh;
        // a window that is hidden or covered may never get one, so the slide
        // also finishes on a timer. Whichever comes first wins.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1, execute: finish)
    }

    private func settlePage() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { pageOffset = 0 }
        pageAnimating = false
    }

    // The switch itself, once the page has slid over.
    func commitSpace(_ id: UUID) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeSpaceID = id
            pageOffset = 0
            pageNeighbor = (nil, nil)
        }
        pageAnimating = false
        applySpaceTint(animated: false)
        let space = activeSpace
        activateTab(space.activeTabID ?? space.tabs.first?.id)
        scheduleSave()
        Diagnostics.mark("space-switched")
    }

    func cycleSpace(by delta: Int) {
        guard spaces.count > 1 else { return }
        let next = (activeSpaceIndex + delta + spaces.count) % spaces.count
        selectSpace(spaces[next].id)
    }

    func selectSpace(at index: Int) {
        guard spaces.indices.contains(index) else { return }
        selectSpace(spaces[index].id)
    }

    // MARK: Two-finger swipe

    // Horizontal scrolling over the sidebar drags the space's page, which
    // follows the fingers; letting go past a third of the way (or with a
    // flick) settles on the neighbour, otherwise it springs back.
    func installSwipeMonitor() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            self?.handleSwipe(event) ?? event
        }
    }

    // |overSidebar| lets the checks feed synthesized events, which carry no
    // window, as if they happened over the sidebar.
    func handleSwipe(_ event: NSEvent, overSidebar: Bool = false) -> NSEvent? {
        let inside =
            overSidebar || (event.window === window && event.locationInWindow.x < sidebarWidth)
        guard inside, sidebarVisible, sidebarPage == .tabs else { return event }

        // Momentum after a swipe belongs to the swipe.
        if !event.momentumPhase.isEmpty {
            return swipe.swallowMomentum ? nil : event
        }
        if event.phase == .began || event.phase == .mayBegin {
            swipe = SwipeTracker()
        }
        guard event.hasPreciseScrollingDeltas else { return event }

        if event.phase == .changed || event.phase == .began {
            // Fingers to the right reveal the space on the left.
            let dx = event.isDirectionInvertedFromDevice
                ? event.scrollingDeltaX : -event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            if swipe.isHorizontal == nil {
                guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return event }
                swipe.isHorizontal = abs(dx) > abs(dy) * 1.2
            }
            guard swipe.isHorizontal == true, !pageAnimating else { return event }
            swipe.velocity = dx
            dragPage(by: dx)
            return nil
        }

        if event.phase == .ended || event.phase == .cancelled {
            guard swipe.isHorizontal == true else { return event }
            swipe.swallowMomentum = true
            endPageDrag(velocity: swipe.velocity, cancelled: event.phase == .cancelled)
            return nil
        }
        return event
    }

    // Moves the page by |dx| points, with rubber banding where there is no
    // space to go to, and blends the window's colour on the way.
    func dragPage(by dx: CGFloat) {
        let width = sidebarWidth
        var offset = pageOffset + dx
        if (offset > 0 && leftSpace == nil) || (offset < 0 && rightSpace == nil) {
            offset = pageOffset + dx * 0.25
            offset = max(min(offset, width * 0.15), -width * 0.15)
        }
        offset = max(min(offset, width), -width)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { pageOffset = offset }

        let neighbor = offset > 0 ? leftSpace : rightSpace
        if let neighbor {
            applySpaceTint(
                activeSpace.theme.mixed(with: neighbor.theme, Double(abs(offset) / width)),
                animated: false)
        }
    }

    func endPageDrag(velocity: CGFloat, cancelled: Bool = false) {
        let width = sidebarWidth
        let flick = abs(velocity) > 12
        let target: SpaceData?
        if !cancelled, pageOffset > 0, let left = leftSpace,
            pageOffset > width / 3 || (flick && velocity > 0)
        {
            target = left
        } else if !cancelled, pageOffset < 0, let right = rightSpace,
            -pageOffset > width / 3 || (flick && velocity < 0)
        {
            target = right
        } else {
            target = nil
        }

        guard let target else {
            applySpaceTint()
            slidePage(to: 0, duration: 0.28, then: nil)
            return
        }
        let forward = pageOffset < 0
        applySpaceTint(target.theme)
        slidePage(to: forward ? -width : width, duration: 0.26, then: target.id)
    }

    // MARK: Making and editing

    // A new space opens straight into its editor page, as in Arc.
    func addSpace() {
        let used = Set(spaces.map(\.theme))
        let theme = SpaceTheme.presets.first { !used.contains($0) }
            ?? SpaceTheme.presets[spaces.count % SpaceTheme.presets.count]
        let symbols = ["star", "briefcase", "book", "gamecontroller", "cart", "house", "leaf"]
        let space = SpaceData(
            name: "Space \(spaces.count + 1)",
            symbol: symbols[spaces.count % symbols.count], theme: theme)
        spaces.append(space)
        scheduleSave()
        selectSpace(space.id, animated: false)
        sidebarPage = .editSpace(space.id, isNew: true)
    }

    func editSpace(_ id: UUID) {
        if id != activeSpaceID { selectSpace(id, animated: false) }
        sidebarPage = .editSpace(id, isNew: false)
    }

    func updateSpace(_ id: UUID, _ body: (inout SpaceData) -> Void) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        body(&spaces[index])
        if id == activeSpaceID { applySpaceTint() }
        scheduleSave()
    }

    func renameSpace(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        updateSpace(id) { $0.name = name }
    }

    // Done in the editor; a fresh space given up on goes away again.
    func finishEditing(cancelled: Bool = false) {
        if case .editSpace(let id, let isNew) = sidebarPage, isNew, cancelled {
            sidebarPage = .tabs
            deleteSpace(id, confirm: false)
            return
        }
        sidebarPage = .tabs
    }

    // Deleting a space with tabs asks first; its today tabs go to the archive.
    func deleteSpace(_ id: UUID, confirm: Bool = true) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == id })
        else { return }
        let space = spaces[index]
        if confirm, !space.tabs.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Delete “\(space.name)”?"
            alert.informativeText =
                "Its \(space.tabs.count) tab\(space.tabs.count == 1 ? "" : "s") will be closed. "
                + "Unpinned ones stay in the archive."
            alert.addButton(withTitle: "Delete Space")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for tab in space.tabs {
            unload(tab.id)
            if !tab.isPinned { addToArchive(tab, spaceID: nil) }
        }
        if id == activeSpaceID {
            let next = spaces[index > 0 ? index - 1 : index + 1].id
            commitSpace(next)
        }
        spaces.removeAll { $0.id == id }
        if case .editSpace(let editing, _) = sidebarPage, editing == id { sidebarPage = .tabs }
        scheduleSave()
    }

    // Dragging a space's icon onto another's puts it there.
    func moveSpace(_ id: UUID, before targetID: UUID) {
        guard id != targetID, let from = spaces.firstIndex(where: { $0.id == id }),
            let to = spaces.firstIndex(where: { $0.id == targetID })
        else { return }
        let space = spaces.remove(at: from)
        // It takes the target's place; the target shifts towards where it came from.
        spaces.insert(space, at: to)
        scheduleSave()
    }

    // MARK: Folders

    @discardableResult
    func addFolder(name: String = "New Folder") -> UUID {
        var space = activeSpace
        let folder = FolderData(name: name)
        space.folders.append(folder)
        replace(space)
        return folder.id
    }

    func renameFolder(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, var space = spaces.first(where: { $0.folders.contains { $0.id == id } }),
            let index = space.folders.firstIndex(where: { $0.id == id })
        else { return }
        space.folders[index].name = name
        replace(space)
    }

    func toggleFolder(_ id: UUID) {
        guard var space = spaces.first(where: { $0.folders.contains { $0.id == id } }),
            let index = space.folders.firstIndex(where: { $0.id == id })
        else { return }
        space.folders[index].isOpen.toggle()
        replace(space)
    }

    // The folder goes; its tabs stay pinned, outside it.
    func deleteFolder(_ id: UUID) {
        guard var space = spaces.first(where: { $0.folders.contains { $0.id == id } })
        else { return }
        space.folders.removeAll { $0.id == id }
        for index in space.tabs.indices where space.tabs[index].folderID == id {
            space.tabs[index].folderID = nil
        }
        replace(space)
    }

    func moveTab(_ id: UUID, toFolder folder: UUID) {
        moveTab(id, toSection: true, folder: folder)
    }
}

struct SwipeTracker {
    var isHorizontal: Bool?
    var velocity: CGFloat = 0
    var swallowMomentum = false
}
