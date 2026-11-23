import AppKit

// Menu items are the app's keyboard shortcuts; they work while a tab's CEF
// window is key, and the web content answers the editing ones itself.
enum MainMenu {
    static func build(controller: BrowserController) -> NSMenu {
        let target = MenuTarget.shared
        target.controller = controller

        let bar = NSMenu()

        let app = NSMenu()
        app.addItem(
            withTitle: "About cha", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        app.addItem(.separator())
        let makeDefault = NSMenuItem(
            title: "Make cha the Default Browser",
            action: #selector(MenuTarget.makeDefaultBrowser), keyEquivalent: "")
        makeDefault.target = target
        app.addItem(makeDefault)
        let calendar = NSMenuItem(
            title: "Connect Google Calendar…",
            action: #selector(MenuTarget.toggleCalendar), keyEquivalent: "")
        calendar.target = target
        app.addItem(calendar)
        app.addItem(.separator())
        app.addItem(
            withTitle: "Hide cha", action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        app.addItem(
            withTitle: "Quit cha", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        bar.addItem(submenu: app, title: "cha")

        let file = NSMenu(title: "File")
        file.add("New Window", "n", target, #selector(MenuTarget.showWindow))
        file.add("New Tab", "t", target, #selector(MenuTarget.newTab))
        file.add("Close Tab", "w", target, #selector(MenuTarget.closeTab))
        file.add(
            "New Little Window", "n", target, #selector(MenuTarget.newLittleWindow),
            [.command, .option])
        file.add("Open in Main Window", "o", target, #selector(MenuTarget.openInMainWindow))
        file.add(
            "Reopen Closed Tab", "t", target, #selector(MenuTarget.reopenClosedTab),
            [.command, .shift])
        file.add("Empty Tab", "", target, #selector(MenuTarget.emptyTab), [])
        file.addItem(.separator())
        file.add("Print…", "p", target, #selector(MenuTarget.printPage))
        file.addItem(.separator())
        file.addItem(.separator())
        file.add("Passwords…", "", target, #selector(MenuTarget.passwords), [])
        file.add(
            "Import Passwords…", "", target, #selector(MenuTarget.importPasswords), [])
        file.addItem(.separator())
        file.add(
            "Fill Verification Code", "v", target, #selector(MenuTarget.fillCode),
            [.command, .shift])
        // The submenu rebuilds itself when it opens, so it shows live codes.
        let codes = NSMenu(title: "Verification Codes")
        codes.delegate = CodesMenuDelegate.shared
        CodesMenuDelegate.shared.controller = controller
        let codesItem = NSMenuItem(
            title: "Verification Codes", action: nil, keyEquivalent: "")
        codesItem.submenu = codes
        file.addItem(codesItem)
        bar.addItem(submenu: file, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a")
        edit.addItem(.separator())
        edit.add("Find…", "f", target, #selector(MenuTarget.findInPage))
        edit.add("Find Next", "g", target, #selector(MenuTarget.findNext))
        edit.add("Find Previous", "g", target, #selector(MenuTarget.findPrevious), [.command, .shift])
        bar.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        view.add("Toggle Sidebar", "s", target, #selector(MenuTarget.toggleSidebar))
        view.add("Reload", "r", target, #selector(MenuTarget.reload))
        view.add(
            "Clear Cache and Reload", "r", target, #selector(MenuTarget.reloadClearingCache),
            [.command, .shift])
        view.addItem(.separator())
        let fullscreen = NSMenuItem(
            title: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        view.addItem(fullscreen)
        view.addItem(.separator())
        view.add(
            "Picture in Picture", "p", target, #selector(MenuTarget.pictureInPicture),
            [.command, .option])
        view.addItem(.separator())
        view.add("Zoom In", "=", target, #selector(MenuTarget.zoomIn))
        let zoomInPlus = NSMenuItem(title: "Zoom In", action: #selector(MenuTarget.zoomIn), keyEquivalent: "+")
        zoomInPlus.target = target
        zoomInPlus.isAlternate = true  // ⌘+ as well as ⌘=, one row.
        zoomInPlus.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(zoomInPlus)
        view.add("Zoom Out", "-", target, #selector(MenuTarget.zoomOut))
        view.add("Actual Size", "0", target, #selector(MenuTarget.zoomReset))
        view.addItem(.separator())
        view.add("Developer Tools", "i", target, #selector(MenuTarget.devTools), [.command, .option])
        view.add("View Source", "u", target, #selector(MenuTarget.viewSource), [.command, .option])
        bar.addItem(submenu: view, title: "View")

        // Tabs: pin, favourite, copy, clear — the tab-level keys Arc has.
        let tabs = NSMenu(title: "Tab")
        tabs.add("Pin / Unpin Tab", "d", target, #selector(MenuTarget.togglePin))
        tabs.add(
            "Add to Favorites", "d", target, #selector(MenuTarget.addToFavorites),
            [.command, .shift])
        tabs.add("Copy Link", "c", target, #selector(MenuTarget.copyLink), [.command, .shift])
        tabs.add(
            "Copy Link as Markdown", "c", target, #selector(MenuTarget.copyMarkdown),
            [.command, .shift, .option])
        tabs.add("Duplicate Tab", "", target, #selector(MenuTarget.duplicateTab), [])
        tabs.add(
            "Back to Pinned Address", "", target, #selector(MenuTarget.resetPinned), [])
        tabs.addItem(.separator())
        tabs.add("Split View", "=", target, #selector(MenuTarget.splitView), [.control, .shift])
        tabs.add("Close Split View", "-", target, #selector(MenuTarget.closeSplitView), [.control, .shift])
        tabs.addItem(.separator())
        tabs.add(
            "Clear Today's Tabs", "k", target, #selector(MenuTarget.clearToday),
            [.command, .shift])
        tabs.add(
            "Downloads", "l", target, #selector(MenuTarget.showDownloads), [.command, .shift])
        bar.addItem(submenu: tabs, title: "Tab")

        // Spaces: ⌃1…⌃9 jump straight to one, as in Arc.
        let spaces = NSMenu(title: "Spaces")
        spaces.add("New Space", "n", target, #selector(MenuTarget.newSpace), [.command, .shift])
        spaces.add("Edit Space…", "", target, #selector(MenuTarget.editSpace), [])
        spaces.add("New Folder", "", target, #selector(MenuTarget.newFolder), [])
        spaces.add("Delete Space…", "", target, #selector(MenuTarget.deleteSpace), [])
        spaces.addItem(.separator())
        spaces.add(
            "Next Space", String(UnicodeScalar(NSRightArrowFunctionKey)!), target,
            #selector(MenuTarget.nextSpace), [.command, .option])
        spaces.add(
            "Previous Space", String(UnicodeScalar(NSLeftArrowFunctionKey)!), target,
            #selector(MenuTarget.previousSpace), [.command, .option])
        for number in 1...9 {
            let item = NSMenuItem(
                title: "Space \(number)", action: #selector(MenuTarget.selectSpaceByNumber(_:)),
                keyEquivalent: String(number))
            item.keyEquivalentModifierMask = [.control]
            item.tag = number - 1
            item.target = target
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            spaces.addItem(item)
        }
        bar.addItem(submenu: spaces, title: "Spaces")

        let navigate = NSMenu(title: "Navigate")
        navigate.add("Back", "[", target, #selector(MenuTarget.goBack))
        navigate.add("Forward", "]", target, #selector(MenuTarget.goForward))
        navigate.addItem(.separator())
        navigate.add(
            "Open Location", "l", target, #selector(MenuTarget.focusAddressBar))
        // ⌘1…⌘9 pick a tab in the current space; the items stay hidden.
        for number in 1...9 {
            let item = NSMenuItem(
                title: "Tab \(number)", action: #selector(MenuTarget.selectTabByNumber(_:)),
                keyEquivalent: String(number))
            item.tag = number - 1
            item.target = target
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            navigate.addItem(item)
        }
        bar.addItem(submenu: navigate, title: "Navigate")

        return bar
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem()
        item.title = title
        item.submenu = submenu
        addItem(item)
    }

    func add(
        _ title: String, _ key: String, _ target: AnyObject, _ action: Selector,
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        addItem(item)
    }
}

// Menu items need an Objective-C target that outlives the menu.
final class MenuTarget: NSObject, NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(makeDefaultBrowser) {
            let isDefault = URLOpener.isDefault
            item.title = isDefault ? "cha Is the Default Browser" : "Make cha the Default Browser"
            item.state = isDefault ? .on : .off
            return !isDefault
        }
        if item.action == #selector(toggleCalendar) {
            item.title = GoogleCalendar.shared.connected ? "Disconnect Google Calendar" : "Connect Google Calendar…"
        }
        return true
    }

    @objc func toggleCalendar() {
        let calendar = GoogleCalendar.shared
        if calendar.connected { calendar.disconnect() } else { calendar.connect() }
    }

    static let shared = MenuTarget()
    var controller: BrowserController?

    @objc func newTab() { controller?.openCommandBar(mode: .newTab) }
    // In a little window ⌘W closes the window, not a tab of the main one.
    @objc func closeTab() {
        if let peek = controller?.peek {
            peek.close()
        } else if let little = LittleWindowController.key {
            little.close()
        } else {
            controller?.closeActiveTab()
        }
    }
    @objc func newLittleWindow() { controller?.openLittleWindow("about:blank") }
    @objc func openInMainWindow() {
        if let peek = controller?.peek {
            peek.expand()
        } else {
            LittleWindowController.key?.openInMain()
        }
    }
    @objc func emptyTab() { controller?.newTab() }
    @objc func reopenClosedTab() { controller?.reopenClosedTab() }
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        controller?.activateTabAtIndex(sender.tag)
    }
    @objc func newSpace() { controller?.addSpace() }
    @objc func editSpace() {
        guard let c = controller else { return }
        c.editSpace(c.activeSpaceID)
    }
    @objc func deleteSpace() {
        guard let c = controller else { return }
        c.deleteSpace(c.activeSpaceID)
    }
    @objc func newFolder() { controller?.addFolder() }
    @objc func selectSpaceByNumber(_ sender: NSMenuItem) {
        controller?.selectSpace(at: sender.tag)
    }
    @objc func togglePin() {
        guard let c = controller, let id = c.activeTabID else { return }
        c.togglePin(id)
    }
    @objc func addToFavorites() {
        guard let c = controller, let id = c.activeTabID else { return }
        c.addToFavorites(id)
    }
    @objc func copyLink() { controller?.copyLink() }
    @objc func copyMarkdown() { controller?.copyLinkAsMarkdown() }
    @objc func splitView() { controller?.startSplit() }
    @objc func closeSplitView() { controller?.closeSplit() }
    @objc func zoomIn() { controller?.chromeCommand(ChaCommand.Chrome.zoomIn) }
    @objc func zoomOut() { controller?.chromeCommand(ChaCommand.Chrome.zoomOut) }
    @objc func zoomReset() { controller?.chromeCommand(ChaCommand.Chrome.zoomReset) }
    @objc func printPage() { controller?.chromeCommand(ChaCommand.Chrome.print) }
    @objc func devTools() { controller?.chromeCommand(ChaCommand.Chrome.devTools) }
    @objc func viewSource() { controller?.chromeCommand(ChaCommand.Chrome.viewSource) }
    @objc func showWindow() { controller?.showMainWindow() }
    @objc func makeDefaultBrowser() { URLOpener.makeDefault() }
    @objc func pictureInPicture() { controller?.togglePictureInPicture() }
    @objc func findInPage() { controller?.openFindBar() }
    @objc func findNext() { controller?.findNext(forward: true) }
    @objc func findPrevious() { controller?.findNext(forward: false) }
    @objc func duplicateTab() {
        guard let c = controller, let id = c.activeTabID else { return }
        c.duplicateTab(id)
    }
    @objc func resetPinned() {
        guard let c = controller, let id = c.activeTabID else { return }
        c.resetToPinnedURL(id)
    }
    @objc func clearToday() { controller?.clearToday() }
    @objc func showDownloads() { controller?.toggleDownloads() }
    // Chromium's own password manager, reachable without a toolbar.
    @objc func passwords() {
        controller?.newTab(url: "chrome://password-manager/passwords")
    }
    @objc func importPasswords() {
        controller?.newTab(url: "chrome://password-manager/settings")
    }

    // Verification codes: the app keeps the TOTP secrets and types the code.
    @objc func fillCode() { controller?.fillVerificationCode() }
    @objc func addCode() { controller?.addVerificationCode() }
    @objc func importCodes() { controller?.importVerificationCodes() }
    @objc func fillCodeEntry(_ sender: NSMenuItem) {
        guard let entry = entry(for: sender) else { return }
        controller?.fill(entry)
    }
    @objc func copyCodeEntry(_ sender: NSMenuItem) {
        guard let code = entry(for: sender)?.code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
    @objc func removeCodeEntry(_ sender: NSMenuItem) {
        guard let entry = entry(for: sender) else { return }
        CodeStore.shared.remove(entry.id)
    }

    private func entry(for item: NSMenuItem) -> CodeEntry? {
        guard let id = item.representedObject as? UUID else { return nil }
        return CodeStore.shared.entries.first { $0.id == id }
    }
    @objc func toggleSidebar() { controller?.toggleSidebar() }
    @objc func reload() { controller?.reload() }
    @objc func reloadClearingCache() { controller?.reloadClearingCache() }
    @objc func goBack() { controller?.goBack() }
    @objc func goForward() { controller?.goForward() }
    @objc func focusAddressBar() { controller?.openCommandBar(mode: .current) }
    @objc func nextSpace() { controller?.cycleSpace(by: 1) }
    @objc func previousSpace() { controller?.cycleSpace(by: -1) }
}
