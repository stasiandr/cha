import AppKit
import FoundationModels

// Arc Max's Tidy Titles, on this Mac's own model (Apple's on-device language
// model: no account, nothing leaves the Mac): today's tabs of the space get
// short names. Off where the model isn't available (a toast says why).
// Asking a page or summing it up is left to Claude.
enum PageAI {
    static var available: Bool {
        if #available(macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        return false
    }

    static var unavailableReason: String {
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return ""
            case .unavailable(let reason): return "Apple Intelligence is not available here (\(reason))."
            }
        }
        return "Needs macOS 26 or later with Apple Intelligence."
    }

    /// A short name for a tab: 1–4 words, no site name, no quotes.
    static func shortTitle(_ title: String, host: String) async -> String? {
        guard #available(macOS 26, *), available, !title.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: """
            You shorten browser tab titles to 1-4 words that say what the page is. \
            Drop the site's name, slogans and punctuation. Keep the title's language. \
            Reply with the short title only.
            """)
        let reply: String
        do {
            reply = try await session.respond(to: "Title: \(title)\nSite: \(host)").content
        } catch {
            NSLog("tidy title failed: %@", String(describing: error))
            return nil
        }
        let short = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”«»."))
            .components(separatedBy: .newlines).first ?? ""
        // A long answer is cut to its first four words rather than dropped.
        let cut = short.count > 40 ? short.split(separator: " ").prefix(4).joined(separator: " ") : short
        return cut.isEmpty || cut.count > 40 ? nil : cut
    }
}

extension BrowserController {
    /// Arc Max's tidy tab titles: today's tabs of the space get short names
    /// (as if renamed by hand; an empty name gives the page's title back).
    func tidyTabTitles(done: (() -> Void)? = nil) {
        let tabs = activeSpace.unpinnedTabs.filter { $0.customTitle == nil && !$0.title.isEmpty }
        guard PageAI.available, !tabs.isEmpty else {
            if !PageAI.available { showToast(PageAI.unavailableReason, symbol: "exclamationmark.triangle") }
            done?()
            return
        }
        showToast("Tidying \(tabs.count) titles…", symbol: "sparkles")
        Task { @MainActor in
            for tab in tabs {
                if let short = await PageAI.shortTitle(tab.title, host: tab.host ?? "") {
                    update(tabID: tab.id) { $0.customTitle = short }
                }
            }
            showToast("Titles tidied", symbol: "sparkles")
            done?()
        }
    }
}
