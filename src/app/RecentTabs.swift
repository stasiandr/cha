import AppKit

// Arc's ⌃Tab: back to the tab used before this one. Holding ⌃ and pressing
// Tab again goes further back, as ⌘Tab does with apps; ⌃⇧Tab goes the other
// way. Letting go of ⌃ settles on the tab, which becomes the most recent;
// the ones passed on the way keep their places.
extension BrowserController {
    /// The space's tabs and the favourites, most recently used first.
    var recentTabs: [UUID] {
        let space = activeSpace
        let all = favorites + space.tabs
        return all.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }.map(\.id)
    }

    func installRecentTabsMonitor() {
        guard recentTabsMonitor == nil else { return }
        recentTabsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                if !event.modifierFlags.contains(.control) { self.endRecentTabsCycle() }
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 48, flags.contains(.control), !flags.contains(.command),
                !flags.contains(.option)
            else { return event }
            self.stepRecentTabs(backwards: flags.contains(.shift))
            return nil
        }
    }

    /// One press of Tab with ⌃ held.
    func stepRecentTabs(backwards: Bool = false) {
        if recentCycle == nil {
            recentCycle = recentTabs
            recentCycleIndex = 0
        }
        guard let cycle = recentCycle, cycle.count > 1 else { return }
        recentCycleIndex = (recentCycleIndex + (backwards ? -1 : 1) + cycle.count) % cycle.count
        keepRecency = true
        activateTab(cycle[recentCycleIndex], transition: .none)
        keepRecency = false
    }

    /// ⌃ let go: the tab reached is the most recent now.
    func endRecentTabsCycle() {
        guard recentCycle != nil else { return }
        recentCycle = nil
        if let id = activeTabID { update(tabID: id) { $0.lastActive = Date() } }
    }
}
