import AppKit

// A page asking for full screen (YouTube's ⛶ or F, any video's own button)
// gets the whole screen, as in Chrome and Arc: cha's window goes full screen
// and the sidebar steps aside; Esc or the page's button puts both back as
// they were. Chromium has already sized the content to the page area.
extension BrowserController {
    func tab(_ tab: ChaTab, pageFullscreen fullscreen: Bool) {
        guard let id = tabIDsByObject[ObjectIdentifier(tab)] else { return }
        if fullscreen {
            // Only the tab in front (or its split partner) takes the screen.
            guard id == activeTabID || activeTabID.flatMap({ splitPartner($0) }) == id else {
                tab.executeJavaScript("document.fullscreenElement && document.exitFullscreen()")
                return
            }
            if pageFullscreen == nil {
                pageFullscreen = (id, isFullscreen, sidebarVisible)
            }
            if sidebarVisible { toggleSidebar(animated: false) }
            NSLog("PAGE full screen: %@", inSecretSpace ? "(secret space)" : tab.currentURL)
            // Quiet runs (the checks) never take the screen: only the sidebar goes.
            if !isFullscreen, !Diagnostics.quiet, let window {
                // The click on ⛶ made the page's own window key; macOS
                // takes to full screen only the window in front of a
                // frontmost app.
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.toggleFullScreen(nil)
            }
        } else {
            guard let page = pageFullscreen, page.tab == id else { return }
            pageFullscreen = nil
            if page.sidebarWasVisible, !sidebarVisible { toggleSidebar(animated: false) }
            if !page.windowWasFullscreen, isFullscreen { window?.toggleFullScreen(nil) }
            NSLog("PAGE left full screen")
        }
    }

    /// Switching tabs ends a page's full screen, as in Chrome.
    func endPageFullscreen() {
        guard let page = pageFullscreen else { return }
        liveTabs[page.tab]?.executeJavaScript("document.fullscreenElement && document.exitFullscreen()")
    }
}
