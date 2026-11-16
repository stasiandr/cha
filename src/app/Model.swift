import AppKit

// Value types so SwiftUI sees every change through the single @Published
// arrays on BrowserController; the live ChaTab objects live next to them.

struct TabData: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var title: String = ""
    // Pinned tabs stay in their space until removed by hand; unpinned ones are
    // "today" tabs that go to the archive when left alone long enough.
    var isPinned: Bool = false
    // Where a pinned tab was pinned, so it can go back there.
    var pinnedURL: String?
    var folderID: UUID?
    var lastActive: Date?
    // A name given by hand; the page's own title no longer replaces it.
    var customTitle: String?

    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if !title.isEmpty { return title }
        return displayHost(url) ?? url
    }

    var host: String? { URL(string: url)?.host }

    // A pinned tab that wandered off the address it was pinned at.
    var hasLeftPinnedURL: Bool {
        guard isPinned, let pinnedURL else { return false }
        return pinnedURL != url
    }

    init(url: String, title: String = "", isPinned: Bool = false) {
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.pinnedURL = isPinned ? url : nil
        self.lastActive = Date()
    }
}

func displayHost(_ url: String) -> String? {
    guard let host = URL(string: url)?.host, !host.isEmpty else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

struct FolderData: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var isOpen = true
}

struct SpaceData: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var symbol: String  // SF Symbol name, or an emoji
    var theme: SpaceTheme
    var tabs: [TabData] = []
    var folders: [FolderData] = []
    var activeTabID: UUID?

    var pinnedTabs: [TabData] { tabs.filter(\.isPinned) }
    var unpinnedTabs: [TabData] { tabs.filter { !$0.isPinned } }
    // Pinned tabs that sit outside any folder.
    var loosePinnedTabs: [TabData] { tabs.filter { $0.isPinned && $0.folderID == nil } }
    func tabs(in folder: UUID) -> [TabData] {
        tabs.filter { $0.isPinned && $0.folderID == folder }
    }

    // An icon is an emoji when it holds no ASCII letters (SF Symbols always do).
    var symbolIsEmoji: Bool { isEmojiIcon(symbol) }

    init(
        id: UUID = UUID(), name: String, symbol: String, theme: SpaceTheme,
        tabs: [TabData] = []
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.theme = theme
        self.tabs = tabs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, theme, tint, tabs, folders, activeTabID
    }

    // Older state files kept the colour as one of six names under "tint".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decode(String.self, forKey: .symbol)
        if let theme = try c.decodeIfPresent(SpaceTheme.self, forKey: .theme) {
            self.theme = theme
        } else {
            let legacy = try c.decodeIfPresent(String.self, forKey: .tint) ?? "blue"
            theme = SpaceTheme.named(legacy) ?? .presets[0]
        }
        tabs = try c.decodeIfPresent([TabData].self, forKey: .tabs) ?? []
        folders = try c.decodeIfPresent([FolderData].self, forKey: .folders) ?? []
        activeTabID = try c.decodeIfPresent(UUID.self, forKey: .activeTabID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(theme, forKey: .theme)
        try c.encode(tabs, forKey: .tabs)
        try c.encode(folders, forKey: .folders)
        try c.encodeIfPresent(activeTabID, forKey: .activeTabID)
    }
}

func isEmojiIcon(_ icon: String) -> Bool {
    !icon.isEmpty && !icon.unicodeScalars.contains { $0.isASCII }
}

// A space's colour. Arc lets you pick any hue; the window wears a gradient of
// it, lighter or deeper with the system appearance.
struct SpaceTheme: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .systemBlue
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    }

    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    // The fixed set offered when making a space, close to Arc's swatches.
    static let presets: [SpaceTheme] = [
        SpaceTheme(red: 0.33, green: 0.55, blue: 0.96),  // blue
        SpaceTheme(red: 0.58, green: 0.40, blue: 0.93),  // purple
        SpaceTheme(red: 0.93, green: 0.38, blue: 0.62),  // pink
        SpaceTheme(red: 0.95, green: 0.42, blue: 0.33),  // red
        SpaceTheme(red: 0.96, green: 0.62, blue: 0.26),  // orange
        SpaceTheme(red: 0.92, green: 0.78, blue: 0.27),  // yellow
        SpaceTheme(red: 0.30, green: 0.75, blue: 0.47),  // green
        SpaceTheme(red: 0.22, green: 0.70, blue: 0.75),  // teal
        SpaceTheme(red: 0.52, green: 0.55, blue: 0.60),  // graphite
    ]

    static func named(_ name: String) -> SpaceTheme? {
        switch name {
        case "blue": return presets[0]
        case "purple": return presets[1]
        case "pink": return presets[2]
        case "orange": return presets[4]
        case "green": return presets[6]
        case "graphite": return presets[8]
        default: return nil
        }
    }

    // Straight blend, for the colours while a swipe is half way.
    func mixed(with other: SpaceTheme, _ t: Double) -> SpaceTheme {
        let t = min(max(t, 0), 1)
        return SpaceTheme(
            red: red + (other.red - red) * t, green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t)
    }
}

// A tab that was closed or aged out, kept so it can come back.
struct ArchivedTab: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var title: String
    var spaceID: UUID?
    var archivedAt = Date()
}

struct BrowserState: Codable {
    var spaces: [SpaceData]
    var activeSpaceID: UUID?
    var sidebarWidth: Double?
    var sidebarFraction: Double?  // Share of the window's width.
    var favorites: [TabData]?
    var archive: [ArchivedTab]?

    static var initial: BrowserState {
        var space = SpaceData(
            name: "Personal", symbol: "person", theme: .presets[0],
            tabs: [TabData(url: "https://example.com")])
        space.activeTabID = space.tabs.first?.id
        return BrowserState(spaces: [space], activeSpaceID: space.id)
    }
}

enum Persistence {
    // CHA_PROFILE points the whole app (state, codes, Chromium's profile) at
    // another directory, so test runs never touch the real one.
    static let directory: URL = {
        let directory: URL
        if let custom = ProcessInfo.processInfo.environment["CHA_PROFILE"] {
            directory = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = support.appendingPathComponent("cha", isDirectory: true)
        }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static var fileURL: URL { directory.appendingPathComponent("state.json") }

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

// Favicons by host, on disk, so a restored sidebar shows them before any page
// has loaded again.
enum FaviconStore {
    private static let directory: URL = {
        let directory = Persistence.directory.appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static func file(_ host: String) -> URL {
        let safe = host.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe + ".png")
    }

    static func load(host: String) -> NSImage? {
        NSImage(contentsOf: file(host))
    }

    static func save(_ image: NSImage, host: String) {
        guard let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        DispatchQueue.global(qos: .utility).async {
            try? png.write(to: file(host), options: .atomic)
        }
    }
}

// Turns whatever is typed in the address field into a URL or a search.
func normalizedURL(from input: String) -> String {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return "about:blank" }
    // Any scheme goes through as is: https://, but also chrome:, data:, about:.
    if text.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil {
        return text
    }
    let looksLikeHost =
        !text.contains(" ") && text.contains(".") && !text.hasSuffix(".")
    if looksLikeHost { return "https://" + text }
    let query =
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    return "https://www.google.com/search?q=" + query
}
