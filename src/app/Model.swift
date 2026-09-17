import AppKit

// Value types so SwiftUI sees every change through the single @Published
// arrays on BrowserController; the live ChaTab objects live next to them.

struct TabData: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var title: String = ""
    var isPinned: Bool = false

    var displayTitle: String {
        if !title.isEmpty { return title }
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

struct SpaceData: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var symbol: String  // SF Symbol shown in the space switcher
    var tint: TintColor
    var tabs: [TabData] = []
    var activeTabID: UUID?

    var pinnedTabs: [TabData] { tabs.filter(\.isPinned) }
    var unpinnedTabs: [TabData] { tabs.filter { !$0.isPinned } }
}

enum TintColor: String, Codable, CaseIterable {
    case blue, purple, pink, orange, green, graphite

    var color: NSColor {
        switch self {
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .orange: return .systemOrange
        case .green: return .systemGreen
        case .graphite: return .systemGray
        }
    }
}

struct BrowserState: Codable {
    var spaces: [SpaceData]
    var activeSpaceID: UUID?
    var sidebarWidth: Double?

    static var initial: BrowserState {
        let space = SpaceData(
            name: "Personal", symbol: "person", tint: .blue,
            tabs: [TabData(url: "https://example.com")])
        return BrowserState(spaces: [space], activeSpaceID: space.id)
    }
}

enum Persistence {
    static var fileURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("cha", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.json")
    }

    static func load() -> BrowserState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(BrowserState.self, from: data),
              !state.spaces.isEmpty
        else { return .initial }
        return state
    }

    static func save(_ state: BrowserState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// Turns whatever is typed in the address field into a URL or a search.
func normalizedURL(from input: String) -> String {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return "about:blank" }
    if text.contains("://") { return text }
    let looksLikeHost =
        !text.contains(" ") && text.contains(".") && !text.hasSuffix(".")
    if looksLikeHost { return "https://" + text }
    let query =
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    return "https://www.google.com/search?q=" + query
}
