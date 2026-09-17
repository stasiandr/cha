import AppKit
import SwiftUI

// Opening, filtering and running the command bar.
extension BrowserController {
    func openCommandBar(mode: CommandMode) {
        commandMode = mode
        commandQuery = mode == .current ? (activeTab?.currentURL ?? "") : ""
        commandSelection = 0
        refreshCommandResults()

        let panel = commandPanel ?? makeCommandPanel()
        commandPanel = panel
        panel.setFrame(commandPanelFrame, display: true)
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        installCommandKeyMonitor()
    }

    func closeCommandBar() {
        if let monitor = commandKeyMonitor {
            NSEvent.removeMonitor(monitor)
            commandKeyMonitor = nil
        }
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
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: CommandBarView(controller: self))
        hosting.sizingOptions = []  // The panel decides the size, not SwiftUI.
        panel.contentView = hosting
        panel.delegate = CommandPanelDelegate.shared
        CommandPanelDelegate.shared.controller = self
        return panel
    }

    // Field plus one row per result, anchored near the top of the content.
    private var commandPanelFrame: NSRect {
        let content = contentScreenRect
        let width: CGFloat = min(620, content.width - 40)
        let rows = CGFloat(commandResults.count)
        let height = 58 + (rows > 0 ? rows * 44 + 13 : 0)
        return NSRect(
            x: content.midX - width / 2, y: content.maxY - height - 90,
            width: width, height: height)
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

    // Called after the result list changes so the panel keeps its top edge.
    func repositionCommandPanel() {
        guard let panel = commandPanel, panel.isVisible else { return }
        panel.setFrame(commandPanelFrame, display: true)
    }

    func refreshCommandResults() {
        let query = commandQuery.trimmingCharacters(in: .whitespaces)
        var results: [CommandResult] = []

        if !query.isEmpty {
            let lowered = query.lowercased()
            for space in spaces {
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
            results = Array(results.prefix(5))

            let target = normalizedURL(from: query)
            if target.contains("google.com/search") {
                results.append(.search(query: query))
            } else {
                results.insert(.open(url: target), at: 0)
            }
        }

        commandResults = results
        commandSelection = min(commandSelection, max(results.count - 1, 0))
        DispatchQueue.main.async { [weak self] in self?.repositionCommandPanel() }
    }

    func runSelectedCommand() {
        guard commandResults.indices.contains(commandSelection) else {
            let query = commandQuery.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty { runCommand(.open(url: normalizedURL(from: query))) }
            return
        }
        runCommand(commandResults[commandSelection])
    }

    func runCommand(_ result: CommandResult) {
        switch result {
        case .tab(let spaceID, let tabID, _, _):
            if spaceID != activeSpaceID { selectSpace(spaceID) }
            activateTab(tabID)
        case .open(let url):
            openFromCommandBar(url)
        case .search(let query):
            openFromCommandBar(normalizedURL(from: query))
        }
        closeCommandBar()
    }

    private func openFromCommandBar(_ url: String) {
        switch commandMode {
        case .newTab: newTab(url: url)
        case .current: navigate(to: url)
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
