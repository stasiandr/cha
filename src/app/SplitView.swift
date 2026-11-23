import AppKit

// Arc's Split View: two tabs of a space side by side in the page area. ⌃⇧=
// asks for a page (the command bar) and opens it to the right of the tab in
// front; ⌃⇧- puts them back apart. Going to either tab shows both, the one
// gone to taking the keys; a click in the other page makes it the one in
// front. The pair is kept with the tabs (TabData.splitWith), so it survives
// a restart.
extension BrowserController {
    static let splitGap: CGFloat = 8

    /// The other tab of a split, when both are still in the same space.
    func splitPartner(_ id: UUID) -> UUID? {
        guard let partner = tabData(id)?.splitWith, let space = spaceContaining(id),
            space.tabs.contains(where: { $0.id == partner }),
            tabData(partner)?.splitWith == id
        else { return nil }
        return partner
    }

    /// The two tabs of the split the tab is in, left one first (the one
    /// higher in the sidebar).
    func splitPair(_ id: UUID) -> (left: UUID, right: UUID)? {
        guard let partner = splitPartner(id), let space = spaceContaining(id),
            let a = space.tabs.firstIndex(where: { $0.id == id }),
            let b = space.tabs.firstIndex(where: { $0.id == partner })
        else { return nil }
        return a < b ? (id, partner) : (partner, id)
    }

    /// Where a tab's page goes: the whole page area, or its half of a split.
    func pageFrame(for id: UUID) -> NSRect {
        let whole = contentScreenRect
        guard let pair = splitPair(id) else { return whole }
        let width = (whole.width - Self.splitGap) / 2
        var left = whole
        left.size.width = width.rounded(.down)
        var right = whole
        right.origin.x = left.maxX + Self.splitGap
        right.size.width = whole.maxX - right.origin.x
        return pair.left == id ? left : right
    }

    var activeSplit: (left: UUID, right: UUID)? {
        activeTabID.flatMap { splitPair($0) }
    }

    /// ⌃⇧=: the command bar asks what to open beside the tab in front.
    func startSplit() {
        guard let id = activeTabID, spaceContaining(id) != nil else {
            NSSound.beep()
            return
        }
        if splitPartner(id) != nil { closeSplit() }
        openCommandBar(mode: .split)
    }

    /// Puts two tabs of the space side by side.
    func split(_ id: UUID, with other: UUID) {
        guard id != other, let space = spaceContaining(id), spaceContaining(other)?.id == space.id
        else { return }
        for tab in [id, other] { unsplit(tab) }
        update(tabID: id) { $0.splitWith = other }
        update(tabID: other) { $0.splitWith = id }
        activateTab(other, transition: .none)
    }

    /// The command bar's answer to ⌃⇧=: a new tab beside the one in front.
    func openInSplit(_ url: String) {
        guard let left = activeTabID else { return newTab(url: url) }
        newTab(url: url)
        guard let right = activeTabID, right != left else { return }
        // The new tab goes right under the one it is split with.
        moveTab(right, after: left)
        split(left, with: right)
    }

    /// ⌃⇧-: the split of the tab in front comes apart; it keeps the page area.
    func closeSplit() {
        guard let id = activeTabID, splitPartner(id) != nil else { return }
        unsplit(id)
        activateTab(id, transition: .none)
    }

    func unsplit(_ id: UUID) {
        guard let partner = tabData(id)?.splitWith else { return }
        update(tabID: id) { $0.splitWith = nil }
        if tabData(partner)?.splitWith == id { update(tabID: partner) { $0.splitWith = nil } }
    }

    private func moveTab(_ id: UUID, after anchor: UUID) {
        guard var space = spaceContaining(id), let from = space.tabs.firstIndex(where: { $0.id == id })
        else { return }
        // Only within its own section: a split doesn't pin a tab.
        guard let anchorTab = space.tabs.first(where: { $0.id == anchor }),
            anchorTab.isPinned == space.tabs[from].isPinned, anchorTab.folderID == space.tabs[from].folderID
        else { return }
        let tab = space.tabs.remove(at: from)
        guard let to = space.tabs.firstIndex(where: { $0.id == anchor }) else { return }
        space.tabs.insert(tab, at: to + 1)
        replace(space)
    }
}
