import Foundation

// Pages the user has been to, for the command bar: typing "app" should find
// App Store Connect even when no tab has it open any more. Kept on disk
// (history.json in the profile), at most `limit` pages; the secret space's
// pages never get here.
final class History {
    struct Entry: Codable, Equatable {
        var url: String
        var title: String
        var visits: Int
        var last: Date
    }

    static let limit = 5000

    private(set) var entries: [String: Entry] = [:]
    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    init(file: URL = Persistence.directory.appendingPathComponent("history.json")) {
        fileURL = file
        if let data = try? Data(contentsOf: file),
            let list = try? JSONDecoder().decode([Entry].self, from: data)
        {
            for entry in list { entries[entry.url] = entry }
        }
    }

    /// Web pages only: no about:, data:, chrome: or file: pages.
    static func keeps(_ url: String) -> Bool {
        let lowered = url.lowercased()
        return lowered.hasPrefix("https://") || lowered.hasPrefix("http://")
    }

    /// A page was opened (or a page went to another address).
    func visit(_ url: String, title: String) {
        guard History.keeps(url) else { return }
        var entry = entries[url] ?? Entry(url: url, title: "", visits: 0, last: Date())
        entry.visits += 1
        entry.last = Date()
        if !title.isEmpty { entry.title = title }
        entries[url] = entry
        trim()
        scheduleSave()
    }

    /// The page's title came after its address.
    func retitle(_ url: String, title: String) {
        guard !title.isEmpty, var entry = entries[url], entry.title != title else { return }
        entry.title = title
        entries[url] = entry
        scheduleSave()
    }

    func clear() {
        entries = [:]
        scheduleSave()
    }

    /// The address without its scheme and "www.": what the user types.
    static func bare(_ url: String) -> String {
        var s = url.lowercased()
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        return s
    }

    /// Pages matching the query, best first. A page whose address starts
    /// with what was typed beats one that only has it somewhere; among those,
    /// often and recently visited pages come first.
    func search(_ query: String, now: Date = Date()) -> [(entry: Entry, prefix: Bool)] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard let first = words.first else { return [] }
        var hits: [(entry: Entry, prefix: Bool, score: Double)] = []
        for entry in entries.values {
            let bare = History.bare(entry.url)
            let title = entry.title.lowercased()
            guard words.allSatisfy({ bare.contains($0) || title.contains($0) }) else { continue }
            let prefix = words.count == 1 && (bare.hasPrefix(first) || hostWords(bare).contains { $0.hasPrefix(first) })
            let days = max(now.timeIntervalSince(entry.last) / 86400, 0)
            var score = Double(entry.visits).squareRoot() * 10 / (1 + days / 7)
            if prefix { score += 1000 }
            // Of a site's pages, its front page is what "you" means.
            score -= Double(bare.count) / 20
            hits.append((entry, prefix, score))
        }
        return hits.sorted { $0.score > $1.score }.map { ($0.entry, $0.prefix) }
    }

    // "appstoreconnect.apple.com/apps" → ["appstoreconnect", "apple", "com"]:
    // "apple" finds it too.
    private func hostWords(_ bare: String) -> [Substring] {
        let host = bare.split(separator: "/", maxSplits: 1).first ?? ""
        return host.split(separator: ".")
    }

    private func trim() {
        guard entries.count > History.limit else { return }
        let old = entries.values.sorted { $0.last < $1.last }.prefix(entries.count - History.limit)
        for entry in old { entries[entry.url] = nil }
    }

    // Written a few seconds after the last change, off the main thread, so
    // a burst of redirects is one write and pages never wait for the disk.
    private static let disk = DispatchQueue(label: "cha.history", qos: .utility)

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }

    /// Writes now; `wait` blocks until it is on disk (at quit, in the checks).
    func save(wait: Bool = false) {
        saveWork?.cancel()
        saveWork = nil
        let list = Array(entries.values)
        let file = fileURL
        let write = {
            guard let data = try? JSONEncoder().encode(list.sorted { $0.last > $1.last }) else { return }
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        if wait { History.disk.sync(execute: write) } else { History.disk.async(execute: write) }
    }
}
