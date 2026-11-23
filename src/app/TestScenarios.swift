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

        case "peek":
            // Peek, against a real web server where localhost and 127.0.0.1
            // are two sites (scripts/check.sh serves the pages).
            let port = ProcessInfo.processInfo.environment["CHA_TEST_PORT"] ?? "0"
            let home = "http://localhost:\(port)/a.html"
            func click(_ id: String) {
                controller.activeTab?.executeJavaScript(withUserGesture: "document.getElementById('\(id)').click()")
            }
            func here() -> String { controller.activeTab?.currentURL ?? "-" }
            at(1) {
                controller.newTab(url: home)
            }
            at(3) {
                controller.togglePin(controller.activeTabID!)
                click("other")
            }
            at(4.5) {
                SpaceChecks.check("a pinned tab's link to another site opens a Peek", controller.peek != nil)
                SpaceChecks.check(
                    "with that site in it", controller.peek?.tab.currentURL.contains("127.0.0.1") == true,
                    controller.peek?.tab.currentURL ?? "-")
                SpaceChecks.check("and the pinned tab stays where it was", here() == home, here())
                if let card = controller.peek?.tab.nativeWindow?.frame {
                    SpaceChecks.check(
                        "the Peek sits over the page, inside it",
                        controller.contentScreenRect.contains(card) && card.width < controller.contentScreenRect.width,
                        NSStringFromRect(card))
                }
                controller.peek?.close()
            }
            at(5.2) {
                SpaceChecks.check("closing the Peek leaves the tab as it was", controller.peek == nil && here() == home)
                click("same")
            }
            at(6.5) {
                SpaceChecks.check("a link within the site goes there, no Peek",
                    controller.peek == nil && here().hasSuffix("/b.html") && here().contains("localhost"), here())
                controller.navigate(to: home)
            }
            at(7.5) {
                controller.togglePin(controller.activeTabID!)  // An ordinary tab now.
                click("other")
            }
            at(9) {
                SpaceChecks.check("an ordinary tab just follows the link", controller.peek == nil && here().contains("127.0.0.1"), here())
                controller.navigate(to: home)
            }
            at(10.5) {
                // ⇧-click with the real mouse event, on the fixed link.
                controller.activeTab?.clickAt(x: 60, y: 160, modifiers: 1 << 1)
            }
            at(12) {
                SpaceChecks.check("⇧-click opens any link in a Peek", controller.peek != nil, here())
                let tabsBefore = controller.activeSpace.tabs.count
                controller.peek?.expand()
                SpaceChecks.check("expanding makes it a tab", controller.peek == nil
                    && controller.activeSpace.tabs.count == tabsBefore + 1)
            }
            at(13) {
                SpaceChecks.check("the open tab is the Peek's page", here().contains("127.0.0.1"), here())
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "popup":
            // "Sign in with Google" as tre.ge has it: the page opens a sized
            // popup on another site, which answers through window.opener and
            // closes itself. As a cha tab it had no opener and never answered.
            let port = ProcessInfo.processInfo.environment["CHA_TEST_PORT"] ?? "0"
            var tabsBefore = 0
            at(1) { controller.newTab(url: "http://localhost:\(port)/popup.html") }
            at(3) {
                tabsBefore = controller.activeSpace.tabs.count
                controller.activeTab?.executeJavaScript(withUserGesture: "document.getElementById('go').click()")
            }
            at(4.5) {
                SpaceChecks.check("the popup is a window of its own", ChaTab.openPopupCount == 1,
                    "\(ChaTab.openPopupCount)")
                SpaceChecks.check("not a cha tab", controller.activeSpace.tabs.count == tabsBefore,
                    "\(tabsBefore) → \(controller.activeSpace.tabs.count)")
                if Diagnostics.headless {
                    let shown = NSApp.windows.filter { w in
                        w.isVisible && NSScreen.screens.contains { $0.frame.intersects(w.frame) }
                    }
                    SpaceChecks.check("headless: nothing on screen", shown.isEmpty,
                        shown.map { NSStringFromRect($0.frame) }.joined(separator: " "))
                }
            }
            at(8) {
                SpaceChecks.check("the page got the popup's answer through window.opener",
                    controller.activeTab?.title == "GOT signed-in", controller.activeTab?.title ?? "-")
                SpaceChecks.check("the popup closed itself", ChaTab.openPopupCount == 0,
                    "\(ChaTab.openPopupCount)")
                SpaceChecks.check("the tab stays", controller.activeSpace.tabs.count == tabsBefore
                    && controller.activeTab?.currentURL.contains("popup.html") == true,
                    controller.activeTab?.currentURL ?? "-")
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "profiles":
            // Accounts per space: each profile keeps its own site data.
            let file = Persistence.directory.appendingPathComponent("storage.html")
            try? """
                <script>
                const q = location.search.slice(1);
                if (q) localStorage.setItem('who', q);
                document.title = 'who=' + (localStorage.getItem('who') || 'none');
                </script>
                """.write(to: file, atomically: true, encoding: .utf8)
            let url = file.absoluteString
            var a = UUID(), b = UUID(), cc = UUID()
            func title() -> String { controller.activeTab?.title ?? "-" }
            func check(_ name: String, _ want: String) {
                SpaceChecks.check(name, title() == want, title())
            }
            at(1) {
                a = controller.activeSpaceID
                controller.newTab(url: url + "?alpha")
            }
            at(3) {
                check("space A writes in the default profile", "who=alpha")
                controller.addSpace()
                b = controller.activeSpaceID
                controller.finishEditing()
                let work = controller.addProfile(named: "Work")
                controller.setProfile(work.id, for: b)
                controller.newTab(url: url)
            }
            at(5) {
                check("space B with its own profile sees none of it", "who=none")
                controller.navigate(to: url + "?beta")
            }
            at(7) {
                check("space B writes its own", "who=beta")
                controller.addSpace()
                cc = controller.activeSpaceID
                controller.finishEditing()
                controller.setProfile(controller.space(b)?.profileID, for: cc)
                controller.newTab(url: url)
            }
            at(9) {
                check("space C sharing B's profile sees B's", "who=beta")
                controller.selectSpace(a, animated: false)
                controller.newTab(url: url)
            }
            at(11) {
                check("space A still has its own", "who=alpha")
                let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: Persistence.directory.path)) ?? [])
                    .filter { $0.hasPrefix("Profile-") }
                SpaceChecks.check("the profile has its own folder", dirs.count == 1, "\(dirs)")
                controller.selectSpace(b, animated: false)
                controller.navigate(to: url)
            }
            at(12) { controller.setProfile(nil, for: b) }
            at(14) {
                check("space B moved to the default profile reloads in it", "who=alpha")
                controller.save()
                let saved = Persistence.load()
                SpaceChecks.check(
                    "profiles saved", saved.profiles?.count == 1
                        && saved.spaces.first { $0.id == cc }?.profileID == saved.profiles?.first?.id)
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "download":
            // A real download: saved where it should be, listed, and no window
            // of Chromium's (its download bubble) pops up when it is done.
            let page = "data:text/html,<title>Download</title>"
                + "<a id=d href='data:text/plain;base64,aGVsbG8gZnJvbSBjaGE=' download='hello.txt'>get</a>"
            at(1) { controller.newTab(url: page) }
            at(3) {
                controller.activeTab?.executeJavaScript(withUserGesture: "document.getElementById('d').click()")
            }
            at(6) {
                let store = DownloadStore.shared
                let item = store.items.first
                SpaceChecks.check("download listed", item != nil)
                SpaceChecks.check("download complete", item?.state == "complete", item?.state ?? "-")
                let saved = item.map { (try? String(contentsOfFile: $0.path, encoding: .utf8)) ?? "" } ?? ""
                SpaceChecks.check("file saved with its content", saved == "hello from cha", item?.path ?? "-")
                let popups = NSApp.windows.filter {
                    $0.isVisible && String(describing: type(of: $0)).contains("NativeWidget")
                }
                SpaceChecks.check("no Chromium window pops up", popups.isEmpty,
                    popups.map { NSStringFromRect($0.frame) }.joined(separator: " "))
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "window":
            // The window comes back: hidden, then ⌘N as the menu has it.
            at(2) { controller.window.orderOut(nil) }
            at(2.5) {
                SpaceChecks.check("window hidden", controller.window.isVisible == false)
                guard let item = NSApp.mainMenu?.items.compactMap(\.submenu)
                    .flatMap(\.items).first(where: { $0.title == "New Window" })
                else { return SpaceChecks.check("New Window in the menu", false) }
                SpaceChecks.check("⌘N is New Window", item.keyEquivalent == "n"
                    && item.keyEquivalentModifierMask == [.command])
                NSApp.sendAction(item.action!, to: item.target, from: item)
            }
            at(3.5) {
                SpaceChecks.check("⌘N shows the window", controller.window.isVisible)
                SpaceChecks.check("with its page", controller.activeTab?.nativeWindow?.isVisible == true)
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

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
            var opensBefore = 0
            var closed: UUID?
            at(3) {
                opensBefore = controller.commandBarOpens
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
                // What matters is that ⌘T reached cha's menu; whether the bar
                // keeps the keyboard depends on the app being active, which
                // an off-screen run never is.
                SpaceChecks.check("⌘T over a page opens cha's command bar",
                    controller.commandBarOpens == opensBefore + 1 && controller.commandMode == .newTab,
                    "\(opensBefore) → \(controller.commandBarOpens)")
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
                // ⌘W, then ⌘⇧T as the keyboard makes it: AppKit matches a
                // shifted shortcut by the key and layout, which only an event
                // made from a CGEvent carries (NSEvent.keyEvent's doesn't match).
                closed = controller.activeTabID
                controller.closeActiveTab()
                guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: 17, keyDown: true) else { return }
                cg.flags = [.maskCommand, .maskShift]
                if let key = NSEvent(cgEvent: cg) { NSApp.sendEvent(key) }
            }
            at(8) {
                SpaceChecks.check("⌘⇧T over a page reopens the closed tab",
                    closed != nil && controller.activeTabID == closed && controller.activeTab?.title == "Links",
                    controller.activeTab?.title ?? "-")
                SpaceChecks.check("and no Chromium window", strays().isEmpty)
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

        case "media":
            // What a page can play, as a site sees it, and a real H.264/AAC
            // file actually decoding (cha's CEF is built with those codecs;
            // the stock one plays only VP9/AV1/Opus). Widevine is reported,
            // not checked: Chromium downloads it in the background.
            let port = ProcessInfo.processInfo.environment["CHA_TEST_PORT"] ?? "0"
            let probe = """
                (async () => {
                  const v = document.createElement('video'), r = [];
                  for (const [n, t] of [['h264', 'video/mp4; codecs="avc1.42E01E"'], ['aac', 'audio/mp4; codecs="mp4a.40.2"'],
                      ['hevc', 'video/mp4; codecs="hvc1.1.6.L93.B0"'], ['vp9', 'video/webm; codecs="vp9"'],
                      ['av1', 'video/mp4; codecs="av01.0.05M.08"'], ['opus', 'audio/webm; codecs="opus"']])
                    r.push(n + '=' + (v.canPlayType(t) === 'probably' && MediaSource.isTypeSupported(t) ? 'yes' : 'no'));
                  for (const ks of ['com.widevine.alpha', 'org.w3.clearkey']) {
                    try { await navigator.requestMediaKeySystemAccess(ks, [{videoCapabilities: [{contentType: 'video/mp4; codecs="avc1.42E01E"'}, {contentType: 'video/webm; codecs="vp9"'}]}]); r.push(ks + '=yes'); }
                    catch (e) { r.push(ks + '=no'); } }
                  document.title = 'MEDIA ' + r.join(' ');
                })()
                """
            let play = """
                (() => {
                  const v = document.createElement('video');
                  v.muted = true; v.src = '/h264-aac.mp4'; document.body.append(v);
                  v.play().catch(e => document.title = 'PLAY error ' + e.name);
                  v.onerror = () => document.title = 'PLAY error ' + (v.error && v.error.code);
                  setTimeout(() => document.title = 'PLAY w=' + v.videoWidth + ' t=' + v.currentTime.toFixed(1) +
                    ' frames=' + v.webkitDecodedFrameCount + ' audio=' + v.webkitAudioDecodedByteCount, 1500);
                })()
                """
            func title() -> String { controller.activeTab?.title ?? "-" }
            func field(_ name: String) -> Double {
                title().split(separator: " ").first { $0.hasPrefix(name + "=") }
                    .flatMap { Double($0.dropFirst(name.count + 1)) } ?? 0
            }
            at(1) { controller.newTab(url: "http://127.0.0.1:\(port)/") }
            at(3) { controller.activeTab?.executeJavaScript(probe) }
            at(4) {
                NSLog("%@", title())
                for codec in ["h264", "aac", "hevc", "vp9", "av1", "opus"] {
                    SpaceChecks.check("a page may play \(codec)", title().contains(" \(codec)=yes"), title())
                }
                controller.activeTab?.executeJavaScript(play)
            }
            at(7) {
                NSLog("%@", title())
                SpaceChecks.check("an H.264/AAC file plays: picture", field("w") == 64 && field("frames") > 5, title())
                SpaceChecks.check("and sound", field("audio") > 0, title())
                SpaceChecks.check("and time runs", field("t") > 0.5, title())
                // A page that asks "leave site?" (Meet in a call) and that
                // the user has clicked in: ⌘W must still end it, sound and
                // all, not leave it running behind an invisible prompt.
                controller.activeTab?.executeJavaScript(
                    "window.onbeforeunload = e => { e.preventDefault(); e.returnValue = ''; }; document.title = 'ASKS'")
            }
            var asking: ChaTab?
            at(8) {
                asking = controller.activeTab
                asking?.clickAt(x: 20, y: 20)
            }
            at(8.5) { asking?.executeJavaScript("document.title = 'ASKS clicked=' + navigator.userActivation.hasBeenActive") }
            at(9) {
                SpaceChecks.check("the page asks before leaving, and was clicked", title() == "ASKS clicked=true", title())
                controller.closeActiveTab()
            }
            // The same in a little window (a Meet link from Slack opens
            // there), playing sound, closed as ⌘W closes it.
            let asks = "window.onbeforeunload = e => { e.preventDefault(); e.returnValue = ''; };" +
                "const c = new AudioContext(), o = c.createOscillator(); o.connect(c.destination); o.start();" +
                "document.onclick = () => c.resume();" +
                "document.title = 'ASKS'"
            var little: LittleWindowController?
            at(12) {
                SpaceChecks.check("⌘W ends a page that asks before leaving", asking?.isClosed == true)
                controller.openLittleWindow("http://127.0.0.1:\(port)/")
                little = LittleWindowController.open.last
            }
            at(14) {
                little?.tab.executeJavaScript(asks)
            }
            at(14.5) { little?.tab.clickAt(x: 20, y: 20) }
            at(15) {
                little?.tab.executeJavaScript(
                    "document.title = 'ASKS clicked=' + navigator.userActivation.hasBeenActive + ' ' + c.state")
            }
            at(16) {
                let t = little?.tab.title ?? "-"
                SpaceChecks.check("a little window's page asks, was clicked, plays", t == "ASKS clicked=true running", t)
                little?.close()
            }
            at(19) {
                SpaceChecks.check("closing the little window ends its page", little?.tab.isClosed == true)
                // A call asking for its own floating window (Meet does,
                // when its tab is left).
                controller.newTab(url: "http://127.0.0.1:\(port)/")
            }
            var floating: ChaTab?
            var tabCount = 0
            at(21) {
                floating = controller.activeTab
                tabCount = controller.activeSpace.tabs.count
                floating?.executeJavaScript(withUserGesture:
                    "documentPictureInPicture.requestWindow({width: 300, height: 200}).then(" +
                    "w => document.title = 'PIP open', e => document.title = 'PIP error ' + e.name)")
            }
            at(23) {
                // Off in the checks (it would open on screen): the request
                // fails, and no empty tab stands in for the floating window.
                SpaceChecks.check("a floating-window request opens no empty tab",
                    controller.activeSpace.tabs.count == tabCount && controller.activeTab === floating,
                    "\(controller.activeSpace.tabs.count) tabs, was \(tabCount); \(floating?.title ?? "-")")
                controller.closeActiveTab()
            }
            at(26) {
                SpaceChecks.check("⌘W ends the page that asked for it", floating?.isClosed == true)
                // A call left for another tab, then closed from the sidebar.
                controller.newTab(url: "http://127.0.0.1:\(port)/")
            }
            var behind: ChaTab?
            var behindID: UUID?
            at(28) {
                behind = controller.activeTab
                behindID = controller.activeSpace.activeTabID
                behind?.executeJavaScript(asks)
            }
            at(28.5) { behind?.clickAt(x: 20, y: 20) }
            at(29) {
                behind?.executeJavaScript(
                    "document.title = 'ASKS clicked=' + navigator.userActivation.hasBeenActive + ' ' + c.state")
            }
            at(30) {
                let t = behind?.title ?? "-"
                SpaceChecks.check("a page asks before leaving, clicked", t.hasPrefix("ASKS clicked=true"), t)
                controller.newTab(url: "https://example.com/")
            }
            at(32) { if let behindID { controller.closeTab(behindID) } }
            at(35) {
                SpaceChecks.check("closing it from the sidebar ends it", behind?.isClosed == true)
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "closevideo":
            // A real video site: playing, then closed with ⌘W. CHA_TEST_URL
            // picks the page.
            let url = ProcessInfo.processInfo.environment["CHA_TEST_URL"] ?? "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
            var page: ChaTab?
            at(1) { controller.newTab(url: url) }
            at(8) {
                page = controller.activeTab
                page?.executeJavaScript(withUserGesture:
                    "const v = document.querySelector('video'); v && v.play(); 'x'")
            }
            at(12) {
                page?.executeJavaScript(
                    "const w = document.querySelector('video'); document.title = 'VIDEO ' + (w ? (w.paused ? 'paused' : 'playing') + ' t=' + w.currentTime.toFixed(1) : 'none')")
            }
            at(13) {
                NSLog("CLOSEVIDEO %@", page?.title ?? "-")
                controller.closeActiveTab()
            }
            at(17) {
                SpaceChecks.check("a closed video tab is gone", page?.isClosed == true, page?.title ?? "-")
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "hardreload":
            // ⇧⌘R as the keyboard sends it: the site's Cache Storage is
            // emptied and the page loads again; its localStorage stays.
            let port = ProcessInfo.processInfo.environment["CHA_TEST_PORT"] ?? "0"
            func title() -> String { controller.activeTab?.title ?? "-" }
            at(1) { controller.newTab(url: "http://127.0.0.1:\(port)/") }
            at(3) {
                controller.activeTab?.executeJavaScript(
                    "localStorage.k = 'kept'; window.marker = 1;" +
                    "caches.open('c').then(c => c.put('/x', new Response('x'))).then(() => caches.keys())" +
                    ".then(k => document.title = 'CACHED ' + k.length)")
            }
            at(4) {
                SpaceChecks.check("the page has a cache", title() == "CACHED 1", title())
                guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: 15, keyDown: true) else { return }
                cg.flags = [.maskCommand, .maskShift]
                if let key = NSEvent(cgEvent: cg) { NSApp.sendEvent(key) }
            }
            at(7) {
                controller.activeTab?.executeJavaScript(
                    "caches.keys().then(k => document.title = 'AFTER ' + k.length + ' ' + (window.marker ? 'same' : 'reloaded') + ' ' + localStorage.k)")
            }
            at(8) {
                SpaceChecks.check("⇧⌘R empties the cache, reloads, keeps site data", title() == "AFTER 0 reloaded kept", title())
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "calendar":
            // Google Calendar against scripts/google-fake.py (CHA_GOOGLE_BASE):
            // sign-in in a tab with PKCE, the next meeting in the sidebar,
            // Join, reminders, the token refreshed, disconnecting.
            let calendar = GoogleCalendar.shared
            let log = ProcessInfo.processInfo.environment["CHA_GOOGLE_LOG"] ?? "/dev/null"
            func fakeLog() -> String { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }
            let client = #"{"installed": {"client_id": "test-client", "client_secret": "test-secret"}}"#
            try? client.write(to: Persistence.directory.appendingPathComponent("google-client.json"), atomically: true, encoding: .utf8)
            var reminders: [(event: CalendarEvent, at: Date)] = []
            calendar.schedule = { reminders = $0 }
            var tabsBefore = 0
            at(1) {
                tabsBefore = controller.activeSpace.tabs.count
                calendar.connect()
            }
            at(4) { calendar.detailsFor = "now" }
            at(4.6) {
                let e = calendar.events.first
                SpaceChecks.check("guests: rooms left out, answers read",
                                  e?.guests.count == 18 && e.map { MeetingDetails.summary($0.guests) } == "18 guests · 9 yes · 1 no · 1 maybe · 7 awaiting"
                                  && e?.guests.contains { $0.isMe && $0.answer == .yes } == true
                                  && e?.guests.first?.organizer == true,
                                  e.map { MeetingDetails.summary($0.guests) } ?? "-")
                SpaceChecks.check("the description is plain text, the call link isn't a place",
                                  e?.notes == "Agenda:\n1. Demos & builds\n2. Plans for next week\nNotes in the doc." && e?.location == nil,
                                  "\(e?.notes ?? "-") | \(e?.location ?? "-")")
                SpaceChecks.check("hovering the card shows the meeting's details", UIFrames.frames["meetingDetails"] != nil)
                if let pop = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }) {
                    // The popover's material isn't drawn into the picture: light
                    // text would vanish on it, so the shot is in light mode.
                    pop.appearance = NSAppearance(named: .aqua)
                    pop.contentView?.layoutSubtreeIfNeeded()
                    pop.displayIfNeeded()
                    TestScenarios.shotWindow(pop, "calendar-details")
                }
                calendar.detailsFor = nil
            }
            at(5) {
                let token = Persistence.directory.appendingPathComponent("google-token.json")
                let mode = (try? FileManager.default.attributesOfItem(atPath: token.path)[.posixPermissions] as? Int) ?? 0
                SpaceChecks.check("signing in through a tab connects", calendar.connected && mode == 0o600, "\(calendar.connected) \(String(mode, radix: 8)) \(calendar.problem ?? "")")
                SpaceChecks.check("with PKCE", fakeLog().contains("token code pkce=True"), fakeLog())
                SpaceChecks.check("the sign-in tab closes by itself", controller.activeSpace.tabs.count == tabsBefore,
                                  "\(controller.activeSpace.tabs.map(\.url))")
                SpaceChecks.check("meetings only: declined, all-day, cancelled and past ones are left out",
                                  calendar.events.map(\.id) == ["now", "zoom", "later"], "\(calendar.events.map(\.id))")
                SpaceChecks.check("the meeting going on is the next one", calendar.next?.id == "now", calendar.next?.id ?? "-")
                SpaceChecks.check("call links: Meet's, and Zoom's from the place",
                                  calendar.events.first?.joinURL?.path == "/meet/abc-defg-hij"
                                  && (calendar.events.count > 1 ? calendar.events[1].joinURL?.host : nil) == "example.zoom.us", "\(calendar.events.map { $0.joinURL?.absoluteString ?? "-" })")
                SpaceChecks.check("a reminder a minute before each upcoming call",
                                  reminders.map(\.event.id) == ["zoom"]
                                  && reminders.first.map { abs($0.at.timeIntervalSince($0.event.start) + 60) < 1 } == true,
                                  "\(reminders.map(\.event.id))")
                SpaceChecks.check("the card is in the sidebar with Join",
                                  UIFrames.frames["meetingCard"] != nil && UIFrames.frames["meetingJoin"] != nil)
                SpaceChecks.check("it says it's on now", calendar.next.map { MeetingCard.when($0, now: Date()) }?.hasPrefix("Now · until") == true)
                TestScenarios.shot("calendar-now")
                if let url = calendar.next?.joinURL { controller.joinMeeting(url) }
            }
            at(7) {
                SpaceChecks.check("Join opens the call in a tab", controller.activeTab?.currentURL.contains("/meet/abc-defg-hij") == true,
                                  controller.activeTab?.currentURL ?? "-")
                calendar.dismissed.insert("now")
                calendar.refresh()  // the access token has run out by now
            }
            at(9) {
                SpaceChecks.check("an expired access token is refreshed", fakeLog().contains("token refresh ok=True")
                                  && fakeLog().components(separatedBy: "events valid=True").count >= 3, fakeLog())
                // "zoom" is 20 minutes on: just before midnight that is tomorrow.
                if Calendar.current.isDateInToday(Date().addingTimeInterval(20 * 60)) {
                    SpaceChecks.check("hiding a meeting brings up the next", calendar.next?.id == "zoom"
                                      && calendar.next.map { MeetingCard.when($0, now: Date()) }?.hasPrefix("In 2") == true
                                      && UIFrames.frames["meetingCard"] != nil, calendar.next.map { MeetingCard.when($0, now: Date()) } ?? "-")
                } else {
                    SpaceChecks.check("hiding the last meeting of the day empties the card", calendar.next == nil,
                                      calendar.next?.id ?? "-")
                }
                calendar.dismissed.insert("zoom")
                // "later" is two hours on: after 22:00 that is tomorrow, off the card.
                let laterIsToday = Calendar.current.isDateInToday(Date().addingTimeInterval(120 * 60))
                SpaceChecks.check(laterIsToday ? "a meeting hours away is on the card all day" : "tomorrow's meeting is not on the card",
                                  laterIsToday
                                    ? calendar.next?.id == "later" && calendar.next.map { MeetingCard.when($0, now: Date()) }?.hasPrefix("At ") == true
                                    : calendar.next == nil,
                                  calendar.next.map { MeetingCard.when($0, now: Date()) } ?? "-")
                calendar.dismissed.remove("zoom")
                TestScenarios.shot("calendar-soon")
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }
            at(9.5) {
                TestScenarios.shot("calendar-soon-dark")
                calendar.disconnect()
            }
            at(10.5) {
                let token = Persistence.directory.appendingPathComponent("google-token.json")
                SpaceChecks.check("disconnecting forgets the token and the meetings",
                                  !calendar.connected && !FileManager.default.fileExists(atPath: token.path)
                                  && calendar.events.isEmpty && reminders.isEmpty && UIFrames.frames["meetingCard"] == nil)
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "meet":
            // Live Google Meet, on screen (run by hand, with the user): they
            // sign in and start or join a call in this instance; then the call
            // tab is left for another and should float, and come back.
            func probe(_ tab: ChaTab?, _ what: String) {
                tab?.executeJavaScript("console.log('__cha_probe__ ' + JSON.stringify({\(what)}))")
            }
            let state = "handler: !!window.__chaEnterPiP, docpip: !!window.documentPictureInPicture?.window, "
                + "videos: [...document.querySelectorAll('video')].map(v => [v.clientWidth, v.paused, v.muted, v.readyState].join('/')), "
                + "pipElement: !!document.pictureInPictureElement, url: location.pathname"
            at(1) { controller.newTab(url: "https://meet.google.com/") }
            var call: ChaTab?
            var callID: UUID?
            var last = ""
            func waitForCall(_ n: Int) {
                let found = controller.activeSpace.tabs.first { data in
                    guard let t = controller.liveTabs[data.id] else { return false }
                    return t.currentURL.range(of: #"meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression) != nil
                        && t.usesCameraOrMicrophone
                }
                if let found, let t = controller.liveTabs[found.id] {
                    NSLog("MEET in a call: %@", t.currentURL)
                    call = t
                    callID = found.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { leave() }
                    return
                }
                let t = controller.activeTab
                let now = "\(t?.currentURL.prefix(60) ?? "-") cam=\(t?.usesCameraOrMicrophone ?? false)"
                if now != last { NSLog("MEET waiting: %@", now); last = now }
                if n > 900 { NSLog("MEET gave up waiting for a call"); NSApp.terminate(nil); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { waitForCall(n + 1) }
            }
            at(2) { waitForCall(0) }
            func leave() {
                probe(call, state)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    controller.newTab(url: "https://example.com/")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    probe(call, state)
                    SpaceChecks.check("leaving the call floats it", call?.hasFloatingWindow == true,
                                      "floating=\(call?.hasFloatingWindow ?? false) (a video PiP shows as pipElement in the probe)")
                    TestScenarios.screenShot("meet-left")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                    if let callID { controller.activateTab(callID) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 16) {
                    probe(call, state)
                    SpaceChecks.check("coming back brings it home", call?.hasFloatingWindow == false && call?.isClosed == false)
                    TestScenarios.screenShot("meet-back")
                    NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                }
            }

        case "callpip":
            // Leaving a tab: a site with its own automatic picture in picture
            // (Meet) gets it called when it plays sound or is in a call; a call
            // without one floats its biggest video. No floating window opens
            // here (requestPictureInPicture is stubbed, document PiP is off).
            func title(_ t: ChaTab?) -> String { t?.title ?? "-" }
            let site = "data:text/html,<title>site</title><canvas id=c width=64 height=36></canvas><video id=v></video><script>"
                + "navigator.mediaSession.setActionHandler('enterpictureinpicture', () => document.title = 'AUTO site');"
                + "const c = document.getElementById('c'), x = c.getContext('2d');"
                + "setInterval(() => { x.fillStyle = 'rgb(' + Math.floor(Math.random()*255) + ',90,140)'; x.fillRect(0,0,64,36); }, 50);"
                + "document.getElementById('v').srcObject = c.captureStream(20);</script>"
            var a: ChaTab?
            var aID: UUID?
            at(1) { controller.newTab(url: site) }
            at(3) {
                a = controller.activeTab
                aID = controller.activeSpace.activeTabID
                a?.executeJavaScript(withUserGesture:
                    "document.getElementById('v').play().then(() => document.title = 'playing ' + !!window.__chaEnterPiP)")
            }
            at(4) {
                SpaceChecks.check("the site's own picture-in-picture handler is kept", title(a) == "playing true", title(a))
                controller.newTab(url: "data:text/html,<title>other</title>")
            }
            at(5.5) {
                SpaceChecks.check("leaving a tab that plays calls the site's picture in picture", title(a) == "AUTO site", title(a))
                if let aID { controller.activateTab(aID) }
            }
            var quiet: ChaTab?
            // Stands in for the real floating window, which would open on screen.
            let stub = "HTMLVideoElement.prototype.requestPictureInPicture = function () { document.title = 'would ' + this.id; return Promise.resolve(); };"
            at(6.5) {
                controller.newTab(url: "data:text/html,<title>quiet</title><script>"
                    + "navigator.mediaSession.setActionHandler('enterpictureinpicture', () => document.title = 'AUTO quiet');</script>")
            }
            at(8) {
                quiet = controller.activeTab
                controller.newTab(url: "data:text/html,<title>other2</title>")
            }
            at(9.5) {
                SpaceChecks.check("a silent page out of a call is left alone", title(quiet) == "quiet", title(quiet))
                if let id = controller.activeSpace.tabs.first(where: { controller.liveTabs[$0.id] === quiet })?.id {
                    controller.activateTab(id)  // its videos play while it is on screen
                }
                // A call with muted tiles: the biggest playing one floats.
                quiet?.executeJavaScript(withUserGesture:
                    "document.body.innerHTML = '<canvas id=c width=64 height=36></canvas><video id=small muted width=40></video><video id=big muted width=320></video>';"
                    + "window.__chaEnterPiP = null;"
                    + "const c = document.getElementById('c'), x = c.getContext('2d'); setInterval(() => x.fillRect(0, 0, Math.random() * 64, 36), 50);"
                    + "Promise.all(['small', 'big'].map(id => { const v = document.getElementById(id); v.srcObject = c.captureStream(20);"
                    + " return new Promise(r => { v.onplaying = r; v.play(); }); })).then(() => document.title = 'tiles playing');")
            }
            at(11) {
                SpaceChecks.check("a call's muted tiles play", title(quiet) == "tiles playing", title(quiet))
                quiet?.executeJavaScript(withUserGesture: stub + "document.title = 'r ' + " + PictureInPicture.enterOnLeaving(call: true))
            }
            at(12.5) {  // A second: the page's answer comes later when the Mac is busy.
                SpaceChecks.check("in a call the biggest playing video floats", title(quiet) == "r video (in a call)", title(quiet))
                quiet?.executeJavaScript(withUserGesture: "document.title = 'r ' + " + PictureInPicture.enterOnLeaving(call: false))
            }
            at(13.5) {
                SpaceChecks.check("muted videos out of a call stay", title(quiet) == "r none", title(quiet))
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "docpip":
            // The real floating window (opens on screen: run when nobody is
            // at the Mac, or with CHA_SCREEN on another display).
            var t: ChaTab?
            var tabs = 0
            at(1) { controller.newTab(url: "data:text/html,<title>call</title>") }
            at(3) {
                t = controller.activeTab
                tabs = controller.activeSpace.tabs.count
                t?.executeJavaScript(withUserGesture:
                    "documentPictureInPicture.requestWindow({width: 300, height: 200}).then(" +
                    "w => { w.document.body.innerHTML = '<h1>tiles</h1>'; document.title = 'PIP open'; }, e => document.title = 'PIP error ' + e.name)")
            }
            at(5) {
                SpaceChecks.check("Meet's floating window opens", t?.title == "PIP open" && t?.hasFloatingWindow == true, "\(t?.title ?? "-") \(t?.hasFloatingWindow ?? false)")
                SpaceChecks.check("and no tab stands in for it", controller.activeSpace.tabs.count == tabs && controller.activeTab === t)
                t?.executeJavaScript(PictureInPicture.exitIfFloating)
            }
            at(7) {
                SpaceChecks.check("closing the floating window leaves the tab", t?.hasFloatingWindow == false && t?.isClosed == false)
                t?.executeJavaScript(withUserGesture: "documentPictureInPicture.requestWindow().then(() => document.title = 'PIP again')")
            }
            at(9) {
                SpaceChecks.check("it opens again", t?.hasFloatingWindow == true, t?.title ?? "-")
                controller.closeActiveTab()
            }
            at(12) {
                SpaceChecks.check("⌘W ends the call and its floating window", t?.isClosed == true && t?.hasFloatingWindow == false)
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "split":
            // Split View: two tabs side by side, as in Arc.
            func page(_ t: String) -> String { "data:text/html,<title>\(t)</title><h1>\(t)</h1>" }
            var left: UUID?, right: UUID?, other: UUID?
            func win(_ id: UUID?) -> NSWindow? { id.flatMap { controller.liveTabs[$0]?.nativeWindow } }
            func onScreen(_ id: UUID?) -> Bool { win(id).map { $0.isVisible && $0.parent === controller.window } ?? false }
            func halves() -> Bool {
                guard let l = win(left)?.frame, let r = win(right)?.frame else { return false }
                let page = controller.contentScreenRect
                return abs(l.minX - page.minX) < 1.5 && abs(r.maxX - page.maxX) < 1.5
                    && abs(r.minX - l.maxX - BrowserController.splitGap) < 1.5
                    && abs(l.width - r.width) < 2 && abs(l.height - page.height) < 1.5
            }
            at(1) {
                controller.newTab(url: page("Other"))
                other = controller.activeTabID
                controller.newTab(url: page("Left"))
                left = controller.activeTabID
            }
            at(2.5) {
                controller.run(ChaCommand.all.first { $0.id == "split" }!)
                SpaceChecks.check("⌃⇧= asks what to open beside", controller.commandMode == .split && controller.commandPanel?.isVisible == true)
                controller.commandQuery = page("Right")
                controller.runSelectedCommand()
                right = controller.activeTabID
            }
            at(4) {
                SpaceChecks.check("it opens beside the tab", right != left && left.flatMap { controller.splitPartner($0) } == right)
                SpaceChecks.check("both pages are on screen", onScreen(left) && onScreen(right))
                SpaceChecks.check("each on its half of the page area", halves(),
                    "\(win(left)?.frame ?? .zero) \(win(right)?.frame ?? .zero) in \(controller.contentScreenRect)")
                shot("split-view")
                controller.activateTab(left)
            }
            at(4.6) {
                SpaceChecks.check("going to the left one keeps both", controller.activeTabID == left && onScreen(right) && halves())
                if let tab = right.flatMap({ controller.liveTabs[$0] }) { controller.bringForward(tab, why: "check") }
            }
            at(5.2) {
                SpaceChecks.check("a click in the other page puts it in front", controller.activeTabID == right && onScreen(left))
                // No fade: off screen, a fade ends only with the next event.
                controller.activateTab(other, transition: .none)
            }
            at(6.8) {
                SpaceChecks.check("another tab hides both", onScreen(other) && !onScreen(left) && !onScreen(right))
                controller.activateTab(right)
            }
            at(8.2) {
                SpaceChecks.check("and coming back shows both again", onScreen(left) && onScreen(right) && halves())
                if let window = controller.window {
                    var frame = window.frame
                    frame.size.width += 160
                    window.setFrame(frame, display: true)
                }
            }
            at(8.8) {
                SpaceChecks.check("the halves follow the window", halves(), "\(win(left)?.frame ?? .zero) \(win(right)?.frame ?? .zero) in \(controller.contentScreenRect)")
                let data = try? JSONEncoder().encode(left.flatMap { controller.tabData($0) })
                let back = data.flatMap { try? JSONDecoder().decode(TabData.self, from: $0) }
                SpaceChecks.check("the pair is kept with the tabs", back?.splitWith == right)
                controller.run(ChaCommand.all.first { $0.id == "unsplit" }!)
            }
            at(10) {
                SpaceChecks.check("⌃⇧- puts them apart", left.flatMap { controller.splitPartner($0) } == nil
                    && onScreen(right) && !onScreen(left)
                    && (win(right)?.frame.isClose(to: controller.contentScreenRect) ?? false))
                if let left, let right { controller.split(left, with: right) }
            }
            at(11.4) {
                SpaceChecks.check("Split with Current Tab pairs them again", left.flatMap { controller.splitPartner($0) } == right)
                if let right { controller.closeTab(right) }
            }
            at(13) {
                SpaceChecks.check("closing one half ends the split, the other takes the page", left.flatMap { controller.tabData($0)?.splitWith } == nil
                    && controller.activeTabID == left && onScreen(left) && (win(left)?.frame.isClose(to: controller.contentScreenRect) ?? false))
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "boost":
            // Boosts: a site's own CSS, script and zapped things.
            let port = ProcessInfo.processInfo.environment["CHA_TEST_PORT"] ?? "0"
            let site = "http://127.0.0.1:\(port)/"
            let probe = "document.title = [getComputedStyle(document.querySelector('h1')).color,"
                + " getComputedStyle(document.querySelector('.ad')).display, document.body.dataset.boosted || 'no'].join(' | ')"
            func title() -> String { controller.activeTab?.title ?? "-" }
            func ask() { controller.activeTab?.executeJavaScript(probe) }
            at(1) { controller.newTab(url: site) }
            at(3) {
                controller.openBoostEditor()
                SpaceChecks.check("the editor opens for the site", controller.boostSite == "127.0.0.1" && controller.boostPanel?.isVisible == true,
                                  controller.boostSite ?? "-")
                controller.updateBoost { $0.css = "h1 { color: rgb(255, 0, 0) }" }
            }
            at(3.5) { ask() }
            at(4) {
                SpaceChecks.check("CSS goes on the page at once", title().hasPrefix("rgb(255, 0, 0) | block"), title())
                if let panel = controller.boostPanel { shotWindow(panel, "boost-editor") }
                controller.updateBoost { $0.js = "document.body.dataset.boosted = 'yes'" }
                controller.startZapping()
            }
            at(4.5) {
                controller.activeTab?.executeJavaScript(
                    "document.querySelector('.ad').dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true}))")
            }
            at(5) {
                let zapped = BoostStore.shared.boosts["127.0.0.1"]?.zapped ?? []
                SpaceChecks.check("Zap: a click hides the thing and keeps it", zapped == ["div.ad"] || zapped.first?.contains("div") == true, "\(zapped)")
                controller.stopZapping()
                controller.reload()
            }
            at(6.5) { ask() }
            at(7) {
                SpaceChecks.check("a new page of the site is boosted: CSS, zapped, script", title() == "rgb(255, 0, 0) | none | yes", title())
                controller.newTab(url: site + "?second")
            }
            at(8.5) { ask() }
            at(9) {
                SpaceChecks.check("so is another tab of it", title() == "rgb(255, 0, 0) | none | yes", title())
                controller.updateBoost { $0.enabled = false }
            }
            at(9.5) { ask() }
            at(10) {
                SpaceChecks.check("switched off, the page is itself again", title().hasPrefix("rgb(0, 0, 0) | block"), title())
                controller.updateBoost { $0.enabled = true }
                let reread = BoostStore()
                SpaceChecks.check("boosts are kept", reread.boosts["127.0.0.1"]?.css == "h1 { color: rgb(255, 0, 0) }")
                SpaceChecks.check("not for other sites", BoostStore.shared.boost(for: "https://example.com/") == nil)
                controller.closeBoostEditor()
                SpaceChecks.check("Done closes the editor", controller.boostPanel?.isVisible != true)
                BoostStore.shared.remove("127.0.0.1")
                controller.applyBoost(site: "127.0.0.1")
            }
            at(10.5) { ask() }
            at(11) {
                SpaceChecks.check("a deleted boost leaves the page", title().hasPrefix("rgb(0, 0, 0) | block"), title())
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "ask":
            // Arc Max on this Mac's model: a question about the page, and
            // tidy tab titles. Skipped (not passed) where the model is missing.
            guard PageAI.available else {
                NSLog("SKIP Apple's on-device model is not available: %@", PageAI.unavailableReason)
                at(1) { NSLog("CHECKS passed=0 failed=0"); NSApp.terminate(nil) }
                break
            }
            let page = "data:text/html,<title>Amazon.com : Wireless Noise Cancelling Headphones Model X200, Black : Electronics</title>"
                + "<p>The Eiffel Tower in Paris was finished in 1889. It is 330 metres tall and was built by Gustave Eiffel's company.</p>"
            at(1) { controller.newTab(url: page) }
            at(3) {
                controller.run(ChaCommand.all.first { $0.id == "ask" }!)
                SpaceChecks.check("Ask opens over the page", controller.askPanel?.isVisible == true)
                controller.ask("How tall is the Eiffel Tower?") {
                    SpaceChecks.check("the answer comes from the page", controller.askAnswer.contains("330"), controller.askAnswer)
                    NSLog("ASK answer: %@", controller.askAnswer)
                    controller.closeAsk()
                    controller.tidyTabTitles {
                        let title = controller.activeTab.flatMap { _ in controller.tabData(controller.activeTabID!)?.displayTitle } ?? "-"
                        SpaceChecks.check("Tidy gives the tab a short name", title.count <= 40 && !title.contains("Amazon") && !title.isEmpty, title)
                        NSLog("ASK tidy: %@", title)
                        NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                        NSApp.terminate(nil)
                    }
                }
            }

        case "easel":
            // Easels: drawn, written, framed, pictures; kept; back on reopening.
            var easelID: UUID?
            func tab() -> ChaTab? { controller.activeTab }
            func count() { tab()?.executeJavaScript("document.title = 'COUNT ' + document.querySelectorAll('.item').length + ' ' + document.querySelectorAll('#ink path').length") }
            at(1) { controller.run(ChaCommand.all.first { $0.id == "new-easel" }!) }
            at(3) {
                easelID = tab().flatMap { EaselStore.id(in: $0.currentURL) }
                SpaceChecks.check("New Easel opens a canvas as a tab", easelID != nil)
                // The pen, by pointer events: a stroke across the board.
                tab()?.executeJavaScript(withUserGesture: """
                    document.querySelector('[data-tool="pen"]').click();
                    const b = document.getElementById('board');
                    const ev = (t, x, y) => b.dispatchEvent(new PointerEvent(t, { clientX: x, clientY: y, bubbles: true, pointerId: 1 }));
                    ev('pointerdown', 100, 100); ev('pointermove', 150, 140); ev('pointermove', 220, 160); ev('pointerup', 220, 160);
                    __chaEaselAdd({ type: 'text', x: 300, y: 80, text: 'Plan for Q1', color: '#0a84ff', size: 22 });
                    __chaEaselAdd({ type: 'box', x: 280, y: 60, w: 240, h: 120, color: '#ff3b30' });
                    __chaEaselAdd({ type: 'image', x: 60, y: 260, w: 40, src: 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" fill="green"/></svg>') });
                    """)
            }
            at(4.5) {
                let saved = easelID.flatMap { EaselStore.load($0) } ?? ""
                let types = ["path", "text", "box", "image"].filter { saved.contains("\"type\":\"\($0)\"") }
                SpaceChecks.check("a stroke, text, a box and a picture are kept", types.count == 4, "\(types)")
                SpaceChecks.check("its text names the tab", tab()?.title == "Plan for Q1", tab()?.title ?? "-")
                if let id = controller.activeTabID { controller.unload(id) }
            }
            at(5) { if let id = controller.activeTabID { controller.activateTab(id) } }
            at(7) { count() }
            at(7.5) {
                SpaceChecks.check("reopened, it is all back", tab()?.title == "COUNT 3 1", tab()?.title ?? "-")
                controller.capture(.zero) { image in
                    if let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "build/shots/easel.png"))
                    }
                    BrowserController.clipboard.clearContents()
                }
                tab()?.executeJavaScript(withUserGesture: """
                    document.querySelector('[data-tool="move"]').click();
                    const b = document.getElementById('board');
                    const box = document.querySelector('.box');
                    box.dispatchEvent(new PointerEvent('pointerdown', { clientX: 300, clientY: 70, bubbles: true, pointerId: 1 }));
                    b.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, pointerId: 1 }));
                    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Backspace', bubbles: true }));
                    """)
            }
            at(8) { count() }
            at(8.5) {
                SpaceChecks.check("a selected thing goes with Delete", tab()?.title == "COUNT 2 1", tab()?.title ?? "-")
                tab()?.executeJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'z', metaKey: true, bubbles: true }))")
            }
            at(9) { count() }
            at(9.5) {
                SpaceChecks.check("and ⌘Z brings it back", tab()?.title == "COUNT 3 1", tab()?.title ?? "-")
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "notes":
            // Notes: written, kept as typed, back after the tab is reopened.
            var noteID: UUID?
            func tab() -> ChaTab? { controller.activeTab }
            at(1) { controller.run(ChaCommand.all.first { $0.id == "new-note" }!) }
            at(3) {
                noteID = tab().flatMap { NoteStore.id(in: $0.currentURL) }
                SpaceChecks.check("New Note opens a note as a tab", noteID != nil, tab()?.currentURL.prefix(80).description ?? "-")
                SpaceChecks.check("named New Note until written", tab()?.title == "New Note", tab()?.title ?? "-")
                tab()?.executeJavaScript(withUserGesture:
                    "const n = document.getElementById('note'); n.focus(); document.execCommand('insertText', false, 'Shopping list');"
                    + "document.execCommand('insertParagraph'); document.execCommand('insertText', false, 'milk & bread #2 100%');")
            }
            at(4.5) {
                SpaceChecks.check("its first line names the tab", tab()?.title == "Shopping list", tab()?.title ?? "-")
                let saved = noteID.map { NoteStore.load($0) }
                SpaceChecks.check("what is written is kept as it is typed",
                    saved?.title == "Shopping list" && saved?.html.contains("milk &amp; bread #2 100%") == true, saved?.html ?? "-")
                if let id = controller.activeTabID { controller.unload(id) }
            }
            at(5) {
                if let id = controller.activeTabID { controller.activateTab(id) }
            }
            at(7) {
                let text = "document.title = 'TEXT ' + document.getElementById('note').innerText.replace(/\\n+/g, ' / ')"
                tab()?.executeJavaScript(text)
            }
            at(7.5) {
                SpaceChecks.check("reopened, the note comes back", tab()?.title == "TEXT Shopping list / milk & bread #2 100%", tab()?.title ?? "-")
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "capture":
            // Capture: part of the page, or all of it, to the clipboard.
            let halves = "data:text/html,<style>body{margin:0;display:flex;height:100vh}div{flex:1}</style>"
                + "<div style='background:rgb(255,0,0)'></div><div style='background:rgb(0,0,255)'></div>"
            func color(_ image: NSImage?, _ x: CGFloat, _ y: CGFloat) -> NSColor? {
                guard let rep = image?.representations.first as? NSBitmapImageRep else { return nil }
                return rep.colorAt(x: Int(x * CGFloat(rep.pixelsWide)), y: Int(y * CGFloat(rep.pixelsHigh)))?.usingColorSpace(.sRGB)
            }
            // Colour-managed: pure red comes back as a strong red, not 1/0/0.
            func isRed(_ c: NSColor?) -> Bool { guard let c else { return false }; return c.redComponent > c.blueComponent + 0.4 && c.redComponent > c.greenComponent + 0.4 }
            func isBlue(_ c: NSColor?) -> Bool { guard let c else { return false }; return c.blueComponent > c.redComponent + 0.4 }
            at(1) { controller.newTab(url: halves) }
            at(3) {
                controller.run(ChaCommand.all.first { $0.id == "capture" }!)
                SpaceChecks.check("Capture covers the page to drag over", controller.captureOverlay?.isVisible == true
                    && (controller.captureOverlay?.frame.isClose(to: controller.contentScreenRect) ?? false))
                controller.captureOverlay?.cancelOperation(nil)
                SpaceChecks.check("Esc lets it be", controller.captureOverlay == nil)
                var left = controller.contentScreenRect
                left.size.width = left.width / 2 - 20
                controller.capture(left) { image in
                    SpaceChecks.check("a dragged part becomes a picture of just that",
                        isRed(color(image, 0.5, 0.5)) && isRed(color(image, 0.95, 0.5)), "\(String(describing: color(image, 0.5, 0.5)))")
                    SpaceChecks.check("and is on the clipboard (the checks' own)",
                        BrowserController.clipboard.data(forType: .png) != nil && controller.toastText == "Copied screenshot")
                }
            }
            at(4.5) {
                controller.capture(.zero) { image in
                    let page = controller.contentScreenRect
                    SpaceChecks.check("a click takes the whole page",
                        isRed(color(image, 0.1, 0.5)) && isBlue(color(image, 0.9, 0.5))
                            && abs((image?.size.width ?? 0) - page.width) < 2,
                        "\(image?.size ?? .zero) vs \(page.size), \(String(describing: color(image, 0.1, 0.5))) \(String(describing: color(image, 0.9, 0.5)))")
                }
            }
            at(6) {
                BrowserController.clipboard.clearContents()
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "sync":
            // Two Macs (two profiles, run in turn) through a local cloudsync
            // server: CHA_SYNC_ROLE is b1 (B shows its code), a (A starts and
            // adds B), b2 (B joins, has A's space, renames it), a2 (A sees it).
            #if CHA_SYNC
            let role = ProcessInfo.processInfo.environment["CHA_SYNC_ROLE"] ?? ""
            let codeFile = ProcessInfo.processInfo.environment["CHA_SYNC_CODE_FILE"] ?? "/dev/null"
            let state = SyncState.shared
            func done() { NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed); NSApp.terminate(nil) }
            func synced() -> SpaceData? { controller.spaces.first { $0.name.hasPrefix("Synced Work") } }
            switch role {
            case "b1":
                at(1) {
                    controller.sync?.waitToJoin()
                    SpaceChecks.check("a Mac to be added shows its code", state.deviceCode.hasPrefix("cs1:") && state.waitingToJoin, state.deviceCode)
                    try? state.deviceCode.write(toFile: codeFile, atomically: true, encoding: .utf8)
                    done()
                }
            case "a":
                at(1) {
                    controller.addSpace()
                    controller.finishEditing()
                    let id = controller.activeSpaceID
                    controller.updateSpace(id) { $0.name = "Synced Work"; $0.symbol = "briefcase" }
                    controller.newTab(url: "https://example.com/pinned")
                    if let tab = controller.activeTabID { controller.togglePin(tab) }
                    _ = controller.addFolder(name: "Docs")
                    controller.newTab(url: "https://example.com/today")  // stays on this Mac
                    controller.newTab(url: "https://example.com/fav")
                    if let tab = controller.activeTabID { controller.addToFavorites(tab) }
                    controller.sync?.startNew()
                }
                at(4) {
                    SpaceChecks.check("Sync starts", state.on, state.status)
                    controller.save()
                }
                at(7) {
                    let code = (try? String(contentsOfFile: codeFile, encoding: .utf8)) ?? ""
                    Task { @MainActor in
                        let result = await controller.sync?.addMac(code: code) ?? "-"
                        SpaceChecks.check("the other Mac is added by its code", result.hasPrefix("Added"), result)
                        done()
                    }
                }
            case "b2":
                at(1) { controller.sync?.waitToJoin() }
                at(8) {
                    let space = synced()
                    SpaceChecks.check("B joins on its own", state.on && state.members == 2, state.status)
                    SpaceChecks.check("and has A's space with its pinned tab and folder",
                        space?.pinnedTabs.contains { $0.url == "https://example.com/pinned" } == true
                            && space?.folders.contains { $0.name == "Docs" } == true && space?.symbol == "briefcase",
                        "\(controller.spaces.map(\.name))")
                    SpaceChecks.check("but not A's today tabs", space?.tabs.contains { $0.url.hasSuffix("/today") } == false)
                    SpaceChecks.check("and A's favourite", controller.favorites.contains { $0.url == "https://example.com/fav" || $0.pinnedURL == "https://example.com/fav" })
                    if let id = space?.id { controller.updateSpace(id) { $0.name = "Synced Work, renamed on B" } }
                    controller.save()
                }
                at(12) { done() }
            case "a2":
                at(8) {
                    SpaceChecks.check("B's rename reaches A", synced()?.name == "Synced Work, renamed on B", "\(controller.spaces.map(\.name))")
                    SpaceChecks.check("the server raised no warnings", state.warnings.isEmpty, "\(state.warnings)")
                    SpaceChecks.check("A counts two Macs", state.members == 2, "\(state.members)")
                    done()
                }
            default:
                at(1) { NSLog("no CHA_SYNC_ROLE"); done() }
            }
            #else
            at(1) { NSLog("SKIP built without cloudsync"); NSLog("CHECKS passed=0 failed=0"); NSApp.terminate(nil) }
            #endif

        case "extensions":
            // Chrome extensions: installed from a CRX (a local stand-in for the
            // Web Store), loaded after a restart (the step runs this twice).
            let port = ProcessInfo.processInfo.environment["CHA_TEST_PORT"] ?? "0"
            let id = "abcdefghijklmnopabcdefghijklmnop"
            ExtensionStore.crxURL = { URL(string: "http://127.0.0.1:\(port)/\($0).crx") }
            let second = !ExtensionStore.shared.installed.isEmpty
            if !second {
                at(1) {
                    SpaceChecks.check("a Web Store link gives the ID",
                        ExtensionStore.extensionID(from: "https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh") == "ddkjiahejlhfcafbddmgiahcphecmpfh")
                    SpaceChecks.check("other text gives none", ExtensionStore.extensionID(from: "hello") == nil)
                    controller.openExtensions()
                    ExtensionStore.shared.install("https://chromewebstore.google.com/detail/probe/\(id)") { ok in
                        let store = ExtensionStore.shared
                        SpaceChecks.check("installing unpacks it into the profile", ok && store.installed.first?.id == id
                            && store.installed.first?.name == "cha probe" && store.needsRestart, store.message)
                        NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                        NSApp.terminate(nil)
                    }
                }
            } else {
                at(1) { controller.newTab(url: "http://127.0.0.1:\(port)/") }
                at(4) { controller.activeTab?.executeJavaScript("document.title = 'EXT ' + (document.documentElement.dataset.ext || 'none')") }
                at(5) {
                    SpaceChecks.check("after a restart the extension runs on pages", controller.activeTab?.title == "EXT yes",
                                      controller.activeTab?.title ?? "-")
                    SpaceChecks.check("its button is in the sidebar", UIFrames.frames["extension:\(id)"] != nil)
                    if let ext = ExtensionStore.shared.installed.first { controller.openExtensionPopup(ext) }
                    SpaceChecks.check("a click opens its popup in a little window",
                        LittleWindowController.open.contains { $0.url.hasPrefix("chrome-extension://\(id)/popup.html") })
                    LittleWindowController.open.forEach { $0.window.close() }
                    if let ext = ExtensionStore.shared.installed.first { ExtensionStore.shared.remove(ext) }
                    SpaceChecks.check("Remove takes it out", ExtensionStore.shared.installed.isEmpty && ExtensionStore.shared.needsRestart)
                    NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                    NSApp.terminate(nil)
                }
            }

        case "sound":
            // A tab playing sound: its speaker, mute, and the mini player once
            // it is left. (The checks run with Chromium's sound off.)
            let song = "data:text/html,<title>Player</title><audio loop></audio><script>"
                + "const rate = 8000, n = rate; const b = new ArrayBuffer(44 + n); const d = new DataView(b);"
                + "const w = (o, s) => [...s].forEach((c, i) => d.setUint8(o + i, c.charCodeAt(0)));"
                + "w(0, 'RIFF'); d.setUint32(4, 36 + n, true); w(8, 'WAVEfmt '); d.setUint32(16, 16, true); d.setUint16(20, 1, true);"
                + "d.setUint16(22, 1, true); d.setUint32(24, rate, true); d.setUint32(28, rate, true); d.setUint16(32, 1, true);"
                + "d.setUint16(34, 8, true); w(36, 'data'); d.setUint32(40, n, true);"
                + "for (let i = 0; i < n; i++) d.setUint8(44 + i, 128 + 60 * Math.sin(i / 4));"
                + "document.querySelector('audio').src = URL.createObjectURL(new Blob([b], {type: 'audio/wav'}));"
                + "navigator.mediaSession.metadata = new MediaMetadata({title: 'Test Song', artist: 'Test Band'});"
                + "navigator.mediaSession.setActionHandler('nexttrack', () => document.title = 'next track');"
                + "</script>"
            var player: UUID?
            func state() -> MediaState? { player.flatMap { controller.media[$0] } }
            at(1) {
                controller.newTab(url: song)
                player = controller.activeTabID
            }
            at(3) { controller.activeTab?.executeJavaScript(withUserGesture: "document.querySelector('audio').play()") }
            at(4.5) {
                SpaceChecks.check("a tab playing sound is known", state()?.playing == true, "\(String(describing: state()))")
                SpaceChecks.check("its row shows a speaker", player.map { UIFrames.frames["speaker:\($0)"] != nil } == true)
                SpaceChecks.check("with what the page says is playing", state()?.title == "Test Song" && state()?.artist == "Test Band")
                SpaceChecks.check("no mini player for the tab in front", controller.miniPlayerTab == nil)
                controller.newTab(url: "data:text/html,<title>Elsewhere</title>")
            }
            at(5.5) {
                SpaceChecks.check("leaving it brings up the mini player", controller.miniPlayerTab == player && UIFrames.frames["miniPlayer"] != nil)
                shot("mini-player")
                if let player { controller.mediaCommand(player, "toggle") }
            }
            at(6.5) {
                SpaceChecks.check("its button pauses", state()?.playing == false && state()?.paused == true, "\(String(describing: state()))")
                SpaceChecks.check("and the player stays, to play again", controller.miniPlayerTab == player)
                if let player { controller.mediaCommand(player, "toggle") }
            }
            at(7.5) {
                SpaceChecks.check("and plays again", state()?.playing == true)
                if let player {
                    controller.mediaCommand(player, "nexttrack")
                    controller.toggleMute(player)
                }
            }
            at(8.5) {
                let title = player.flatMap { controller.liveTabs[$0]?.title } ?? "-"
                SpaceChecks.check("forward runs the page's next-track", title == "next track", title)
                SpaceChecks.check("mute mutes the tab", state()?.muted == true && player.flatMap { controller.liveTabs[$0]?.audioMuted } == true)
                if let player { controller.showTab(player) }
            }
            at(9) {
                SpaceChecks.check("going back to it puts the player away", controller.miniPlayerTab == nil && controller.activeTabID == player)
                if let player { controller.toggleMute(player) }
                controller.navigate(to: "data:text/html,<title>Silent</title>")
            }
            at(10.5) {
                SpaceChecks.check("a new page there plays nothing", state() == nil && controller.miniPlayerTab == nil, "\(String(describing: state()))")
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "external":
            // Links to other apps go to macOS instead of nowhere: a click and a
            // typed address open the app; a page sending itself there asks
            // first. Nothing is opened for real: the checks record it.
            var opened: [String] = []
            var asked: [String] = []
            ExternalLinks.open = { opened.append($0.absoluteString) }
            ExternalLinks.ask = { app, answer in asked.append(app); answer(true) }
            func title() -> String { controller.activeTab?.title ?? "-" }
            let page = "data:text/html,<title>here</title><a href='mailto:click@example.com'"
                + " style='display:block;width:100vw;height:100vh'>link</a>"
            var tabs = 0
            at(1) { controller.newTab(url: page) }
            at(3) {
                tabs = controller.activeSpace.tabs.count
                controller.activeTab?.clickAt(x: 40, y: 40)
            }
            at(4) {
                SpaceChecks.check("a click on a mailto: link opens Mail", opened == ["mailto:click@example.com"] && asked.isEmpty, "\(opened) \(asked)")
                controller.activeTab?.executeJavaScript("setTimeout(() => location.href = 'mailto:page@example.com', 10)")
            }
            at(5) {
                SpaceChecks.check("a page sending itself to an app asks first", asked.count == 1 && opened.last == "mailto:page@example.com", "\(opened) \(asked)")
                controller.navigate(to: "mailto:typed@example.com")
                controller.newTab(url: "mailto:newtab@example.com")
                controller.activeTab?.executeJavaScript("location.href = 'nosuchapp-cha-test:x'")
            }
            at(6.5) {
                SpaceChecks.check("a typed address and a new tab open the app at once",
                                  opened.suffix(2) == ["mailto:typed@example.com", "mailto:newtab@example.com"] && asked.count == 1, "\(opened) \(asked)")
                SpaceChecks.check("the page and the tabs stay as they were",
                                  title() == "here" && controller.activeSpace.tabs.count == tabs, "\(title()) \(controller.activeSpace.tabs.count)/\(tabs)")
                SpaceChecks.check("schemes: web ones stay, others go out",
                                  !ChaTab.isExternalURL("https://a.b") && !ChaTab.isExternalURL("about:blank")
                                  && !ChaTab.isExternalURL("data:text/plain,x") && normalizedURL(from: "localhost:3000") == "http://localhost:3000"
                                  && ChaTab.isExternalURL("slack://T1/magic-login/x?id=1") && ChaTab.isExternalURL("mailto:a@b"), "")
                SpaceChecks.check("a sign-in token stays out of the log", ExternalLinks.scheme(of: "slack://T/magic-login/secret") == "slack", "")
                let logged = Diagnostics.redacted("close (tab) http://127.0.0.1:5/?state=abc&iss=x&code=4/0Secret&scope=s")
                SpaceChecks.check("sign-in codes in URLs are hidden in the logs",
                                  !logged.contains("0Secret") && !logged.contains("abc") && logged.contains("iss=x"), logged)
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

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
                    "its page fills the window under the bar",
                    little.map { l in
                        let page = l.tab.nativeWindow?.frame ?? .zero
                        let want = l.pageScreenRect
                        return abs(page.width - want.width) < 1 && abs(page.height - want.height) < 1
                            && abs(page.minX - want.minX) < 1 && abs(page.maxY - want.maxY) < 1
                    } ?? false,
                    little.map { NSStringFromRect($0.tab.nativeWindow?.frame ?? .zero) + " want " + NSStringFromRect($0.pageScreenRect) } ?? "-")
                SpaceChecks.check("the main window is left as it was", controller.activeSpace.tabs.count == tabsBefore)
                // The bar's contents sit on the traffic lights' line, above
                // the page (SwiftUI's frames are top-left based, in points).
                let host = UIFrames.frames["littleHost"] ?? .zero
                let open = UIFrames.frames["littleOpen"] ?? .zero
                SpaceChecks.check(
                    "the little window's bar is on the traffic lights' line",
                    abs(host.midY - 22) < 2 && abs(open.midY - 22) < 2,
                    "host \(host.midY), button \(open.midY)")
                SpaceChecks.check(
                    "and above the page", host.maxY <= LittleWindowController.barHeight
                        && open.maxY <= LittleWindowController.barHeight, "\(host.maxY) \(open.maxY)")
                SpaceChecks.check(
                    "it opens on the desktop in use, full-screen apps included",
                    little?.window.collectionBehavior.contains(.fullScreenAuxiliary) == true
                        && little?.window.collectionBehavior.contains(.canJoinAllSpaces) == true
                        && little?.window.collectionBehavior.contains(.moveToActiveSpace) == false)
                if let little { TestScenarios.shotWindow(little.window, "little-window") }
                // Placement over the calling app's window.
                if let screen = NSScreen.screens.first?.visibleFrame {
                    let caller = NSRect(x: screen.minX + 60, y: screen.minY + 80, width: 900, height: 600)
                    let placed = LittleWindowController.frame(over: caller)
                    SpaceChecks.check(
                        "a little window opens centred over the calling app's window",
                        abs(placed.midX - caller.midX) <= 1 && abs(placed.midY - caller.midY) <= 1
                            && placed.width <= caller.width && placed.height <= caller.height,
                        NSStringFromRect(placed))
                    let corner = NSRect(x: screen.maxX - 150, y: screen.maxY - 120, width: 300, height: 200)
                    let kept = LittleWindowController.frame(over: corner)
                    SpaceChecks.check(
                        "and stays on that screen", screen.contains(kept), NSStringFromRect(kept))
                }
                SpaceChecks.check(
                    "the page's window can't be moved or resized on its own",
                    little.map { l in
                        let w = l.tab.nativeWindow
                        return w?.isMovable == false && w?.styleMask.contains(.resizable) == false
                    } ?? false)
                // A page that resizes and moves its own window snaps back.
                little?.tab.executeJavaScript(withUserGesture: "window.resizeTo(300, 200); window.moveTo(0, 0)")
            }
            at(4.2) {
                let little = LittleWindowController.open.first
                SpaceChecks.check(
                    "a page's resizeTo can't move it out of place",
                    little.map { abs(($0.tab.nativeWindow?.frame.width ?? 0) - $0.pageScreenRect.width) < 1 } ?? false,
                    little.map { NSStringFromRect($0.tab.nativeWindow?.frame ?? .zero) } ?? "-")
                controller.activeTab?.executeJavaScript(withUserGesture: "window.resizeTo(300, 200)")
            }
            at(4.6) {
                let page = controller.activeTab?.nativeWindow?.frame ?? .zero
                SpaceChecks.check(
                    "nor in the main window", abs(page.width - controller.contentScreenRect.width) < 1,
                    NSStringFromRect(page))
                LittleWindowController.open.first?.openInMain()
            }
            at(5.5) {
                SpaceChecks.check("Open in cha closes the little window", LittleWindowController.open.isEmpty)
                SpaceChecks.check(
                    "and the page is a tab of the main window, same browser",
                    controller.activeTab?.currentURL.contains("From outside") == true
                        && controller.activeSpace.tabs.count == tabsBefore + 1)
                let page = controller.activeTab?.nativeWindow
                SpaceChecks.check(
                    "its window is shown in the main window, opaque, in place",
                    page?.isVisible == true && page?.parent === controller.window && page?.alphaValue == 1
                        && (page?.frame.isClose(to: controller.contentScreenRect) ?? false),
                    page.map { NSStringFromRect($0.frame) } ?? "-")
                controller.openLittleWindow("data:text/html,<title>Throwaway</title>")
            }
            at(7) {
                let little = LittleWindowController.open.first
                little?.close()
            }
            // Air Traffic Control: a rule sends a link to its space.
            var routedSpace: UUID?
            at(8.2) {
                controller.addSpace()
                controller.finishEditing()
                routedSpace = controller.activeSpaceID
                if let first = controller.visibleSpaces.first?.id { controller.selectSpace(first, animated: false) }
                RoutingStore.shared.rules = [RouteRule(match: "Routed page", spaceID: routedSpace!)]
                LittleWindowController.open.forEach { $0.window.close() }
                let event = NSAppleEventDescriptor(
                    eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                    targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                    transactionID: AETransactionID(kAnyTransactionID))
                event.setParam(NSAppleEventDescriptor(string: "data:text/html,<title>Routed page</title>"), forKeyword: keyDirectObject)
                URLOpener.shared.handleGetURL(event, withReplyEvent: NSAppleEventDescriptor.null())
            }
            at(9.2) {
                let routedTabs = controller.spaces.first { $0.id == routedSpace }?.tabs.map(\.url) ?? []
                SpaceChecks.check("a routed link opens as a tab of its space", controller.activeSpaceID == routedSpace
                    && routedTabs.contains { $0.contains("Routed") },
                    "active \(controller.activeSpace.name), routed space tabs \(routedTabs.count): \(routedTabs.joined(separator: " "))")
                SpaceChecks.check("not in a little window", !LittleWindowController.open.contains { $0.url.contains("Routed") })
                SpaceChecks.check("rules are kept", RoutingStore().rules.first?.match == "Routed page")
                SpaceChecks.check("a rule doesn't claim other links", RoutingStore.shared.space(for: "https://example.com/", in: controller.spaces) == nil)
                RoutingStore.shared.rules = []
            }
            at(8) {
                SpaceChecks.check("closing it closes the page too", LittleWindowController.open.isEmpty)
                SpaceChecks.check("and leaves the main window alone", controller.activeSpace.tabs.count == tabsBefore + 1)
            }
            at(9.6) {
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "persist":
            // Sign-ins survive a restart, checked the way sites do it: the
            // server sets the cookies (a session one and a persistent one),
            // and after a restart logs what the browser sends back
            // (scripts/cookie-server.py). Phases on one CHA_PROFILE: setup
            // (makes a space with its own profile), write, read.
            let port = ProcessInfo.processInfo.environment["CHA_TEST_PORT"] ?? "0"
            let phase = ProcessInfo.processInfo.environment["CHA_PHASE"] ?? "read"
            let path = phase == "read" ? "check" : "set"
            if phase == "setup" {
                at(1) {
                    controller.addSpace()
                    let work = controller.activeSpaceID
                    controller.finishEditing()
                    controller.setProfile(controller.addProfile(named: "Work").id, for: work)
                    controller.newTab(url: "about:blank")
                }
                at(6) { NSApp.terminate(nil) }
                break
            }
            at(1) {
                controller.selectSpace(controller.spaces[0].id, animated: false)
                controller.newTab(url: "http://localhost:\(port)/\(path)?p=default")
            }
            at(4) {
                controller.selectSpace(controller.spaces[1].id, animated: false)
                controller.newTab(url: "http://localhost:\(port)/\(path)?p=work")
            }
            at(9) { NSApp.terminate(nil) }

        case "fs-corners":
            // Real full screen without the sidebar (takes over the screen: only
            // with the user's go-ahead). Corners checked from screen captures:
            // the page that was open, then a tab opened in full screen.
            let white = "data:text/html,<body style='background:rgb(250,250,250);margin:0'></body>"
            func capture(_ name: String) -> NSBitmapImageRep? {
                let path = "build/shots/\(name).png"
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-D1", path]
                try? process.run()
                process.waitUntilExit()
                return NSImage(contentsOfFile: path).flatMap { $0.tiffRepresentation }.flatMap(NSBitmapImageRep.init)
            }
            func corners(_ name: String, rounded: Bool = false) {
                guard let rep = capture(name), let page = controller.activeTab?.nativeWindow,
                    let screen = page.screen
                else { return SpaceChecks.check("\(name): captured", false) }
                let scale = CGFloat(rep.pixelsWide) / screen.frame.width
                let f = page.frame
                let top = Int((screen.frame.maxY - f.maxY) * scale) + 2
                let bottom = Int((screen.frame.maxY - f.minY) * scale) - 3
                let left = Int((f.minX - screen.frame.minX) * scale) + 2
                let right = Int((f.maxX - screen.frame.minX) * scale) - 3
                let points = [("top-left", left, top), ("top-right", right, top),
                              ("bottom-left", left, bottom), ("bottom-right", right, bottom)]
                var round: [String] = []
                for (label, x, y) in points {
                    let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                    if (c?.brightnessComponent ?? 0) < 0.9 || (c?.saturationComponent ?? 1) > 0.1 { round.append(label) }
                }
                NSLog("FS %@ styleMask=%lu radius=%.0f round=%@", name, page.styleMask.rawValue,
                    page.contentView?.layer?.cornerRadius ?? -1, round.joined(separator: ","))
                if rounded {
                    SpaceChecks.check("\(name): rounded corners", round.count == 4, round.joined(separator: ","))
                } else {
                    SpaceChecks.check("\(name): square corners", round.isEmpty, round.joined(separator: ","))
                }
            }
            at(1) { controller.newTab(url: white) }
            at(2.2) { corners("window-card", rounded: true) }
            at(2.5) { controller.toggleFullscreen() }
            at(4.5) { controller.toggleSidebar() }
            at(5.5) { corners("fs-open-tab") }
            at(9) { controller.newTab(url: white) }
            at(10.5) { corners("fs-new-tab") }
            at(11) { controller.toggleSidebar() }
            at(12) { corners("fs-with-sidebar-card", rounded: true) }
            at(12.5) { controller.toggleFullscreen() }
            at(14.5) { corners("window-again", rounded: true) }
            at(15) {
                NSLog("CHECKS passed=%d failed=%d", SpaceChecks.passed, SpaceChecks.failed)
                NSApp.terminate(nil)
            }

        case "fullscreen-real":
            // Real full screen, in a normal (visible, active) run, captured
            // from the screen: the way in, with the sidebar, without it, the
            // way out. Only when the user is fine with the screen taken over.
            var step = 0
            func capture(_ name: String) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-D1", "build/shots/\(name).png"]
                try? process.run()
                process.waitUntilExit()
                step += 1
            }
            func state(_ label: String) {
                NSLog("FS %@ fullscreen=%d sidebar=%d page=%@ radius=%.1f", label, controller.isFullscreen ? 1 : 0,
                    controller.sidebarVisible ? 1 : 0,
                    NSStringFromRect(controller.activeTab?.nativeWindow?.frame ?? .zero),
                    controller.activeTab?.nativeWindow?.contentView?.layer?.cornerRadius ?? -1)
            }
            at(1) { controller.newTab(url: "data:text/html,<body style='background:rgb(250,250,250);margin:0'><h1 style='margin:40px'>page</h1></body>") }
            at(3) { controller.toggleFullscreen() }
            at(3.06) { capture("fs-enter-1") }
            at(3.14) { capture("fs-enter-2") }
            at(5) { state("in"); capture("fs-sidebar") }
            at(5.5) { controller.toggleSidebar() }
            at(6.5) {
                state("no sidebar"); capture("fs-nosidebar")
                guard let w = controller.activeTab?.nativeWindow else { return }
                let r = w.value(forKey: "_cornerRadius") as? CGFloat ?? -1
                NSLog("FS window class=%@ _cornerRadius=%.1f mask=%@ frame=%@ canBecomeKey=%d isKey=%d", String(describing: type(of: w)), r,
                    String(describing: w.value(forKey: "_cornerMask")), NSStringFromRect(w.frame),
                    w.canBecomeKey ? 1 : 0, w.isKeyWindow ? 1 : 0)
                func walk(_ layer: CALayer, _ depth: Int, _ path: String) {
                    if layer.cornerRadius > 0 || layer.mask != nil {
                        NSLog("FS layer %@ %@ radius=%.1f masks=%d mask=%@ curve=%@ frame=%@", path,
                            String(describing: type(of: layer)), layer.cornerRadius, layer.masksToBounds ? 1 : 0,
                            String(describing: layer.mask.map { type(of: $0) }), layer.cornerCurve.rawValue,
                            NSStringFromRect(layer.frame))
                    }
                    for (i, sub) in (layer.sublayers ?? []).enumerated() where depth < 12 {
                        walk(sub, depth + 1, path + "/\(i)")
                    }
                }
                if let root = w.contentView?.superview?.layer { walk(root, 0, "frame") }
                if let main = controller.window.contentView?.superview?.layer {
                    NSLog("FS main window: walking"); walk(main, 0, "main")
                }
            }
            at(6.8) {
                if let w = controller.activeTab?.nativeWindow {
                    w.setFrame(w.frame.insetBy(dx: 40, dy: 30), display: true)
                }
            }
            at(7.2) { capture("fs-moved") }
            at(7.4) {
                controller.toggleSidebar()
                controller.toggleFullscreen()
            }
            at(7.46) { capture("fs-exit-1") }
            at(7.54) { capture("fs-exit-2") }
            at(9) { state("out"); capture("fs-window"); NSApp.terminate(nil) }

        case "pagewindow":
            at(2) {
                guard let w = controller.activeTab?.nativeWindow else { return NSLog("PAGE no window") }
                NSLog("PAGE class=%@ styleMask=%lu titled=%d fullSize=%d opaque=%d hasShadow=%d",
                    String(describing: type(of: w)), w.styleMask.rawValue,
                    w.styleMask.contains(.titled) ? 1 : 0, w.styleMask.contains(.fullSizeContentView) ? 1 : 0,
                    w.isOpaque ? 1 : 0, w.hasShadow ? 1 : 0)
                let frameView = w.contentView?.superview
                NSLog("PAGE frame view=%@ layer radius=%.1f masks=%d", String(describing: frameView.map { type(of: $0) }),
                    frameView?.layer?.cornerRadius ?? -1, frameView?.layer?.masksToBounds == true ? 1 : 0)
                for sel in ["_cornerMask", "_cornerRadius", "cornerRadius"] {
                    if w.responds(to: NSSelectorFromString(sel)) { NSLog("PAGE responds to %@", sel) }
                }
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

    // Any window's own views, as a picture (no Chromium pixels).
    static func shotWindow(_ window: NSWindow, _ name: String) {
        guard let content = window.contentView,
            let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "build/shots/\(name).png"))
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
        // Every page on screen: two in Split View.
        for page in (window.childWindows ?? []) where page.isVisible && !(page is NSPanel) {
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
