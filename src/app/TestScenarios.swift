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

        case "spaces":
            SpaceChecks.run(controller)

        case "ui":
            UIChecks.run(controller)

        case "arclike":
            // The same sidebar as the Arc reference screenshot (pinned tabs,
            // the second one open, graphite theme, dark, ~193 pt sidebar, a
            // 1114×669 window), for a side-by-side picture.
            NSApp.appearance = NSAppearance(named: .darkAqua)
            var space = controller.activeSpace
            space.name = "Work"
            space.symbol = "calendar"
            let names = [
                "Timeline - CTD Services Plan", "Confluence", "Calendar", "Home",
                "All Projects", "Rare", "Service Planning", "Road Map Prototype",
                "[OST Service Team] release notes",
            ]
            space.tabs = names.map {
                var tab = TabData(url: "data:text/html,<title>\($0)</title>", isPinned: true)
                tab.title = $0
                return tab
            }
            space.theme = SpaceTheme.presets[8]
            controller.replace(space)
            if let window = controller.window {
                var frame = window.frame
                frame.origin.y += frame.height - 669
                frame.size = NSSize(width: 1114, height: 669)
                window.setFrame(frame, display: true)
            }
            controller.setSidebarWidth(227)
            controller.activateTab(space.tabs[0].id)
            at(2) { shot("arclike") }
            at(3) { NSApp.terminate(nil) }

        case "newtablinks":
            // Links that ask for a new tab must become cha's tabs, never a
            // window of Chromium's own: ⌘T with a page in front, then ⌘-click.
            let page = "data:text/html,<title>Links</title><a id=l href='about:blank' "
                + "style='position:fixed;left:0;top:0;width:300px;height:100px;display:block'>link</a>"
            var before = 0
            func strays() -> [NSWindow] {
                NSApp.windows.filter {
                    $0.isVisible && $0.parent == nil && !($0 is BrowserWindow) && !($0 is NSPanel)
                        && $0.frame.width > 300
                }
            }
            at(1) { controller.newTab(url: page) }
            at(3) {
                guard let window = controller.activeTab?.nativeWindow,
                    let key = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [.command],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false,
                        keyCode: 17)
                else { return }
                NSApp.sendEvent(key)
            }
            at(4) {
                SpaceChecks.check("⌘T over a page opens cha's command bar",
                    controller.commandPanel?.isVisible == true && controller.commandMode == .newTab)
                SpaceChecks.check("and no Chromium window", strays().isEmpty)
                controller.closeCommandBar()
                before = controller.activeSpace.tabs.count
                controller.activeTab?.clickAt(x: 50, y: 50, modifiers: 1 << 7)
            }
            at(6) {
                SpaceChecks.check("⌘-click adds a cha tab", controller.activeSpace.tabs.count == before + 1,
                    "\(before) → \(controller.activeSpace.tabs.count)")
                SpaceChecks.check("in the background", controller.activeTab?.title == "Links",
                    controller.activeTab?.title ?? "-")
                SpaceChecks.check("no Chromium window", strays().isEmpty)
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "quitkey":
            // ⌘Q as the keyboard sends it, with the page's window in front.
            at(2.5) {
                guard let page = controller.activeTab?.nativeWindow,
                    let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [.command],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: page.windowNumber, context: nil, characters: "q",
                        charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)
                else { return NSLog("QUITKEY no page window") }
                NSLog("QUITKEY sending ⌘Q, key window=%@", String(describing: NSApp.keyWindow.map { type(of: $0) }))
                NSApp.sendEvent(event)
            }
            at(8) { NSLog("QUITKEY still running 5.5 s after ⌘Q") }

        case "closewindow":
            // The red button: performClose on the main window.
            at(2.5) { controller.window.performClose(nil) }
            at(8) { NSLog("QUITKEY still running 5.5 s after closing the window") }

        case "find":
            // What ⌘F does: the key as macOS delivers it to the page's window,
            // then Chrome's own Find command; the windows are listed after each.
            at(1) {
                controller.navigate(
                    to: "data:text/html,<title>Find</title><p>alpha beta gamma beta</p>")
            }
            at(3) { listWindows("before") }
            at(3.5) {
                guard let page = controller.activeTab?.nativeWindow,
                    let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [.command],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: page.windowNumber, context: nil, characters: "f",
                        charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)
                else { return }
                NSLog("FIND menu handles ⌘F: %d", NSApp.mainMenu?.performKeyEquivalent(with: event) == true ? 1 : 0)
                page.sendEvent(event)
            }
            at(5) { listWindows("after ⌘F") }
            at(5.5) {
                let tab = controller.activeTab
                NSLog("FIND can execute IDC_FIND: %d", tab?.canExecuteChromeCommand(37000) == true ? 1 : 0)
                tab?.executeChromeCommand(37000)
            }
            at(7) { listWindows("after IDC_FIND") }
            at(8) { NSApp.terminate(nil) }

        case "pip":
            // Picture in picture without opening the floating window (it
            // would land on the screen in use): the user-gesture path, and
            // which video the scripts pick.
            let page = """
                data:text/html,<title>pip</title><canvas id=c width=64 height=36></canvas>
                <video id=small muted width=40></video><video id=big muted width=320></video>
                <script>
                const c = document.getElementById('c'), x = c.getContext('2d');
                setInterval(() => { x.fillStyle = 'rgb(' + Math.floor(Math.random()*255) + ',90,140)'; x.fillRect(0,0,64,36); }, 50);
                for (const id of ['small', 'big']) {
                  const v = document.getElementById(id); v.srcObject = c.captureStream(20); }
                document.getElementById('big').play();
                </script>
                """
            at(1) { controller.newTab(url: page) }
            at(4) {
                controller.activeTab?.executeJavaScript(
                    withUserGesture: "document.title = 'gesture ' + navigator.userActivation.isActive")
            }
            at(5) {
                let ok = controller.activeTab?.title == "gesture true"
                NSLog("CHECK %@ scripts run with a user gesture (%@)", ok ? "ok  " : "FAIL", controller.activeTab?.title ?? "-")
                if ok { SpaceChecks.passed += 1 } else { SpaceChecks.failed += 1 }
                controller.activeTab?.executeJavaScript(
                    "(() => { \(PictureInPicture.pickVideo) document.title = 'picked ' + (video ? video.id : 'none'); })()")
            }
            at(6) {
                let ok = controller.activeTab?.title == "picked big"
                NSLog("CHECK %@ picks the playing video (%@)", ok ? "ok  " : "FAIL", controller.activeTab?.title ?? "-")
                if ok { SpaceChecks.passed += 1 } else { SpaceChecks.failed += 1 }
            }
            at(6.5) {
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "openurl":
            // A link from another app, as the GetURL Apple event delivers it.
            at(1.5) {
                let event = NSAppleEventDescriptor(
                    eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                    targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                    transactionID: AETransactionID(kAnyTransactionID))
                event.setParam(
                    NSAppleEventDescriptor(string: "data:text/html,<title>From outside</title>"),
                    forKeyword: keyDirectObject)
                URLOpener.shared.handleGetURL(event, withReplyEvent: NSAppleEventDescriptor.null())
            }
            var tabsBefore = 0
            at(1.4) { tabsBefore = controller.activeSpace.tabs.count }
            at(3.5) {
                let little = LittleWindowController.open.first
                SpaceChecks.check("a link from another app opens a little window", little != nil)
                SpaceChecks.check(
                    "the page loads in it", little?.tab.currentURL.contains("From outside") == true,
                    little?.tab.currentURL ?? "-")
                SpaceChecks.check(
                    "its page sits under the bar",
                    little.map { l in
                        let page = l.tab.nativeWindow?.frame ?? .zero
                        return page.maxY <= l.window.frame.maxY - LittleWindowController.barHeight + 1
                            && page.minX >= l.window.frame.minX
                    } ?? false)
                SpaceChecks.check("the main window is left as it was", controller.activeSpace.tabs.count == tabsBefore)
                little?.openInMain()
            }
            at(4.5) {
                SpaceChecks.check("Open in cha closes the little window", LittleWindowController.open.isEmpty)
                SpaceChecks.check(
                    "and the page is a tab of the main window, same browser",
                    controller.activeTab?.currentURL.contains("From outside") == true
                        && controller.activeSpace.tabs.count == tabsBefore + 1)
                controller.openLittleWindow("data:text/html,<title>Throwaway</title>")
            }
            at(6) {
                let little = LittleWindowController.open.first
                little?.close()
            }
            at(7) {
                SpaceChecks.check("closing it closes the page too", LittleWindowController.open.isEmpty)
                SpaceChecks.check("and leaves the main window alone", controller.activeSpace.tabs.count == tabsBefore + 1)
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

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

    // The real screen where the main window is, pages included. Only for
    // windowed runs (scripts/check.sh window), which happen when nobody is
    // at this Mac.
    static func screenShot(_ name: String) {
        guard let window = NSApp.windows.first(where: { $0 is BrowserWindow }) else { return }
        // screencapture counts from the top left of the main display.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let f = window.frame
        let rect = "\(Int(f.minX)),\(Int(top - f.maxY)),\(Int(f.width)),\(Int(f.height))"
        NSLog("SHOT window %@ frame=%@ rect=%@ level=%d visible=%d", name, NSStringFromRect(f), rect, window.level.rawValue, window.isVisible ? 1 : 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R\(rect)", "build/shots/\(name).png"]
        try? process.run()
        process.waitUntilExit()
    }

    // A picture of the main window drawn from its views, with the active
    // tab's page laid over the content area: works off screen and while the
    // display sleeps, unlike screencapture.
    static func shot(_ name: String) {
        if !Diagnostics.headless, !Diagnostics.screenMissing { screenShot(name + "-window") }
        guard let window = NSApp.windows.first(where: { $0 is BrowserWindow }),
            let content = window.contentView
        else { return }
        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        content.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        // Chromium's pixels don't come through cacheDisplay, so the page is
        // drawn as a plain card where its window sits, to judge the layout.
        if let page = window.childWindows?.first(where: { $0.isVisible && !($0 is NSPanel) }) {
            let rect = NSRect(
                x: page.frame.minX - window.frame.minX, y: page.frame.minY - window.frame.minY,
                width: page.frame.width, height: page.frame.height)
            let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            image.lockFocus()
            (dark ? NSColor(white: 0.13, alpha: 1) : NSColor.white).setFill()
            NSBezierPath(
                roundedRect: rect, xRadius: BrowserController.contentCornerRadius,
                yRadius: BrowserController.contentCornerRadius
            ).fill()
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
        // The code changes every 30 s; what counts is the one typed in.
        var typed = ["", ""]
        at(2) { controller.newTab(url: otpPage) }
        at(5) {
            typed[0] = entry.code ?? "-"
            controller.fill(entry)
        }
        at(6) {
            controller.activeTab?.executeJavaScript(
                "document.title = 'SINGLE [' + document.getElementById('otp').value + ']'")
        }
        at(8) {
            NSLog(
                "CODES fill %@ expected=%@", controller.activeTab?.title ?? "-", typed[0])
            controller.navigate(to: boxesPage)
        }
        at(11) {
            typed[1] = entry.code ?? "-"
            controller.fill(entry)
        }
        at(12) {
            controller.activeTab?.executeJavaScript(
                """
                document.title = 'BOXES [' + Array.from(
                  document.querySelectorAll('input')).map(i => i.value).join('') + ']';
                """)
        }
        at(14) {
            NSLog(
                "CODES boxes %@ expected=%@", controller.activeTab?.title ?? "-", typed[1])
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

    static func listWindows(_ label: String) {
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
