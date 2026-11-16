import AppKit
import SwiftUI

// Development helper: the app can't be driven by scripts on this machine
// (no Accessibility permission), so CHA_TEST=<name> replays a scenario and
// captures screenshots into build/.
enum TestScenarios {
    static func run(_ name: String, controller: BrowserController) {
        switch name {
        case "bench":
            // Launch until the first page has loaded, then quit as ⌘Q does;
            // scripts/bench.sh times both ends from outside.
            Diagnostics.after("first-load-end") {
                at(0.5) { NSApp.terminate(nil) }
            }
            at(20) { NSApp.terminate(nil) }

        case "shot":
            at(2) { shot("look") }
            at(3) { NSApp.terminate(nil) }

        case "demo":
            at(2) { controller.newTab(url: "https://news.ycombinator.com") }
            at(6) { shot("test-tabs") }
            at(7) { controller.addSpace() }
            at(10) { shot("test-space2") }
            at(11) { controller.cycleSpace(by: -1) }
            at(13) { shot("test-space1") }
            at(14) { controller.toggleFullscreen() }
            at(18) { shot("test-fullscreen") }
            at(19) { controller.toggleSidebar() }
            at(21) { shot("test-nosidebar") }
            at(22) { controller.toggleSidebar(); controller.toggleFullscreen() }
            at(25) { shot("test-back") }
        case "fullscreen":
            at(2) { dump("windowed", controller) }
            at(3) { controller.toggleFullscreen() }
            at(7) { dump("fullscreen", controller) }
            at(8) { controller.toggleSidebar() }
            at(10) { dump("fullscreen, no sidebar", controller) }
            at(11) { controller.toggleSidebar(); controller.toggleFullscreen() }
            at(15) { dump("windowed again", controller) }

        case "look":
            at(3) { controller.newTab(url: "https://news.ycombinator.com") }
            at(7) { controller.setSidebarWidth(300) }
            at(9) { shot("test-look-wide") }
            at(10) { controller.setSidebarWidth(200) }
            at(12) { shot("test-look-narrow") }
            at(13) {
                NSLog(
                    "LOOK width=%.0f back=%d forward=%d title=%@",
                    controller.sidebarWidth, controller.canGoBack ? 1 : 0,
                    controller.canGoForward ? 1 : 0, controller.window.title)
            }

        case "organize":
            at(2) { controller.newTab(url: "https://example.org") }
            at(4) { controller.newTab(url: "https://news.ycombinator.com") }
            at(7) { describe("start", controller) }
            at(8) {
                let tabs = controller.activeSpace.tabs
                controller.togglePin(tabs[0].id)
                controller.moveTab(tabs[2].id, before: tabs[1].id)
            }
            at(9) { describe("pinned + reordered", controller) }
            at(10) { controller.addSpace() }
            at(12) { controller.cycleSpace(by: -1) }
            at(13) {
                let target = controller.spaces[1].id
                let moved = controller.activeSpace.unpinnedTabs[0].id
                controller.moveTab(moved, toSpace: target)
            }
            at(15) { describe("after move to space 2", controller) }
            at(16) { controller.selectSpace(controller.spaces[1].id) }
            at(18) { describe("space 2", controller); shot("test-organize") }

        case "passwordsui":
            at(2) { controller.newTab(url: "chrome://password-manager/settings") }
            at(6) { shot("test-pwui") }
            at(8) {
                controller.activeTab?.executeJavaScript(
                    "document.title = 'PWUI ' + document.body.innerText"
                        + ".replace(/\\n/g, ' | ').slice(0, 400);")
            }
            at(10) { NSLog("PWUI title=%@", controller.activeTab?.title ?? "-") }
            at(11) {
                controller.navigate(
                    to: "data:text/html,<h1>file dialog test</h1>"
                        + "<input id=f type=file style='font-size:20px'>")
            }
            at(14) { controller.activeTab?.clickAt(x: 68, y: 78) }
            at(17) { shot("test-filedialog") }

        case "command":
            at(3) { controller.openCommandBar(mode: .newTab) }
            at(4) { controller.commandQuery = "news.ycombinator.com" }
            at(5) { shot("test-command") }
            at(6) {
                NSLog(
                    "COMMAND results=%@",
                    controller.commandResults.map(\.id).joined(separator: ", "))
                controller.runSelectedCommand()
            }
            at(10) {
                NSLog(
                    "COMMAND opened url=%@ tabs=%d",
                    controller.activeTab?.currentURL ?? "-",
                    controller.activeSpace.tabs.count)
            }
            at(11) { controller.openCommandBar(mode: .newTab) }
            at(12) { controller.commandQuery = "hacker" }
            at(13) {
                NSLog(
                    "COMMAND search results=%@",
                    controller.commandResults.map(\.id).joined(separator: ", "))
            }
            at(16) { shot("test-command-search") }
            at(18) { controller.closeCommandBar() }

        case "passwords":
            runPasswords(controller)

        case "codes":
            runCodes(controller)

        case "sidebar":
            // The screen may be asleep, so the sidebar is rendered offscreen
            // instead of captured.
            at(3) {
                MainActor.assumeIsolated {
                renderSidebar(controller, name: "sidebar")
                let first = controller.activeSpace.tabs.first?.id
                if let first { controller.togglePin(first) }
                renderSidebar(controller, name: "sidebar-pinned")
                if let first { controller.togglePin(first) }
                }
                NSApp.terminate(nil)
            }

        default:
            break
        }
    }

    private static func describe(_ label: String, _ controller: BrowserController) {
        for space in controller.spaces {
            let tabs = space.tabs.map {
                "\($0.isPinned ? "📌" : "")\($0.displayTitle)"
            }
            NSLog(
                "ORGANIZE %@: space=%@ active=%@ tabs=[%@]", label, space.name,
                space.id == controller.activeSpaceID ? "yes" : "no",
                tabs.joined(separator: " | "))
        }
    }

    // Verifies layout without relying on the screen being awake.
    private static func dump(_ label: String, _ controller: BrowserController) {
        let main = NSApp.windows.first { $0.title == "cha" }
        let tab = main?.childWindows?.first
        NSLog(
            "LAYOUT %@: main=%@ tab=%@ sidebar=%@", label,
            NSStringFromRect(main?.frame ?? .zero),
            NSStringFromRect(tab?.frame ?? .zero),
            controller.sidebarVisible ? "on" : "off")
    }

    @MainActor
    private static func renderSidebar(_ controller: BrowserController, name: String) {
        let renderer = ImageRenderer(
            content: SidebarView(controller: controller)
                .frame(width: 260, height: 640))
        renderer.scale = 2
        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            NSLog("SIDEBAR render failed")
            return
        }
        try? png.write(to: URL(fileURLWithPath: "build/\(name).png"))
        NSLog("SIDEBAR wrote build/%@.png", name)
    }

    static func at(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body)
    }

    // A picture of the main window drawn from its views, with the active
    // tab's page laid over the content area: works off screen and while the
    // display sleeps, unlike screencapture.
    static func shot(_ name: String) {
        guard let window = NSApp.windows.first(where: { $0 is BrowserWindow }),
            let content = window.contentView
        else { return }
        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        content.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        if let page = window.childWindows?.first(where: { $0.isVisible && !($0 is NSPanel) }),
            let pageView = page.contentView,
            let pageRep = pageView.bitmapImageRepForCachingDisplay(in: pageView.bounds)
        {
            pageView.cacheDisplay(in: pageView.bounds, to: pageRep)
            let origin = NSPoint(
                x: page.frame.minX - window.frame.minX, y: page.frame.minY - window.frame.minY)
            image.lockFocus()
            pageRep.draw(in: NSRect(origin: origin, size: page.frame.size))
            image.unlockFocus()
        }
        guard let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: "build/shots/\(name).png"))
        NSLog("SHOT build/shots/%@.png", name)
    }
}

// Verification codes: the generator against the RFC 6238 vectors, then the
// fill into the two shapes of form that ask for a code.
extension TestScenarios {
    // RFC 6238 appendix B, SHA-1, secret "12345678901234567890".
    static func checkTOTP() {
        let entry = CodeEntry(
            label: "test", site: "", secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
            digits: 8)
        let vectors: [(Double, String)] = [
            (59, "94287082"), (1_111_111_109, "07081804"),
            (1_234_567_890, "89005924"), (2_000_000_000, "69279037"),
            (20_000_000_000, "65353130"),
        ]
        for (time, expected) in vectors {
            let got = entry.code(at: Date(timeIntervalSince1970: time)) ?? "-"
            NSLog(
                "CODES totp t=%.0f expected=%@ got=%@ %@", time, expected, got,
                got == expected ? "ok" : "FAIL")
        }
        let parsed = OTPAuth.parse(
            "otpauth://totp/Keycloak:stas?secret=GEZDGNBVGY3TQOJQ&issuer=Keycloak&digits=6",
            site: "auth.example.com")
        NSLog(
            "CODES parse label=%@ site=%@ digits=%d code=%@",
            parsed?.label ?? "-", parsed?.site ?? "-", parsed?.digits ?? 0,
            parsed?.code ?? "-")
        let rows = parseCSV(
            "Title,URL,Username,Password,Notes,OTPAuth\n"
                + "Keycloak,https://auth.example.com/,stas,hunter2,,"
                + "otpauth://totp/Keycloak:stas?secret=GEZDGNBVGY3TQOJQ\n")
        NSLog("CODES csv rows=%d columns=%d", rows.count, rows.last?.count ?? 0)
    }

    // A Keycloak-style single field, then a row of one-character boxes.
    static let otpPage =
        "data:text/html,<form><input id=otp name=otp autocomplete=off></form>"
    static let boxesPage =
        "data:text/html,<form>"
            + "<input maxlength=1 autocomplete=one-time-code><input maxlength=1>"
            + "<input maxlength=1><input maxlength=1><input maxlength=1>"
            + "<input maxlength=1></form>"

    static func runCodes(_ controller: BrowserController) {
        at(1) { checkTOTP() }
        let entry = CodeStore.shared.add(
            CodeEntry(
                label: "Test code", site: "", secret: "GEZDGNBVGY3TQOJQ"))
        at(2) { controller.newTab(url: otpPage) }
        at(5) { controller.fill(entry) }
        at(6) {
            controller.activeTab?.executeJavaScript(
                "document.title = 'SINGLE [' + document.getElementById('otp').value + ']'")
        }
        at(8) {
            NSLog(
                "CODES fill %@ expected=%@", controller.activeTab?.title ?? "-",
                entry.code ?? "-")
            controller.navigate(to: boxesPage)
        }
        at(11) { controller.fill(entry) }
        at(12) {
            controller.activeTab?.executeJavaScript(
                """
                document.title = 'BOXES [' + Array.from(
                  document.querySelectorAll('input')).map(i => i.value).join('') + ']';
                """)
        }
        at(14) {
            NSLog(
                "CODES boxes %@ expected=%@", controller.activeTab?.title ?? "-",
                entry.code ?? "-")
            CodeStore.shared.remove(entry.id)
            NSApp.terminate(nil)
        }
    }
}

// Password manager checks. The Save button lives in a Chrome bubble window, so
// the click is synthesized inside our own process; results come back through
// document.title, which the app already observes.
extension TestScenarios {
    static let loginPage = "https://the-internet.herokuapp.com/login"

    static func runPasswords(_ controller: BrowserController) {
        at(2) { controller.newTab(url: loginPage) }
        at(7) {
            controller.activeTab?.executeJavaScript(
                """
                for (const [id, v] of [['username', 'tomsmith'],
                                       ['password', 'SuperSecretPassword!']]) {
                  const el = document.getElementById(id);
                  el.focus(); el.value = v;
                  el.dispatchEvent(new Event('input', {bubbles: true}));
                  el.dispatchEvent(new Event('change', {bubbles: true}));
                }
                document.querySelector('button[type=submit]').click();
                """)
        }
        at(10) { listWindows("t10") }
        at(12) { listWindows("t12") }
        at(13) { clickSaveButton() }
        at(15) { listWindows("after save click") }
        at(16) { controller.navigate(to: loginPage) }
        at(20) {
            // Chrome hides autofilled values from scripts until the user
            // interacts with the page, so click in it first.
            controller.activeTab?.clickAt(x: 400, y: 500)
        }
        at(21) {
            // Report what the page sees back through the title.
            controller.activeTab?.executeJavaScript(
                """
                document.title = 'AUTOFILL user=[' +
                  document.getElementById('username').value + '] pass=[' +
                  document.getElementById('password').value + ']';
                """)
        }
        at(23) {
            NSLog("AUTOFILL RESULT: %@", controller.activeTab?.title ?? "-")
            shot("test-autofill")
        }
    }

    private static var appWindows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible }
    }

    private static func listWindows(_ label: String) {
        for window in NSApp.windows {
            NSLog(
                "WINDOW %@: class=%@ title=%@ frame=%@ visible=%d key=%d children=%d",
                label, String(describing: type(of: window)), window.title,
                NSStringFromRect(window.frame), window.isVisible ? 1 : 0,
                window.isKeyWindow ? 1 : 0, window.childWindows?.count ?? 0)
            for child in window.childWindows ?? [] {
                NSLog(
                    "  CHILD %@: class=%@ frame=%@ visible=%d", label,
                    String(describing: type(of: child)),
                    NSStringFromRect(child.frame), child.isVisible ? 1 : 0)
            }
        }
    }

    // Chrome's password bubble is a Views window titled "Save password?".
    // Save is its default button, so Return accepts it.
    private static func clickSaveButton() {
        guard let bubble = NSApp.windows.first(where: {
            $0.isVisible && $0.title.contains("Save password")
        }) else {
            NSLog("AUTOFILL: no bubble window found")
            return
        }
        NSLog("AUTOFILL: accepting bubble %@", NSStringFromRect(bubble.frame))
        bubble.makeKeyAndOrderFront(nil)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: bubble.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36)
            {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }
}
