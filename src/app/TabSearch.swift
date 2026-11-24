import AppKit

// Search All Tabs (⇧⌘F): every tab of every space by its title, its address
// and the text on its page. ⌘T finds tabs by title and address; this one
// also finds the tab that said something. A page's text is read when it
// finishes loading and again when the search opens, and kept (tab-text.json
// in the profile) so tabs that are not loaded now are found too. The secret
// space's pages are never read, and turn up by title only from inside it.
final class TabTextStore {
    struct Entry: Codable {
        var url: String
        var text: String
    }

    /// As much of a page as is read: enough for a long article.
    static let limit = 20000

    private(set) var entries: [UUID: Entry] = [:]
    private let fileURL: URL
    private var saveWork: DispatchWorkItem?
    private static let disk = DispatchQueue(label: "cha.tab-text", qos: .utility)

    init(file: URL = Persistence.directory.appendingPathComponent("tab-text.json")) {
        fileURL = file
        if let data = try? Data(contentsOf: file),
            let saved = try? JSONDecoder().decode([UUID: Entry].self, from: data)
        {
            entries = saved
        }
    }

    /// What the tab's page said when last read (a tab that is not loaded
    /// can't have moved on since).
    func text(of id: UUID) -> String? { entries[id]?.text }

    func set(_ text: String, of id: UUID, at url: String) {
        guard entries[id]?.text != text || entries[id]?.url != url else { return }
        entries[id] = Entry(url: url, text: text)
        scheduleSave()
    }

    /// Tabs that are gone take their text with them.
    func keep(only ids: Set<UUID>) {
        let before = entries.count
        entries = entries.filter { ids.contains($0.key) }
        if entries.count != before { scheduleSave() }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }

    func save(wait: Bool = false) {
        saveWork?.cancel()
        saveWork = nil
        let snapshot = entries
        let file = fileURL
        let write = {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        if wait { Self.disk.sync(execute: write) } else { Self.disk.async(execute: write) }
    }
}

extension BrowserController {
    /// The page's visible text (whitespace run together), through the renderer.
    func pageText(_ tab: ChaTab, _ done: @escaping (String) -> Void) {
        let token = UUID().uuidString
        pageTextRequests[token] = done
        tab.executeJavaScript(
            "console.log('__cha_app__ text \(token) ' + JSON.stringify((document.body && document.body.innerText || '')"
                + ".replace(/\\s+/g, ' ').trim().slice(0, \(TabTextStore.limit))))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if let done = self?.pageTextRequests.removeValue(forKey: token) { done("") }
        }
    }

    /// "text <token> <json string>" from the page.
    func receivePageText(_ message: String) {
        let parts = message.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, let done = pageTextRequests.removeValue(forKey: parts[1]) else { return }
        let text = (try? JSONSerialization.jsonObject(with: Data(parts[2].utf8), options: .fragmentsAllowed)) as? String
        done(text ?? "")
    }

    private func readsText(of id: UUID) -> Bool {
        spaceContaining(id)?.isSecret != true
    }

    /// Reads a live tab's text into the store; `done` once it is in.
    func indexText(of id: UUID, done: (() -> Void)? = nil) {
        guard readsText(of: id), let tab = liveTabs[id] else {
            done?()
            return
        }
        let url = tab.currentURL
        pageText(tab) { [weak self] text in
            // A tab gone or moved on meanwhile keeps what it had.
            if let self, !text.isEmpty, self.liveTabs[id] === tab, tab.currentURL == url {
                self.tabText.set(text, of: id, at: url)
            }
            done?()
        }
    }

    /// After a page loads (a moment later: pages fill themselves in).
    func indexTextAfterLoad(_ tab: ChaTab, id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.indexText(of: id)
        }
    }

    /// When the search opens: every loaded tab read afresh, the results
    /// following as the texts come in.
    func refreshTabTexts(done: (() -> Void)? = nil) {
        let known = Set(spaces.flatMap { $0.tabs.map(\.id) } + favorites.map(\.id))
        tabText.keep(only: known)
        let ids = liveTabs.keys.filter { known.contains($0) }
        let group = DispatchGroup()
        for id in ids {
            group.enter()
            indexText(of: id) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if self.commandMode == .tabs, self.commandPanel?.isVisible == true { self.refreshCommandResults() }
            done?()
        }
    }

    /// Tabs with every word of the query in their title, address or text:
    /// title hits first, then address, then text.
    func tabSearchResults(_ query: String) -> [CommandResult] {
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func has(_ haystack: String, _ word: String) -> Bool { haystack.range(of: word, options: options) != nil }

        var candidates: [(space: SpaceData?, tab: TabData)] = favorites.map { (nil, $0) }
        for space in spaces where !space.isSecret || space.id == activeSpaceID {
            candidates += space.tabs.map { (space, $0) }
        }
        var scored: [(rank: Int, result: CommandResult)] = []
        for (space, tab) in candidates {
            let title = tab.displayTitle
            // A page cha makes (a note, an easel) has all of itself in its
            // data: address: it is found by what it shows, not by that.
            let url = tab.url.hasPrefix("data:") ? "" : tab.url
            let text = readsText(of: tab.id) ? (tabText.text(of: tab.id) ?? "") : ""
            guard words.allSatisfy({ has(title, $0) || has(url, $0) || has(text, $0) }) else { continue }
            let rank: Int
            var detail: String
            if words.allSatisfy({ has(title, $0) }) {
                rank = 0
                detail = History.bare(url)
            } else if words.allSatisfy({ has(title, $0) || has(url, $0) }) {
                rank = 1
                detail = History.bare(url)
            } else {
                rank = 2
                let word = words.first { has(text, $0) && !has(title, $0) } ?? words[0]
                detail = Self.snippet(of: text, around: word) ?? History.bare(url)
            }
            if let space, space.id != activeSpaceID { detail = space.name + " · " + detail }
            scored.append((rank, .found(spaceID: space?.id ?? activeSpaceID, tabID: tab.id, title: title, detail: detail)))
        }
        // Stable: within a rank, the sidebar's order.
        return scored.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .prefix(6).map(\.element.result)
    }

    /// A line of the text around the word: "…what was said near it…".
    static func snippet(of text: String, around word: String) -> String? {
        guard let hit = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(hit.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(hit.upperBound, offsetBy: 90, limitedBy: text.endIndex) ?? text.endIndex
        var line = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
        if start != text.startIndex { line = "…" + line }
        if end != text.endIndex { line += "…" }
        return line
    }
}
