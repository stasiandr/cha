import AppKit
import FoundationModels
import SwiftUI

// Arc Max, on this Mac's own model (Apple's on-device language model: no
// account, nothing leaves the Mac): ask the page a question or have it
// summed up, in a panel over the page; and Tidy Titles, which gives today's
// tabs of the space short names. Off where the model isn't available (the
// panel says why).
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

    /// The page's text, cut to what the model can read with room to answer.
    static let pageLimit = 6000

    static func ask(_ question: String, page: String, title: String) async -> String {
        guard #available(macOS 26, *), available else { return unavailableReason }
        let session = LanguageModelSession(instructions: """
            You answer questions about one web page, using only its text below. \
            Answer in the language of the question, briefly and plainly. \
            If the page does not say, say so.
            """)
        let prompt = "Page title: \(title)\n\nPage text:\n\(page.prefix(pageLimit))\n\nQuestion: \(question)"
        do {
            return try await session.respond(to: prompt).content
        } catch {
            return "The model could not answer: \(error.localizedDescription)"
        }
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
    /// The page's visible text, through the renderer.
    func pageText(_ tab: ChaTab, _ done: @escaping (String) -> Void) {
        let token = UUID().uuidString
        pageTextRequests[token] = done
        tab.executeJavaScript(
            "console.log('__cha_app__ text \(token) ' + JSON.stringify((document.body && document.body.innerText || '').slice(0, \(PageAI.pageLimit))))")
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

    func openAsk(summarize: Bool = false) {
        guard activeTab != nil, let window else {
            NSSound.beep()
            return
        }
        let panel = askPanel ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.becomesKeyOnlyIfNeeded = false
            let host = NSHostingView(rootView: AskPanel(controller: self))
            panel.contentView = host
            return panel
        }()
        askPanel = panel
        let page = contentScreenRect
        panel.setFrame(NSRect(x: page.maxX - 392, y: page.maxY - 332, width: 380, height: 320), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        if Diagnostics.quiet { panel.orderFront(nil) } else { panel.makeKeyAndOrderFront(nil) }
        askAnswer = PageAI.available ? "" : PageAI.unavailableReason
        if summarize { ask("Summarize this page in a few short bullet points.") }
    }

    func closeAsk() {
        guard let panel = askPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func ask(_ question: String, done: (() -> Void)? = nil) {
        guard let tab = activeTab, !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        askBusy = true
        askAnswer = ""
        let title = tab.title
        pageText(tab) { [weak self] text in
            Task { @MainActor in
                let answer = await PageAI.ask(question, page: text, title: title)
                self?.askAnswer = answer
                self?.askBusy = false
                done?()
            }
        }
    }

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

struct AskPanel: View {
    @ObservedObject var controller: BrowserController
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                TextField("Ask this page…", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { controller.ask(question) }
                Button { controller.closeAsk() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                Group {
                    if controller.askBusy {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading the page…") }
                    } else if controller.askAnswer.isEmpty {
                        Text("Ask anything about this page. Answers come from this Mac's own model; nothing leaves it.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(controller.askAnswer).textSelection(.enabled)
                    }
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Summarize") { controller.ask("Summarize this page in a few short bullet points.") }
                Spacer()
                Button("Ask") { controller.ask(question) }.keyboardShortcut(.defaultAction)
                    .disabled(question.isEmpty || controller.askBusy || !PageAI.available)
            }
            .controlSize(.small)
            .disabled(!PageAI.available)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .onAppear { focused = true }
        .onExitCommand { controller.closeAsk() }
    }
}
