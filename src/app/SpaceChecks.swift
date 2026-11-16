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

    // What a relaunch does with the saved state: today's tabs left alone for
    // 12 hours go to the archive, pinned ones stay, favicons come back.
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
        check("stale today tab archived", !tabs.contains { $0.id == stale.id })
        check(
            "stale tab is in the archive",
            relaunched.archive.contains { $0.url == "https://stale.example/" })
        check("old pinned tab kept", tabs.contains { $0.id == keptPinned.id })
        check("favicon restored", relaunched.favicons[keptPinned.id] != nil)
        Persistence.save(saved)
    }

    static func run(_ c: BrowserController) {
        var personal = UUID()
        var work = UUID()
        var pinned = UUID()
        var favorite = UUID()
        var folder = UUID()
        let dark = NSAppearance(named: .darkAqua)
        let light = NSAppearance(named: .aqua)

        sequence([
            (1.0, {
                NSApp.appearance = light
                personal = c.activeSpaceID
                check("starts with one space", c.spaces.count == 1)
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
            (0.8, { TestScenarios.shot("spaces-work-light") }),
            (0.2, {
                NSApp.appearance = dark
            }),
            (0.6, { TestScenarios.shot("spaces-work-dark") }),
            (0.2, {
                // Click-switch slides over and lands.
                c.selectSpace(personal)
                check("switch is animated", c.pageAnimating)
            }),
            (0.7, {
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
                // Today's tabs go to the archive with Clear.
                let today = c.activeSpace.unpinnedTabs.count
                let archived = c.archive.count
                c.clearToday()
                check("clear empties today", c.activeSpace.unpinnedTabs.isEmpty)
                check("clear archives", c.archive.count == archived + today, "\(c.archive.count)")
                check("clear keeps pinned", c.tabData(pinned) != nil)
                c.sidebarPage = .archive
            }),
            (0.6, { TestScenarios.shot("spaces-archive-dark") }),
            (0.2, {
                let first = c.archive[0]
                c.restoreArchived(first.id)
                check("restore from archive", c.activeSpace.unpinnedTabs.first?.url == first.url)
                // ⌘W on a pinned tab unloads it.
                c.activateTab(pinned)
            }),
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
                // Many spaces: the inactive ones shrink to dots.
                for _ in 0..<8 {
                    c.addSpace()
                    c.finishEditing()
                }
                c.selectSpace(work, animated: false)
                NSApp.appearance = light
            }),
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
                check("archive saved", (state.archive?.count ?? 0) == c.archive.count)
                checkRelaunch(state)
                NSLog("CHECKS passed=%d failed=%d", passed, failed)
                NSApp.terminate(nil)
            }),
        ])
    }
}
