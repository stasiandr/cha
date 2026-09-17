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
        app.addItem(
            withTitle: "Hide cha", action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        app.addItem(
            withTitle: "Quit cha", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        bar.addItem(submenu: app, title: "cha")

        let file = NSMenu(title: "File")
        file.add("New Tab", "t", target, #selector(MenuTarget.newTab))
        file.add("Close Tab", "w", target, #selector(MenuTarget.closeTab))
        file.add("Empty Tab", "t", target, #selector(MenuTarget.emptyTab), [.command, .shift])
        file.addItem(.separator())
        file.add("New Space", "n", target, #selector(MenuTarget.newSpace), [.command, .shift])
        file.addItem(.separator())
        file.add("Passwords…", "", target, #selector(MenuTarget.passwords), [])
        file.add(
            "Import Passwords…", "", target, #selector(MenuTarget.importPasswords), [])
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
        bar.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        view.add("Toggle Sidebar", "s", target, #selector(MenuTarget.toggleSidebar))
        view.add("Reload", "r", target, #selector(MenuTarget.reload))
        view.addItem(.separator())
        let fullscreen = NSMenuItem(
            title: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        view.addItem(fullscreen)
        bar.addItem(submenu: view, title: "View")

        let navigate = NSMenu(title: "Navigate")
        navigate.add("Back", "[", target, #selector(MenuTarget.goBack))
        navigate.add("Forward", "]", target, #selector(MenuTarget.goForward))
        navigate.addItem(.separator())
        navigate.add(
            "Open Location", "l", target, #selector(MenuTarget.focusAddressBar))
        navigate.addItem(.separator())
        navigate.add(
            "Next Space", String(UnicodeScalar(NSRightArrowFunctionKey)!), target,
            #selector(MenuTarget.nextSpace), [.command, .option])
        navigate.add(
            "Previous Space", String(UnicodeScalar(NSLeftArrowFunctionKey)!), target,
            #selector(MenuTarget.previousSpace), [.command, .option])
        // ⌘1…⌘9 pick a tab in the current space; the items stay hidden.
        for number in 1...9 {
            let item = NSMenuItem(
                title: "Tab \(number)", action: #selector(MenuTarget.selectTabByNumber(_:)),
                keyEquivalent: String(number))
            item.tag = number - 1
            item.target = target
            item.isHidden = true
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
final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    var controller: BrowserController?

    @objc func newTab() { controller?.openCommandBar(mode: .newTab) }
    @objc func closeTab() { controller?.closeActiveTab() }
    @objc func emptyTab() { controller?.newTab() }
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        controller?.activateTabAtIndex(sender.tag)
    }
    @objc func newSpace() { controller?.addSpace() }
    // Chromium's own password manager, reachable without a toolbar.
    @objc func passwords() {
        controller?.newTab(url: "chrome://password-manager/passwords")
    }
    @objc func importPasswords() {
        controller?.newTab(url: "chrome://password-manager/settings")
    }
    @objc func toggleSidebar() { controller?.toggleSidebar() }
    @objc func reload() { controller?.reload() }
    @objc func goBack() { controller?.goBack() }
    @objc func goForward() { controller?.goForward() }
    @objc func focusAddressBar() { controller?.openCommandBar(mode: .current) }
    @objc func nextSpace() { controller?.cycleSpace(by: 1) }
    @objc func previousSpace() { controller?.cycleSpace(by: -1) }
}
