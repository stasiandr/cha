import AppKit
import SwiftUI

// Opening, filtering and running the command bar.
extension BrowserController {
    func openCommandBar(mode: CommandMode) {
        commandBarOpens += 1
        commandMode = mode
        commandQuery = mode == .current ? (activeTab?.currentURL ?? "") : ""
        commandSelection = 0
        refreshCommandResults()
        if mode == .tabs { refreshTabTexts() }

        let panel = commandPanel ?? makeCommandPanel()
        commandPanel = panel
        panel.setFrame(commandPanelFrame, display: true)
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        if mode != .tabs { InputSource.useASCII() }
        commandFocusToken += 1
        installCommandKeyMonitor()
    }

    func closeCommandBar() {
        if let monitor = commandKeyMonitor {
            NSEvent.removeMonitor(monitor)
            commandKeyMonitor = nil
        }
        InputSource.restore()
        guard let panel = commandPanel else { return }
        if panel.parent != nil { window.removeChildWindow(panel) }
        panel.orderOut(nil)
        activeTab?.focus()
    }

    private func makeCommandPanel() -> CommandPanel {
        let panel = CommandPanel(
            contentRect: commandPanelFrame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The panel keeps one size; the card inside casts its own shadow.
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: CommandBarView(controller: self))
        hosting.sizingOptions = []  // The panel decides the size, not SwiftUI.
        panel.contentView = hosting
        panel.delegate = CommandPanelDelegate.shared
        CommandPanelDelegate.shared.controller = self
        return panel
    }

    // One size for the panel, whatever the results: room for the field and
    // `commandMaxRows` rows, the card at its top and clear (click-through)
    // below it. It used to be resized to every new result count, which
    // flickered. The field sits in the middle of the page, a little above
    // centre, as Arc's. Around the card, room for all of its shadow: with
    // too little, the panel's edge cut the shadow into a dark rectangle.
    static let commandWidth: CGFloat = 596  // The card's.
    static let commandFieldHeight: CGFloat = 58
    static let commandRowHeight: CGFloat = 44
    /// More results than fit pushed the field out of the panel's top.
    static let commandMaxRows = 8
    static let commandShadowMargin: CGFloat = 44
    static let commandHeight: CGFloat =
        commandFieldHeight + CGFloat(commandMaxRows) * commandRowHeight + 13 + 2 * commandShadowMargin

    var commandPanelFrame: NSRect {
        let content = contentScreenRect
        let margin = Self.commandShadowMargin
        let width = min(Self.commandWidth, content.width - 40) + 2 * margin
        let fieldCentre = content.midY + content.height * 0.08
        let top = fieldCentre + Self.commandFieldHeight / 2 + margin
        return NSRect(
            x: content.midX - width / 2, y: top - Self.commandHeight,
            width: width, height: Self.commandHeight)
    }

    /// At most `commandMaxRows`: pages visited before go first, then
    /// archived tabs, open tabs, commands; the first row (what Return opens)
    /// and the search stay.
    static func fitting(_ results: [CommandResult]) -> [CommandResult] {
        var results = results
        let drops: [(CommandResult) -> Bool] = [
            { if case .history = $0 { return true }; return false },
            { if case .archived = $0 { return true }; return false },
            { if case .tab = $0 { return true }; if case .found = $0 { return true }; return false },
            { if case .command = $0 { return true }; return false },
        ]
        for drop in drops {
            while results.count > commandMaxRows,
                let index = results.indices.dropFirst().last(where: { drop(results[$0]) })
            {
                results.remove(at: index)
            }
        }
        return Array(results.prefix(commandMaxRows))
    }

    private func installCommandKeyMonitor() {
        guard commandKeyMonitor == nil else { return }
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, self.commandPanel?.isVisible == true else { return event }
            switch event.keyCode {
            case 53:  // Escape
                self.closeCommandBar()
                return nil
            case 125:  // Down
                self.commandSelection = min(
                    self.commandSelection + 1, max(self.commandResults.count - 1, 0))
                return nil
            case 126:  // Up
                self.commandSelection = max(self.commandSelection - 1, 0)
                return nil
            default:
                return event
            }
        }
    }

    func repositionCommandPanel() {
        guard let panel = commandPanel, panel.isVisible else { return }
        let frame = commandPanelFrame
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    func refreshCommandResults() {
        let query = commandQuery.trimmingCharacters(in: .whitespaces)
        var results: [CommandResult] = []

        if commandMode == .tabs {
            commandResults = Self.fitting(tabSearchResults(query))
            commandSelection = min(commandSelection, max(commandResults.count - 1, 0))
            return
        }

        // An otpauth:// link is a secret, not an address: offer to keep it.
        if query.lowercased().hasPrefix("otpauth://"), OTPAuth.parse(query) != nil {
            commandResults = [.addCode(uri: query)]
            commandSelection = 0
            return
        }

        if !query.isEmpty {
            let lowered = query.lowercased()
            for space in visibleSpaces where space.id != activeSpaceID
                && space.name.lowercased().hasPrefix(lowered)
            {
                results.append(.space(id: space.id, name: space.name))
            }
            for tab in favorites
            where tab.displayTitle.lowercased().contains(lowered)
                || tab.url.lowercased().contains(lowered)
            {
                results.append(
                    .tab(spaceID: activeSpaceID, tabID: tab.id, title: tab.displayTitle, url: tab.url))
            }
            // The secret space's tabs turn up only from inside it.
            for space in spaces where !space.isSecret || space.id == activeSpaceID {
                for tab in space.tabs
                where tab.displayTitle.lowercased().contains(lowered)
                    || tab.url.lowercased().contains(lowered)
                {
                    results.append(
                        .tab(
                            spaceID: space.id, tabID: tab.id,
                            title: tab.displayTitle, url: tab.url))
                }
            }
            results = Array(results.prefix(6))

            // A command whose name starts with what was typed comes before
            // pages and the search ("copy" means Copy URL, as in Arc); one
            // found by another word of it comes after the search.
            let commands = ChaCommand.matching(query).prefix(3)
            let namedCommands = commands.filter { $0.title.lowercased().hasPrefix(lowered) }
            let otherCommands = commands.filter { !$0.title.lowercased().hasPrefix(lowered) }
            for command in namedCommands { results.append(.command(command)) }

            // Archived tabs of this space, as in Arc's archive search.
            let archivedHits = archive.filter {
                ($0.spaceID == nil || $0.spaceID == activeSpaceID)
                    && ($0.title.lowercased().contains(lowered) || $0.url.lowercased().contains(lowered))
            }
            for item in archivedHits.prefix(2) {
                results.append(.archived(id: item.id, title: item.title, url: item.url))
            }

            // Pages visited before in this space (another space has other
            // accounts signed in), but not those an open tab already shows.
            let shown = Set(results.compactMap { result -> String? in
                if case .tab(_, _, _, let url) = result { return url }
                return nil
            })
            let visited = history.search(query, in: activeSpaceID).filter { !shown.contains($0.entry.url) }
            for hit in visited.prefix(max(0, 8 - results.count)) {
                results.append(.history(title: hit.entry.title, url: hit.entry.url))
            }

            let target = normalizedURL(from: query)
            let typedAddress = target.contains("google.com/search") ? nil : target
            // "app" with App Store Connect visited before: Return goes there,
            // as in Chrome and Arc, not to a search for "app". An address
            // typed out ("example.com") still opens as typed.
            if let typedAddress {
                results.insert(.open(url: typedAddress), at: 0)
            } else if let best = visited.first, best.prefix, !opensTab(startingWith: lowered, results) {
                let hit = CommandResult.history(title: best.entry.title, url: best.entry.url)
                results.removeAll { $0 == hit }
                results.insert(hit, at: 0)
                results.append(.search(query: query))
            } else {
                results.append(.search(query: query))
            }
            for command in otherCommands { results.append(.command(command)) }
        }

        commandResults = Self.fitting(results)
        commandSelection = min(commandSelection, max(commandResults.count - 1, 0))
    }

    // An open tab whose address starts with the query stays the first choice.
    private func opensTab(startingWith query: String, _ results: [CommandResult]) -> Bool {
        results.contains {
            if case .tab(_, _, _, let url) = $0 { return History.bare(url).hasPrefix(query) }
            return false
        }
    }

    func runSelectedCommand() {
        guard commandResults.indices.contains(commandSelection) else {
            guard commandMode != .tabs else { return }
            let query = commandQuery.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty { runCommand(.open(url: normalizedURL(from: query))) }
            return
        }
        runCommand(commandResults[commandSelection])
    }

    func runCommand(_ result: CommandResult) {
        switch result {
        case .tab(let spaceID, let tabID, _, _), .found(let spaceID, let tabID, _, _):
            if spaceID != activeSpaceID { selectSpace(spaceID) }
            activateTab(tabID)
        case .open(let url), .history(_, let url):
            openFromCommandBar(url)
        case .search(let query):
            openFromCommandBar(normalizedURL(from: query))
        case .space(let id, _):
            selectSpace(id)
        case .archived(let id, _, _):
            restoreArchived(id)
        case .command(let command):
            closeCommandBar()
            run(command)
            return
        case .addCode(let uri):
            if let entry = OTPAuth.parse(uri, site: activeHost) {
                CodeStore.shared.add(entry)
            }
        }
        closeCommandBar()
    }

    private func openFromCommandBar(_ url: String) {
        switch commandMode {
        case .newTab: newTab(url: url)
        case .current: navigate(to: url)
        case .split: openInSplit(url)
        case .tabs: newTab(url: url)
        }
    }
}


// Clicking outside the panel dismisses it.
final class CommandPanelDelegate: NSObject, NSWindowDelegate {
    static let shared = CommandPanelDelegate()
    weak var controller: BrowserController?

    func windowDidResignKey(_ notification: Notification) {
        controller?.closeCommandBar()
    }
}
