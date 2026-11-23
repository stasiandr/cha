import AppKit

// Arc's command bar does things, not only finds pages: "copy", "new space",
// "clear" run the command. Each one is also in the menu bar with Arc's key.
struct ChaCommand: Equatable {
    let id: String
    let title: String
    let symbol: String
    let keys: String  // As the menu shows it, for the row's subtitle.
    let words: [String]  // Other names it is found by.

    static func == (a: ChaCommand, b: ChaCommand) -> Bool { a.id == b.id }

    // Chromium's own command ids (chrome/app/chrome_command_ids.h).
    enum Chrome {
        static let viewSource: Int32 = 35002
        static let print: Int32 = 35003
        static let zoomIn: Int32 = 38001
        static let zoomReset: Int32 = 38002
        static let zoomOut: Int32 = 38003
        static let devTools: Int32 = 40004
    }

    static let all: [ChaCommand] = [
        .init(id: "copy-url", title: "Copy URL", symbol: "link", keys: "⇧⌘C", words: ["link", "address"]),
        .init(id: "copy-markdown", title: "Copy URL as Markdown", symbol: "text.quote", keys: "⌥⇧⌘C", words: ["link", "md"]),
        .init(id: "duplicate", title: "Duplicate Tab", symbol: "plus.square.on.square", keys: "", words: ["copy tab"]),
        .init(id: "pin", title: "Pin / Unpin Tab", symbol: "pin", keys: "⌘D", words: []),
        .init(id: "favorite", title: "Add to Favorites", symbol: "star", keys: "⇧⌘D", words: ["favourite"]),
        .init(id: "close", title: "Close Tab", symbol: "xmark", keys: "⌘W", words: []),
        .init(id: "reopen", title: "Reopen Closed Tab", symbol: "arrow.uturn.backward", keys: "⇧⌘T", words: ["undo close"]),
        .init(id: "clear", title: "Clear Today's Tabs", symbol: "archivebox", keys: "⇧⌘K", words: ["archive"]),
        .init(id: "reload", title: "Reload", symbol: "arrow.clockwise", keys: "⌘R", words: ["refresh"]),
        .init(id: "hard-reload", title: "Clear Cache and Reload", symbol: "arrow.clockwise.circle", keys: "⇧⌘R", words: ["hard reload"]),
        .init(id: "find", title: "Find in Page", symbol: "text.magnifyingglass", keys: "⌘F", words: ["search page"]),
        .init(id: "zoom-in", title: "Zoom In", symbol: "plus.magnifyingglass", keys: "⌘+", words: ["bigger", "larger"]),
        .init(id: "zoom-out", title: "Zoom Out", symbol: "minus.magnifyingglass", keys: "⌘−", words: ["smaller"]),
        .init(id: "zoom-reset", title: "Actual Size", symbol: "1.magnifyingglass", keys: "⌘0", words: ["zoom reset"]),
        .init(id: "print", title: "Print…", symbol: "printer", keys: "⌘P", words: ["pdf"]),
        .init(id: "devtools", title: "Developer Tools", symbol: "hammer", keys: "⌥⌘I", words: ["inspect", "console"]),
        .init(id: "source", title: "View Source", symbol: "chevron.left.forwardslash.chevron.right", keys: "⌥⌘U", words: ["html"]),
        .init(id: "pip", title: "Picture in Picture", symbol: "pip", keys: "⌥⌘P", words: ["float", "video"]),
        .init(id: "sidebar", title: "Toggle Sidebar", symbol: "sidebar.left", keys: "⌘S", words: ["hide sidebar", "show sidebar"]),
        .init(id: "new-space", title: "New Space", symbol: "square.stack.badge.plus", keys: "⇧⌘N", words: ["add space"]),
        .init(id: "edit-space", title: "Edit Space", symbol: "paintpalette", keys: "", words: ["rename space", "theme", "colour", "color"]),
        .init(id: "new-folder", title: "New Folder", symbol: "folder.badge.plus", keys: "", words: []),
        .init(id: "little-window", title: "New Little Window", symbol: "macwindow", keys: "⌥⌘N", words: ["little arc"]),
        .init(id: "split", title: "Split View", symbol: "rectangle.split.2x1", keys: "⌃⇧=", words: ["side by side"]),
        .init(id: "unsplit", title: "Close Split View", symbol: "rectangle", keys: "⌃⇧-", words: ["separate"]),
        .init(id: "boost", title: "Boost This Site", symbol: "paintbrush", keys: "", words: ["css", "style", "customize", "zap"]),
        .init(id: "routing", title: "Route Links to Spaces…", symbol: "arrow.triangle.branch", keys: "", words: ["air traffic control", "rules", "links from apps"]),
        .init(id: "new-note", title: "New Note", symbol: "note.text", keys: "⌃⌘N", words: ["easel", "write", "notes"]),
        .init(id: "capture", title: "Capture", symbol: "camera.viewfinder", keys: "⇧⌘2", words: ["screenshot", "picture"]),
        .init(id: "downloads", title: "Downloads", symbol: "arrow.down.circle", keys: "⇧⌘L", words: []),
    ]

    /// Commands whose name (or another name) has every word typed, the ones
    /// starting with what was typed first.
    static func matching(_ query: String) -> [ChaCommand] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty, query.count >= 2 else { return [] }
        let hits = all.filter { command in
            let names = ([command.title] + command.words).map { $0.lowercased() }
            return words.allSatisfy { word in names.contains { $0.contains(word) } }
        }
        let lowered = query.lowercased()
        return hits.sorted { a, b in
            let pa = a.title.lowercased().hasPrefix(lowered), pb = b.title.lowercased().hasPrefix(lowered)
            return pa && !pb
        }
    }
}

extension BrowserController {
    func run(_ command: ChaCommand) {
        let tab = activeTabID
        switch command.id {
        case "copy-url": copyLink()
        case "copy-markdown": copyLinkAsMarkdown()
        case "duplicate": if let tab { duplicateTab(tab) }
        case "pin": if let tab { togglePin(tab) }
        case "favorite": if let tab { addToFavorites(tab) }
        case "close": closeActiveTab()
        case "reopen": reopenClosedTab()
        case "clear": clearToday()
        case "reload": reload()
        case "hard-reload": reloadClearingCache()
        case "find": openFindBar()
        case "zoom-in": chromeCommand(ChaCommand.Chrome.zoomIn)
        case "zoom-out": chromeCommand(ChaCommand.Chrome.zoomOut)
        case "zoom-reset": chromeCommand(ChaCommand.Chrome.zoomReset)
        case "print": chromeCommand(ChaCommand.Chrome.print)
        case "devtools": chromeCommand(ChaCommand.Chrome.devTools)
        case "source": chromeCommand(ChaCommand.Chrome.viewSource)
        case "pip": togglePictureInPicture()
        case "sidebar": toggleSidebar()
        case "new-space": addSpace()
        case "edit-space": editSpace(activeSpaceID)
        case "new-folder": _ = addFolder()
        case "little-window": openLittleWindow("about:blank")
        case "downloads": toggleDownloads()
        case "capture": startCapture()
        case "new-note": newNote()
        case "routing": openRoutingRules()
        case "boost": openBoostEditor()
        case "split": startSplit()
        case "unsplit": closeSplit()
        default: break
        }
    }

    /// Runs one of Chromium's own commands on the page (zoom, print, tools).
    func chromeCommand(_ id: Int32) {
        guard let tab = activeTab, tab.canExecuteChromeCommand(id) else {
            NSSound.beep()
            return
        }
        tab.executeChromeCommand(id)
    }

    /// Arc's ⌥⇧⌘C: [Title](url), ready for a chat or a doc.
    func copyLinkAsMarkdown(_ id: UUID? = nil) {
        guard let id = id ?? activeSpace.activeTabID, let tab = tabData(id) else { return }
        let url = liveTabs[id]?.currentURL ?? tab.url
        let title = tab.displayTitle.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        BrowserController.clipboard.clearContents()
        BrowserController.clipboard.setString("[\(title)](\(url))", forType: .string)
        showToast("Copied as Markdown")
    }
}
