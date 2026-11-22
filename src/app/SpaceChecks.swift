import AppKit
import SwiftUI

// CHA_TEST=spaces: walks through everything docs/arc-parity.md asks of
// spaces, checking the state after each step, and takes offscreen pictures
// in light and dark mode. Run it against a fresh CHA_PROFILE (scripts/check.sh
// does). The log ends with "CHECKS passed=N failed=M"; the exit code is the
// number of failures.
enum SpaceChecks {
    static var passed = 0
    static var failed = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok {
            passed += 1
            NSLog("CHECK ok   %@", name)
        } else {
            failed += 1
            NSLog("CHECK FAIL %@ %@", name, detail())
        }
    }

    static func page(_ text: String) -> String {
        "data:text/html,<title>\(text)</title><h1>\(text)</h1>"
    }

    // Runs the steps one after another, each |gap| seconds after the
    // previous one finished (not after the start: a slow step must not make
    // the next ones bunch up).
    static func sequence(_ steps: [(Double, () -> Void)]) {
        guard let (gap, step) = steps.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
            step()
            sequence(Array(steps.dropFirst()))
        }
    }

    // The window's own chrome: traffic lights where Arc has them, hidden
    // with the sidebar, and a sidebar that scales with the window.
    static func checkChrome(_ c: BrowserController) {
        guard let window = c.browserWindow, let close = window.standardWindowButton(.closeButton),
            let content = window.contentView
        else { return check("window buttons found", false) }
        let inWindow = close.convert(close.bounds, to: nil)
        let center = NSPoint(x: inWindow.midX, y: content.bounds.height - inWindow.midY)
        check(
            "traffic lights where Arc has them",
            abs(center.x - BrowserWindow.trafficLightCenter.x) < 1.5
                && abs(center.y - BrowserWindow.trafficLightCenter.y) < 1.5,
            NSStringFromPoint(center))
        c.toggleSidebar(animated: false)
        check("traffic lights hide with the sidebar", close.isHidden)
        c.toggleSidebar(animated: false)
        check("and come back", !close.isHidden)

        let before = c.sidebarWidth
        var frame = window.frame
        let original = frame
        for scale in [1.4, 0.75] {
            frame.size.width = (original.width * scale).rounded()
            window.setFrame(frame, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            check(
                "sidebar scales with the window ×\(scale)",
                abs(c.sidebarWidth - (before * scale).rounded()) <= 1
                    || c.sidebarWidth == BrowserController.minSidebarWidth
                    || c.sidebarWidth == BrowserController.maxSidebarWidth,
                "\(before) → \(c.sidebarWidth)")
            checkSidebarFits("×\(scale)", c)
        }
        window.setFrame(original, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        check("and back", abs(c.sidebarWidth - before) <= 1, "\(c.sidebarWidth)")
        checkSidebarFits("back", c)
        // Dragging the sidebar's edge goes through setSidebarWidth.
        for width in [320.0, 190.0, before] {
            c.setSidebarWidth(width)
            window.contentView?.layoutSubtreeIfNeeded()
            checkSidebarFits("dragged to \(Int(width))", c)
        }
        let again = c.browserWindow.map { b -> NSPoint in
            let r = close.convert(close.bounds, to: nil)
            return NSPoint(x: r.midX, y: (b.contentView?.bounds.height ?? 0) - r.midY)
        } ?? .zero
        check("traffic lights stay put after a resize", abs(again.y - 22) < 1.5, NSStringFromPoint(again))
    }

    // What is on screen, not just the number: the sidebar view is as wide
    // as sidebarWidth, its pill spans it less the padding, and the page
    // starts right where the sidebar ends.
    static func checkSidebarFits(_ label: String, _ c: BrowserController) {
        guard let view = c.sidebarView else { return check("sidebar view found", false) }
        check(
            "the sidebar's width constraint holds the sidebar view (\(label))",
            c.sidebarWidthConstraint?.firstItem === view && c.sidebarWidthConstraint?.isActive == true)
        check(
            "sidebar view as wide as the sidebar (\(label))",
            abs(view.frame.width - c.sidebarWidth) < 1,
            "view \(view.frame.width) vs \(c.sidebarWidth)")
        if let pill = UIFrames.frames["pill"] {
            check(
                "pill spans the sidebar (\(label))",
                abs(pill.minX - 8) < 1 && abs(pill.maxX - (c.sidebarWidth - 8)) < 1,
                "pill \(pill.minX)…\(pill.maxX) in \(c.sidebarWidth)")
        }
        check(
            "page starts where the sidebar ends (\(label))",
            abs(c.contentLocalRect.minX - c.sidebarWidth) < 1 && abs(view.frame.maxX - c.sidebarWidth) < 1,
            "page \(c.contentLocalRect.minX), view ends \(view.frame.maxX)")
    }

    // Full screen without going full screen (that would take over the
    // display): the page's rectangle and shape for both modes.
    static func checkFullscreenShape(_ c: BrowserController) {
        guard let content = c.window.contentView else { return }
        let inset = BrowserController.contentInset
        func radius() -> CGFloat? { c.activeTab?.nativeWindow?.contentView?.layer?.cornerRadius }

        c.isFullscreen = true
        c.applyPageShape()
        c.updateTrafficLights()
        let card = c.contentLocalRect
        check(
            "full screen, sidebar shown: a card with margins",
            card.minX == c.sidebarWidth && card.minY == inset && card.maxX == content.bounds.width - inset
                && card.maxY == content.bounds.height - inset,
            NSStringFromRect(card))
        check("full screen, sidebar shown: rounded corners", radius() == BrowserController.contentCornerRadius)
        check("full screen: the window's buttons are kept", c.browserWindow?.standardWindowButton(.closeButton)?.isHidden == false)

        c.toggleSidebar(animated: false)
        let full = c.contentLocalRect
        check("full screen, sidebar hidden: the page fills the screen", full == content.bounds, NSStringFromRect(full))
        check("full screen, sidebar hidden: no corners", radius() == 0)
        c.toggleSidebar(animated: false)
        check("sidebar back: corners back", radius() == BrowserController.contentCornerRadius)

        c.isFullscreen = false
        c.applyPageShape()
        c.updateTrafficLights()
        let window = c.contentLocalRect
        check(
            "window: the page is a card with a margin",
            window.minY == inset && window.maxX == content.bounds.width - inset, NSStringFromRect(window))
        check("window: rounded corners", radius() == BrowserController.contentCornerRadius)
    }

    // ⌘W on everything: today's tabs close one by one, then nothing is open;
    // pinned tabs are never opened on their own.
    // ⌘⇧T brings closed tabs back, last closed first, each where it was.
    static func checkReopenClosed(_ c: BrowserController) {
        c.recentlyClosed = []
        for name in ["A", "B", "C"] { c.newTab(url: page(name)) }  // today: C B A
        let today = { c.activeSpace.unpinnedTabs.map(\.id) }
        let before = today()
        let b = before[1], cc = before[0]
        c.renameTab(b, to: "Named B")
        c.closeTab(b)
        c.closeTab(cc)
        check("closed tabs leave", !today().contains(b) && !today().contains(cc))
        c.reopenClosedTab()
        check("⌘⇧T brings the last closed tab back, open", c.activeTabID == cc && today().first == cc,
              "\(today())")
        c.reopenClosedTab()
        check("then the one before, in its old place", today() == before && c.activeTabID == b,
              "\(today()) vs \(before)")
        check("with its name", c.tabData(b)?.displayTitle == "Named B", c.tabData(b)?.displayTitle ?? "-")
        c.reopenClosedTab()
        check("⌘⇧T with nothing closed changes nothing", today() == before && c.activeTabID == b)
        // From another space it goes home first.
        if let other = c.spaces.first(where: { $0.id != c.activeSpaceID }) {
            let home = c.activeSpaceID
            c.closeTab(b)
            c.selectSpace(other.id, animated: false)
            c.reopenClosedTab()
            check("a tab closed in another space comes back there", c.activeSpaceID == home
                  && c.activeTabID == b && today().contains(b))
        }
    }

    // A tab taken out of the model by any path but closeTab: its page
    // goes too, once the change is over; a tab only moving keeps its page.
    static func checkOrphanPages(_ c: BrowserController) {
        c.newTab(url: page("Orphan"))
        c.newTab(url: page("Mover"))
        guard let orphan = c.activeSpace.unpinnedTabs.last?.id,
            let mover = c.activeSpace.unpinnedTabs.first?.id
        else { return check("orphan tabs made", false) }
        c.activateTab(orphan)
        c.activateTab(mover)
        let page = c.liveTabs[orphan]
        var space = c.activeSpace
        space.tabs.removeAll { $0.id == orphan }
        c.replace(space)
        c.togglePin(mover)
        DispatchQueue.main.async {
            check("a page whose tab is gone is closed", c.liveTabs[orphan] == nil && page != nil)
            check("a tab that only moved keeps its page", c.liveTabs[mover] != nil)
            c.togglePin(mover)
            c.closeTab(mover)
        }
    }

    static func checkCloseEverything(_ c: BrowserController) {
        var pinnedOpened = false
        var steps = 0
        while let id = c.activeTabID, steps < 20 {
            c.closeTab(id)
            steps += 1
            if let now = c.activeTabID, let data = c.tabData(now), data.isPinned { pinnedOpened = true }
        }
        check(
            "closing everything ends with nothing open", c.activeTabID == nil && c.nothingOpen,
            "after \(steps) closes")
        check("no pinned tab opened on its own", !pinnedOpened)
        check("pinned tabs are still there", !c.activeSpace.pinnedTabs.isEmpty)
        c.closeActiveTab()
        check("⌘W with nothing open does nothing", c.activeTabID == nil)
    }

    // The sidebar slides: half way the page is between its two places, at
    // the end it fills the freed room and the sidebar is hidden; and back.
    static func checkSidebarSlide(_ c: BrowserController, then next: @escaping () -> Void) {
        guard let page = c.activeTab?.nativeWindow else { return next() }
        let withSidebar = page.frame
        c.sidebarProgress = []
        c.toggleSidebar()
        let without = c.contentScreenRect
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            let mid = page.frame.minX
            check("sidebar hides with a slide", c.sidebarAnimating
                && mid < withSidebar.minX - 1 && mid > without.minX + 1,
                "\(withSidebar.minX) → \(mid) → \(without.minX)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            check("…in 150 ms, the page in its room", !c.sidebarAnimating
                && page.frame.isClose(to: without) && c.sidebarView?.isHidden == true,
                NSStringFromRect(page.frame))
            // Ease-out: the first half of the time covers well over half the way.
            let p = c.sidebarProgress
            let half = p.count > 2 ? p[p.count / 2] : 0
            check("on an ease-out curve, not linear", p.count >= 6 && half > 0.7,
                "\(p.count) frames, half-time progress \(half)")
            c.toggleSidebar()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                check("…and back", !c.sidebarAnimating && page.frame.isClose(to: withSidebar)
                    && c.sidebarView?.isHidden == false && c.sidebarLeadingConstraint?.constant == 0,
                    NSStringFromRect(page.frame))
                next()
            }
        }
    }

    // Pages shown: exactly one, fully opaque, once a transition is over.
    static func checkOnePage(_ name: String, _ c: BrowserController) {
        let pages = (c.window.childWindows ?? []).filter { $0.isVisible && !($0 is NSPanel) }
        check(
            name, pages.count == 1 && pages.first?.alphaValue == 1
                && pages.first === c.activeTab?.nativeWindow,
            "\(pages.count) visible, alpha \(pages.map(\.alphaValue))")
    }

    // A trackpad scroll event over the sidebar. phase: 1 began, 2 changed,
    // 4 ended (CGScrollPhase).
    static func scrollEvent(phase: Int, dx: Double, dy: Double = 0, in c: BrowserController)
        -> NSEvent?
    {
        guard
            let cg = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
        else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        let inSidebar = NSPoint(x: 100, y: 300)
        cg.location = c.window.convertPoint(toScreen: inSidebar)
        guard let event = NSEvent(cgEvent: cg) else { return nil }
        // The window comes from the event's window number, which a
        // synthesized event lacks; rebuild it as one that belongs here.
        return event.window === c.window ? event : retarget(event, to: c.window)
    }

    private static func retarget(_ event: NSEvent, to window: NSWindow) -> NSEvent? {
        guard let cg = event.cgEvent else { return nil }
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            value: Int64(window.windowNumber))
        return NSEvent(cgEvent: cg)
    }

    // What a relaunch does with the saved state: tabs stay where they were,
    // however old (nothing is archived any more), and favicons come back.
    static func checkRelaunch(_ saved: BrowserState) {
        var state = saved
        let old = Date().addingTimeInterval(-13 * 3600)
        var stale = TabData(url: "https://stale.example/")
        stale.lastActive = old
        var keptPinned = TabData(url: "https://pinned.example/", isPinned: true)
        keptPinned.lastActive = old
        state.spaces[0].tabs += [stale, keptPinned]
        Persistence.save(state)

        let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
        FaviconStore.save(icon, host: "pinned.example")
        Thread.sleep(forTimeInterval: 0.3)  // The store writes in the background.

        let relaunched = BrowserController()
        let tabs = relaunched.spaces.flatMap(\.tabs)
        check("an old today tab is kept", tabs.contains { $0.id == stale.id })
        check("old pinned tab kept", tabs.contains { $0.id == keptPinned.id })
        check("favicon restored", relaunched.favicons[keptPinned.id] != nil)
        Persistence.save(saved)
    }

    // The secret space: reached from a space's menu, hidden from the bottom
    // bar, swipes, ⌃1…⌃9, the command bar, the archive and the logs, never
    // opened at launch.
    static func checkSecretSpace(_ c: BrowserController) {
        let before = c.activeSpaceID
        let visibleCount = c.visibleSpaces.count
        let archived = c.archive.count
        c.openSecretSpace()
        guard let secret = c.secretSpace else { return check("secret space made", false) }
        check("secret space opens", c.activeSpaceID == secret.id && c.inSecretSpace)
        check("it has a profile of its own", secret.profileID != nil
            && c.spaces.filter { $0.id != secret.id }.allSatisfy { $0.profileID != secret.profileID })
        check("it is not among the visible spaces",
            c.visibleSpaces.count == visibleCount && !c.visibleSpaces.contains { $0.id == secret.id })
        check("no swipe neighbours in it", c.leftSpace == nil && c.rightSpace == nil)
        c.newTab(url: page("Hush"))
        let hush = c.activeTabID
        _ = archived
        c.commandQuery = "hush"
        c.refreshCommandResults()
        let found = c.commandResults.contains {
            if case .tab(_, let id, _, _) = $0 { return id == hush }
            return false
        }
        check("its tabs are found from inside it", found)

        c.leaveSecretSpace()
        check("leaving goes back where it came from", c.activeSpaceID == before)
        c.refreshCommandResults()
        let leaked = c.commandResults.contains {
            switch $0 {
            case .tab(let space, _, _, _), .space(let space, _): return space == secret.id
            default: return false
            }
        }
        check("the command bar keeps it hidden outside", !leaked)
        c.commandQuery = "sec"
        c.refreshCommandResults()
        check("nor finds it by name", !c.commandResults.contains {
            if case .space(let id, _) = $0 { return id == secret.id }
            return false
        })
        c.commandQuery = ""
        for index in 0..<visibleCount {
            c.selectSpace(at: index)
            c.commitSpace(c.pageNeighbor.right ?? c.pageNeighbor.left ?? c.activeSpaceID)
            check("⌃\(index + 1) never lands in it", !c.inSecretSpace)
        }
        c.selectSpace(before, animated: false)
        c.cycleSpace(by: -1)
        c.commitSpace(c.pageNeighbor.right ?? c.pageNeighbor.left ?? c.activeSpaceID)
        check("nor ⌥⌘←", !c.inSecretSpace)
        c.selectSpace(before, animated: false)

        c.openSecretSpace()
        check("the second time it is the same space",
            c.activeSpaceID == secret.id && c.spaces.filter(\.isSecret).count == 1)
    }

    // ⌘T finds pages visited before, closed tabs or not.
    static func checkHistory(_ c: BrowserController) {
        c.history.clear()
        c.newTab(url: page("Visits"))
        guard let tab = c.activeTabID else { return check("history tab opened", false) }
        let first: () -> String = { c.commandResults.first?.id ?? "-" }
        for url in ["https://appstoreconnect.apple.com/apps", "https://appstoreconnect.apple.com/apps/42/testflight",
                    "https://www.youtube.com/", "https://www.youtube.com/watch?v=1", "https://www.youtube.com/"] {
            c.noteVisit(tabID: tab, url: url, title: "")
        }
        c.noteVisit(tabID: tab, url: "https://www.youtube.com/", title: "YouTube")
        c.noteVisit(tabID: tab, url: "https://appstoreconnect.apple.com/apps/42/testflight", title: "TestFlight - App Store Connect")
        check("a title alone is no visit", c.history.entries["https://www.youtube.com/"]?.visits == 2
            && c.history.entries["https://www.youtube.com/"]?.title == "YouTube")
        check("data: pages are not kept", !c.history.entries.keys.contains { $0.hasPrefix("data:") })
        c.closeTab(tab)

        c.commandQuery = "you"
        check("\"you\" goes to YouTube's front page", first() == "history-https://www.youtube.com/", first())
        c.commandQuery = "app"
        check("\"app\" goes to App Store Connect", first().hasPrefix("history-https://appstoreconnect.apple.com/apps"), first())
        check("with the search still there", c.commandResults.last == .search(query: "app"))
        c.commandQuery = "apple"
        check("a later part of the host finds it too", first().hasPrefix("history-https://appstoreconnect"), first())
        c.commandQuery = "testflight"
        check("so does the title, below the search",
            c.commandResults.contains(.history(title: "TestFlight - App Store Connect",
                url: "https://appstoreconnect.apple.com/apps/42/testflight")), first())
        c.commandQuery = "youtube.com"
        check("an address typed out opens as typed", first() == "open-https://youtube.com", first())
        c.commandQuery = "zzqx"
        check("nothing visited, a search first", first() == "search-zzqx", first())

        c.newTab(url: page("Open"))
        if let open = c.activeTabID {
            c.update(tabID: open) { $0.url = "https://www.youtube.com/" }
            c.commandQuery = "you"
            check("an open tab beats the same page in history",
                first() == "tab-\(open)" && !c.commandResults.contains { $0.id == "history-https://www.youtube.com/" }, first())
            c.closeTab(open)
        }

        c.history.save(wait: true)
        let reloaded = History()
        check("history survives a relaunch", reloaded.entries.count == c.history.entries.count && reloaded.entries.count == 4,
            "\(reloaded.entries.count)")
        let mode = (try? FileManager.default.attributesOfItem(
            atPath: Persistence.directory.appendingPathComponent("history.json").path)[.posixPermissions] as? Int) ?? 0
        check("and is the user's alone", mode == 0o600, String(mode, radix: 8))
        c.commandQuery = ""
    }

    static func checkSecretSpaceEnd(_ c: BrowserController) {
        guard let secret = c.secretSpace else { return check("secret space still there", false) }
        let before = c.lastVisibleSpaceID
        let kept = c.history.entries.count
        if let tab = secret.tabs.first?.id {
            c.noteVisit(tabID: tab, url: "https://hush.example.com/", title: "Hush")
        }
        check("the secret space leaves no history", c.history.entries.count == kept
            && c.history.entries["https://hush.example.com/"] == nil)
        let archived = c.archive.count
        TestScenarios.shot("secret-space")
        if let hush = secret.tabs.first?.id { c.closeTab(hush) }
        check("its closed tabs skip the archive", c.archive.count == archived)

        c.save()
        let relaunched = BrowserController()
        check("a launch never opens it", relaunched.activeSpaceID != secret.id
            && relaunched.secretSpace?.id == secret.id)

        c.deleteSpace(secret.id, confirm: false)
        check("it can be deleted, back to a visible space",
            c.secretSpace == nil && !c.inSecretSpace && c.activeSpaceID == before)
    }

    static func run(_ c: BrowserController) {
        var personal = UUID()
        var work = UUID()
        var pinned = UUID()
        var favorite = UUID()
        var folder = UUID()
        var findFirst = 0
        let dark = NSAppearance(named: .darkAqua)
        let light = NSAppearance(named: .aqua)

        var steps: [(Double, () -> Void)] = []
        steps += [
            (1.0, {
                NSApp.appearance = light
                personal = c.activeSpaceID
                check("starts with one space", c.spaces.count == 1)
                checkChrome(c)
                c.navigate(to: page("Home"))
            }),
            (0.5, {
                c.addSpace()
                work = c.activeSpaceID
                check("new space is open", work != personal)
                check(
                    "new space opens its editor",
                    c.sidebarPage == .editSpace(work, isNew: true))
                c.renameSpace(work, to: "Work")
                c.updateSpace(work) {
                    $0.symbol = "💼"
                    $0.theme = SpaceTheme.presets[1]
                }
            }),
            (0.6, { TestScenarios.shot("spaces-editor-light") }),
            (0.2, {
                c.finishEditing()
                check("editor closes", c.sidebarPage == .tabs)
                check("space renamed", c.activeSpace.name == "Work")
                check("emoji icon kept", c.activeSpace.symbolIsEmoji)
                c.newTab(url: page("One"))
            }),
            (0.4, { c.newTab(url: page("Two")) }),
            (0.4, { c.newTab(url: page("Three")) }),
        ]
        steps += [
            (1.0, {
                let titles = c.activeSpace.unpinnedTabs.map(\.displayTitle)
                check("new tabs on top", titles == ["Three", "Two", "One"], "\(titles)")
                pinned = c.activeSpace.unpinnedTabs[2].id
                c.togglePin(pinned)
                check("pinned", c.tabData(pinned)?.isPinned == true)
                check("pinned keeps its address", c.tabData(pinned)?.pinnedURL == page("One"))
                favorite = c.activeSpace.unpinnedTabs[1].id
                c.addToFavorites(favorite)
                check("favourite added", c.favorites.map(\.id) == [favorite])
                check("favourite left the space", c.spaceContaining(favorite) == nil)
                folder = c.addFolder(name: "Docs")
                c.newTab(url: page("Spec"))
            }),
            (0.6, {
                let spec = c.activeSpaceID == work ? c.activeSpace.unpinnedTabs[0].id : UUID()
                c.moveTab(spec, toFolder: folder)
                check(
                    "tab into folder",
                    c.activeSpace.tabs(in: folder).map(\.displayTitle) == ["Spec"])
                c.activateTab(c.activeSpace.unpinnedTabs.first?.id)
            }),
            (0.8, {
                checkOnePage("one page after a tab switch", c)
                checkFullscreenShape(c)
            }),
            // The shape checks flip the sidebar twice: let those slides settle,
            // then time one there and back (~1 s).
            (0.6, { checkSidebarSlide(c) {} }),
            (1.4, { TestScenarios.shot("spaces-work-light") }),
            (0.2, {
                NSApp.appearance = dark
            }),
            (0.6, { TestScenarios.shot("spaces-work-dark") }),
            (0.2, {
                // Click-switch slides over and lands.
                c.selectSpace(personal)
                check("switch is animated", c.pageAnimating)
            }),
        ]
        steps += [
            (0.25, {
                check("switch done within 250 ms", c.activeSpaceID == personal && !c.pageAnimating)
            }),
            (0.45, {
                checkOnePage("one page after a space switch", c)
                check("switched by click", c.activeSpaceID == personal)
                check("page settled", c.pageOffset == 0 && !c.pageAnimating)
                check("favourites shared", c.favorites.count == 1)
                check(
                    "space remembers its tab",
                    c.activeSpace.activeTabID == c.activeSpace.tabs.first?.id)
                c.selectSpace(at: 1)  // ⌃2
            }),
            (0.7, {
                check("⌃2 opens the second space", c.activeSpaceID == work)
                // A swipe half way to the left space, then let go.
                c.dragPage(by: c.sidebarWidth * 0.25)
                c.dragPage(by: c.sidebarWidth * 0.25)
            }),
            (0.2, { TestScenarios.shot("spaces-swipe-dark") }),
            (0.1, { c.endPageDrag(velocity: 0) }),
            (0.7, {
                check("swipe past a third switches", c.activeSpaceID == personal)
                c.dragPage(by: -c.sidebarWidth * 0.1)
                c.endPageDrag(velocity: 0)
            }),
        ]
        steps += [
            (0.7, {
                check("short swipe springs back", c.activeSpaceID == personal)
                check("spring back settles", c.pageOffset == 0)
                c.dragPage(by: c.sidebarWidth * 0.5)
                c.endPageDrag(velocity: 0)
            }),
            (0.7, {
                check("no space beyond the first", c.activeSpaceID == personal)
                c.dragPage(by: -c.sidebarWidth * 0.05)
                c.endPageDrag(velocity: -20)
            }),
            (0.7, {
                check("flick switches", c.activeSpaceID == work)
                // The same through real trackpad events: a scroll gesture
                // over the sidebar, fingers moving right.
                for (phase, dx) in [(1, 0.0), (2, -30.0), (2, -40.0), (2, -40.0), (4, 0.0)] {
                    if let event = scrollEvent(phase: phase, dx: dx, in: c) {
                        NSLog(
                            "SWIPE event window=%@ phase=%lu precise=%d dx=%.1f inv=%d loc=%@",
                            event.window === c.window ? "main" : String(describing: event.window),
                            event.phase.rawValue, event.hasPreciseScrollingDeltas ? 1 : 0,
                            event.scrollingDeltaX, event.isDirectionInvertedFromDevice ? 1 : 0,
                            NSStringFromPoint(event.locationInWindow))
                        _ = c.handleSwipe(event, overSidebar: true)
                    }
                }
                check("trackpad swipe takes the events", c.pageAnimating)
            }),
            (0.7, {
                check("trackpad swipe switches", c.activeSpaceID == personal)
                // Vertical scrolling stays with the tab list.
                let vertical = scrollEvent(phase: 1, dx: 0, dy: 12, in: c)
                let passed = vertical.map { c.handleSwipe($0, overSidebar: true) != nil } ?? false
                check("vertical scroll passes through", passed)
                c.selectSpace(work, animated: false)
                // Clear closes today's tabs (there is no archive any more).
                c.clearToday()
                check("clear empties today", c.activeSpace.unpinnedTabs.isEmpty)
                check("clear keeps pinned", c.tabData(pinned) != nil)
                // ⇧⌘L: the downloads page slides up in place of the tabs.
                c.toggleDownloads()
            }),
            (0.06, {
                // Mid-slide: downloads coming in from the left.
                TestScenarios.shot("spaces-downloads-sliding")
            }),
            (0.5, {
                check("⇧⌘L opens downloads", c.sidebarPage == .downloads)
                TestScenarios.shot("spaces-downloads-dark")
            }),
            (0.2, { c.toggleDownloads() }),
            (0.3, {
                check("and ⇧⌘L again goes back", c.sidebarPage == .tabs)
                c.newTab(url: page("Restored"))
                // ⌘W on a pinned tab unloads it.
                c.activateTab(pinned)
            }),
        ]
        steps += [
            (0.8, {
                c.closeTab(pinned)
                check("⌘W keeps a pinned tab", c.tabData(pinned) != nil)
                check("⌘W unloads it", !c.isLoaded(pinned))
                c.activateTab(pinned)
            }),
            (0.8, {
                c.navigate(to: page("Elsewhere"))
            }),
            (0.8, {
                check("pinned tab wandered", c.tabData(pinned)?.hasLeftPinnedURL == true)
                c.resetToPinnedURL(pinned)
            }),
            (0.8, {
                check("back to pinned address", c.tabData(pinned)?.hasLeftPinnedURL == false)
                // Move a tab to the other space.
                let tab = c.activeSpace.unpinnedTabs.first!.id
                c.moveTab(tab, toSpace: personal)
                check("moved to space", c.spaceContaining(tab)?.id == personal)
                // Reorder spaces and delete a third one.
                c.addSpace()
                let third = c.activeSpaceID
                c.finishEditing()
                c.moveSpace(third, before: personal)
                check("reorder spaces", c.spaces.first?.id == third)
                c.deleteSpace(third, confirm: false)
                check("delete space", c.spaces.count == 2 && c.activeSpaceID != third)
                // A fresh space given up on goes away.
                c.addSpace()
                c.finishEditing(cancelled: true)
                check("cancelled new space removed", c.spaces.count == 2)
            }),
            (0.8, {
                c.selectSpace(work, animated: false)
                // ⌘F: the find bar finds and counts, steps, and closes.
                c.newTab(url: "data:text/html,<title>Find</title><p>alpha beta gamma beta delta</p>")
            }),
            (1.2, {
                // Something selected: ⌘F searches for it straight away.
                c.activeTab?.executeJavaScript(
                    "const r = document.createRange(); const p = document.querySelector('p');"
                        + "r.setStart(p.firstChild, 6); r.setEnd(p.firstChild, 10);"
                        + "getSelection().removeAllRanges(); getSelection().addRange(r);")
            }),
            (0.4, {
                c.openFindBar()
                check("⌘F opens the find bar", c.isFindOpen)
            }),
            (0.8, {
                check("⌘F takes the selection as the search", c.find.query == "beta", c.find.query)
                check("the selection wins over the clipboard", true)
                c.closeFindBar()
                // Nothing selected: the clipboard's first line; nothing
                // there either: an empty field, not the last search.
                c.activeTab?.executeJavaScript("getSelection().removeAllRanges()")
                BrowserController.clipboard.clearContents()
                BrowserController.clipboard.setString("gamma\nsecond line", forType: .string)
            }),
            (0.3, { c.openFindBar() }),
            (0.8, {
                check("no selection: the clipboard's first line", c.find.query == "gamma", c.find.query)
                c.closeFindBar()
                BrowserController.clipboard.clearContents()
            }),
            (0.3, { c.openFindBar() }),
            (0.8, {
                check("nothing anywhere: an empty field", c.find.query.isEmpty, c.find.query)
                c.find.query = "beta"
                c.search("beta", findNext: false)
            }),
        ]
        steps += [
            (1.0, {
                check("find counts matches", c.find.count == 2, "\(c.find.count)")
                c.findNext(forward: true)
            }),
            (0.6, {
                findFirst = c.find.active
                c.findNext(forward: true)
            }),
            (0.6, {
                // Off screen Chromium only picks a match once asked to step,
                // so the check is that ⌘G moves between the two.
                check(
                    "⌘G steps between matches",
                    (1...2).contains(c.find.active) && (1...2).contains(findFirst)
                        && c.find.active != findFirst,
                    "\(findFirst) → \(c.find.active)")
                if let bar = c.findPanel {
                    let page = c.contentScreenRect
                    check(
                        "find bar sits at the page's top right",
                        abs(bar.frame.maxX - (page.maxX - 12)) < 1
                            && abs(bar.frame.maxY - (page.maxY - 12)) < 1,
                        "\(NSStringFromRect(bar.frame)) in \(NSStringFromRect(page))")
                }
                c.closeFindBar()
                check("Esc closes it", !c.isFindOpen && c.find.count == 0)
                // Renaming a tab: the name sticks through the page's own title.
                let id = c.activeTabID!
                c.renameTab(id, to: "My notes")
                check("rename a tab", c.tabData(id)?.displayTitle == "My notes")
                c.navigate(to: "data:text/html,<title>Other title</title>")
            }),
            (1.0, {
                let id = c.activeTabID!
                check("the name survives a page load", c.tabData(id)?.displayTitle == "My notes",
                      c.tabData(id)?.displayTitle ?? "-")
                c.renameTab(id, to: "")
                check("an empty name gives the page's title back",
                      c.tabData(id)?.displayTitle == "Other title", c.tabData(id)?.displayTitle ?? "-")
                // ⌘W on everything: today's tabs close one by one, then
                // nothing is open; pinned tabs are never opened on their own.
                c.newTab(url: page("Close me"))
            }),
            (0.6, { checkCloseEverything(c) }),
            (0.2, { checkReopenClosed(c) }),
            (0.4, { checkOrphanPages(c) }),
            (0.6, { checkHistory(c) }),
            (0.6, { checkSecretSpace(c) }),
            (1.0, { checkSecretSpaceEnd(c) }),
            (0.8, {
                // Many spaces: the inactive ones shrink to dots.
                for _ in 0..<8 {
                    c.addSpace()
                    c.finishEditing()
                }
                c.selectSpace(work, animated: false)
                NSApp.appearance = light
            }),
        ]
        steps += [
            (0.8, {
                TestScenarios.shot("spaces-many-light")
                for space in c.spaces where space.id != work && space.id != personal {
                    c.deleteSpace(space.id, confirm: false)
                }
                check("extra spaces deleted", c.spaces.count == 2)
            }),
            (0.8, { TestScenarios.shot("spaces-final-light") }),
            (0.2, {
                c.save()
                let state = Persistence.load()
                check("favourites saved", state.favorites?.map(\.id) == [favorite])
                check(
                    "folders saved",
                    state.spaces.first { $0.id == work }?.folders.first?.name == "Docs")
                check(
                    "themes saved",
                    state.spaces.first { $0.id == work }?.theme == SpaceTheme.presets[1])
                checkRelaunch(state)
                NSLog("CHECKS passed=%d failed=%d", passed, failed)
                NSApp.terminate(nil)
            }),
        ]
        sequence(steps)
    }
}
