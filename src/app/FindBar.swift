import AppKit
import SwiftUI

// Find in page, Arc-style: a small floating bar at the top right of the page
// (field, "2/5", previous / next, close) instead of Chrome's find bar, which
// in a frameless tab window moves the window around. The search itself is
// CEF's: Find highlights the matches, OnFindResult reports the count.
//
// ⌘F opens it (or selects what is typed), Return / ⌘G go to the next match,
// ⇧Return / ⇧⌘G to the previous one, Esc closes it and clears the
// highlights. Switching tabs closes it.
final class FindModel: ObservableObject {
    @Published var query = ""
    @Published var count = 0
    @Published var active = 0
    @Published var focusToken = 0
}

extension BrowserController {
    static let findBarSize = NSSize(width: 340, height: 44)

    var findFrame: NSRect {
        let content = contentScreenRect
        let size = Self.findBarSize
        return NSRect(
            x: content.maxX - size.width - 12, y: content.maxY - size.height - 12,
            width: size.width, height: size.height)
    }

    var isFindOpen: Bool { findPanel?.isVisible == true }

    func openFindBar() {
        guard activeTab != nil, let window else { return }
        let panel = findPanel ?? makeFindPanel()
        findPanel = panel
        panel.setFrame(findFrame, display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        if Diagnostics.quiet { panel.orderFront(nil) } else { panel.makeKeyAndOrderFront(nil) }
        find.focusToken += 1
        if !find.query.isEmpty { search(find.query, findNext: false) }
        // What is selected in the page becomes the search, as in Safari and
        // Arc; with nothing selected the last search stays.
        activeTab?.fetchSelection { [weak self] text in
            guard let self, self.isFindOpen else { return }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let query = String(line.trimmingCharacters(in: .whitespaces).prefix(200))
            guard !query.isEmpty, query != self.find.query else { return }
            self.find.query = query
            self.search(query, findNext: false)
            NSLog("FIND from selection: %@", query)
        }
    }

    func closeFindBar() {
        guard let panel = findPanel, panel.isVisible else { return }
        if panel.parent != nil { window.removeChildWindow(panel) }
        panel.orderOut(nil)
        activeTab?.stopFinding(true)
        find.count = 0
        find.active = 0
        if !Diagnostics.quiet { activeTab?.focus() }
    }

    func search(_ text: String, forward: Bool = true, findNext: Bool) {
        guard let tab = activeTab else { return }
        if text.isEmpty {
            tab.stopFinding(true)
            find.count = 0
            find.active = 0
            return
        }
        tab.find(text, forward: forward, findNext: findNext)
    }

    // ⌘G / ⇧⌘G: with the bar closed they open it on the last search.
    func findNext(forward: Bool) {
        if !isFindOpen { openFindBar() }
        search(find.query, forward: forward, findNext: true)
    }

    func repositionFindBar() {
        guard let panel = findPanel, panel.isVisible else { return }
        panel.setFrame(findFrame, display: true)
    }

    func tab(_ tab: ChaTab, didFindCount count: Int32, active: Int32, final: Bool) {
        guard tab === activeTab else { return }
        find.count = Int(count)
        find.active = Int(active)
        if final { NSLog("FIND result %d/%d", active, count) }
    }

    private func makeFindPanel() -> CommandPanel {
        let panel = CommandPanel(
            contentRect: findFrame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: FindBarView(controller: self, model: find))
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
}

struct FindBarView: View {
    let controller: BrowserController
    @ObservedObject var model: FindModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Find on page", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($focused)
                .onChange(of: model.query) { _, text in
                    controller.search(text, findNext: false)
                }
                .onSubmit {
                    let back = NSEvent.modifierFlags.contains(.shift)
                    controller.search(model.query, forward: !back, findNext: true)
                    focused = true
                }
                .onExitCommand { controller.closeFindBar() }
            Text(counter)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            button("chevron.up", help: "Previous (⇧⌘G)") {
                controller.search(model.query, forward: false, findNext: true)
            }
            button("chevron.down", help: "Next (⌘G)") {
                controller.search(model.query, forward: true, findNext: true)
            }
            button("xmark", help: "Close (Esc)") { controller.closeFindBar() }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onChange(of: model.focusToken) { _, _ in focused = true }
        .onAppear { focused = true }
    }

    private var counter: String {
        if model.query.isEmpty { return "" }
        if model.count == 0 { return "0/0" }
        return "\(model.active)/\(model.count)"
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(model.query.isEmpty && symbol != "xmark")
        .help(help)
    }
}
