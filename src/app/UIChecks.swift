import AppKit
import SwiftUI

// CHA_TEST=ui: the sidebar driven through real AppKit events posted to the
// app's own queue (no Accessibility permission needed): clicks, hover,
// drags of tabs and space icons, and the colour panel. Elements are found
// through the window's own accessibility tree, so the coordinates are where
// SwiftUI actually put them. Meant for a visible window
// (CHA_SCREEN=1 scripts/check.sh window); the log ends with "CHECKS …".
enum UIChecks {
    typealias Check = SpaceChecks

    static func page(_ text: String) -> String { SpaceChecks.page(text) }

    // MARK: Finding elements

    // Screen frame of a recorded element ("tab:<uuid>", "space:<uuid>", …).
    static func frame(_ key: String, in c: BrowserController) -> NSRect? {
        guard let rect = UIFrames.frames[key], let view = c.sidebarView else { return nil }
        // .global is the hosting view's own space, top-left origin.
        let flippedY = view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
        let local = NSRect(x: rect.minX, y: flippedY, width: rect.width, height: rect.height)
        let inWindow = view.convert(local, to: nil)
        return c.window.convertToScreen(inWindow)
    }

    // MARK: Events

    static func toWindow(_ screenPoint: NSPoint, _ c: BrowserController) -> NSPoint {
        c.window.convertPoint(fromScreen: screenPoint)
    }

    static func post(_ type: NSEvent.EventType, at screenPoint: NSPoint, _ c: BrowserController) {
        guard
            let event = NSEvent.mouseEvent(
                with: type, location: toWindow(screenPoint, c), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: c.window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        NSApp.postEvent(event, atStart: false)
    }

    static func center(_ rect: NSRect) -> NSPoint { NSPoint(x: rect.midX, y: rect.midY) }

    static func click(_ rect: NSRect, _ c: BrowserController) {
        post(.leftMouseDown, at: center(rect), c)
        post(.leftMouseUp, at: center(rect), c)
    }

    // A drag in small steps, the way a hand does it.
    static func drag(from: NSRect, to: NSRect, _ c: BrowserController) {
        let start = center(from), end = center(to)
        post(.leftMouseDown, at: start, c)
        for i in 1...20 {
            let t = CGFloat(i) / 20
            let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            post(.leftMouseDragged, at: point, c)
        }
        post(.leftMouseUp, at: end, c)
    }

    // MARK: Real cursor (CHA_REAL_INPUT=1)

    // Hover and drags need the window server: tracking areas and drag
    // sessions follow the real cursor, not events posted to the app. So
    // these move the real mouse, which only happens when nobody is at the
    // Mac (scripts/check.sh window decides). They post from a background
    // queue, since a drag session runs its own loop on the main thread.
    static let realInput = ProcessInfo.processInfo.environment["CHA_REAL_INPUT"] == "1"

    // AppKit screen points (bottom-left origin) to CoreGraphics' (top-left
    // of the main display).
    static func cgPoint(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
    }

    static func realEvent(_ type: CGEventType, _ p: NSPoint) {
        CGEvent(
            mouseEventSource: nil, mouseType: type, mouseCursorPosition: cgPoint(p),
            mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    static func realHover(_ target: NSRect) {
        let p = center(target)
        DispatchQueue.global().async {
            realEvent(.mouseMoved, NSPoint(x: p.x + 1, y: p.y + 1))
            usleep(80_000)
            realEvent(.mouseMoved, p)
        }
    }

    static func realDrag(from: NSRect, to: NSRect) {
        let start = center(from), end = center(to)
        DispatchQueue.global().async {
            realEvent(.mouseMoved, start)
            usleep(100_000)
            realEvent(.leftMouseDown, start)
            usleep(150_000)
            for i in 1...30 {
                let t = CGFloat(i) / 30
                realEvent(
                    .leftMouseDragged,
                    NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                usleep(16_000)
            }
            usleep(200_000)
            realEvent(.leftMouseUp, end)
        }
    }

    static func skip(_ name: String) {
        NSLog("CHECK skip %@ (needs the real cursor: CHA_REAL_INPUT=1, Mac idle)", name)
    }

    // MARK: Scenario

    static func run(_ c: BrowserController) {
        var work = UUID(), personal = UUID()
        var a = UUID(), b = UUID(), d = UUID()
        SpaceChecks.sequence([
            (1.0, {
                personal = c.activeSpaceID
                c.renameSpace(personal, to: "Personal")
                c.navigate(to: page("Home"))
                c.addSpace()
                work = c.activeSpaceID
                c.renameSpace(work, to: "Work")
                c.finishEditing()
                c.newTab(url: page("Alpha"))
                a = c.activeTabID!
            }),
            (0.4, { c.newTab(url: page("Bravo")); b = c.activeTabID! }),
            (0.4, { c.newTab(url: page("Delta")); d = c.activeTabID! }),
            (1.2, {
                // A click on a row opens it.
                guard let alpha = frame("tab:\(a)", in: c) else {
                    Check.check("row Alpha found", false)
                    return
                }
                click(alpha, c)
            }),
            (0.6, {
                Check.check("click opens the tab", c.activeTabID == a, "\(String(describing: c.activeTabID))")
                // A click on a space icon switches.
                if let icon = frame("space:\(personal)", in: c) { click(icon, c) }
            }),
            (1.0, {
                Check.check("click on a space icon switches", c.activeSpaceID == personal)
                if let icon = frame("space:\(work)", in: c) { click(icon, c) }
            }),
            (1.0, {
                Check.check("and back", c.activeSpaceID == work)
                // Hover shows the close button on that row only.
                guard realInput else { return skip("hover") }
                if let bravo = frame("tab:\(b)", in: c) { realHover(bravo) }
            }),
            (0.8, {
                if realInput {
                    Check.check("hover shows the close button", UIFrames.frames["close:\(b)"] != nil)
                    Check.check("only on the hovered row", UIFrames.frames["close:\(a)"] == nil)
                }
                // Drag Delta onto the Personal space icon.
                guard realInput else { return skip("drag a tab onto a space icon") }
                guard let delta = frame("tab:\(d)", in: c),
                    let icon = frame("space:\(personal)", in: c)
                else { return Check.check("drag targets found", false) }
                realDrag(from: delta, to: icon)
            }),
            (2.0, {
                guard realInput else { return skip("drag to reorder tabs") }
                Check.check("drag tab onto a space icon moves it", c.spaceContaining(d)?.id == personal)
                // Drag Alpha onto Bravo's row: Alpha goes before Bravo.
                guard let alpha = frame("tab:\(a)", in: c), let bravo = frame("tab:\(b)", in: c)
                else { return Check.check("rows found", false) }
                realDrag(from: alpha, to: bravo)
            }),
            (2.0, {
                guard realInput else { return skip("drag space icons to reorder") }
                let order = c.activeSpace.unpinnedTabs.map(\.displayTitle)
                Check.check("drag reorders tabs", order == ["Alpha", "Bravo"], "\(order)")
                guard let workIcon = frame("space:\(work)", in: c),
                    let personalIcon = frame("space:\(personal)", in: c)
                else { return Check.check("space icons found", false) }
                realDrag(from: workIcon, to: personalIcon)
            }),
            (2.0, {
                if realInput {
                    Check.check("drag space icon reorders spaces", c.spaces.first?.id == work)
                }
            }),
            (0.6, {
                // The colour panel recolours the space live.
                ThemeColorPanel.shared.attach(for: personal, controller: c)
                NSColorPanel.shared.color = NSColor(srgbRed: 0.2, green: 0.8, blue: 0.3, alpha: 1)
                ThemeColorPanel.shared.colorChanged(NSColorPanel.shared)
                let theme = c.space(personal)?.theme
                Check.check(
                    "colour panel recolours the space",
                    theme.map { abs($0.green - 0.8) < 0.02 && abs($0.red - 0.2) < 0.02 } ?? false,
                    "\(String(describing: theme))")
                TestScenarios.shot("ui-final")
            }),
            (0.5, {
                NSLog("CHECKS passed=%d failed=%d", Check.passed, Check.failed)
                NSApp.terminate(nil)
            }),
        ])
    }
}

