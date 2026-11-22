import AppKit
import SwiftUI

// Arc's command bar: one field for addresses, searches and open tabs. It is a
// panel above the tab's CEF window, since that window covers the content area.
enum CommandMode {
    case newTab  // ⌘T — the result opens in a new tab.
    case current  // ⌘L — the result replaces what the active tab shows.
}

enum CommandResult: Identifiable, Equatable {
    case tab(spaceID: UUID, tabID: UUID, title: String, url: String)
    case open(url: String)
    case search(query: String)
    case addCode(uri: String)  // An otpauth:// link typed or pasted in.
    case space(id: UUID, name: String)
    case archived(id: UUID, title: String, url: String)
    case history(title: String, url: String)  // A page visited before.

    var id: String {
        switch self {
        case .tab(_, let tabID, _, _): return "tab-\(tabID)"
        case .open(let url): return "open-\(url)"
        case .search(let query): return "search-\(query)"
        case .addCode: return "add-code"
        case .space(let id, _): return "space-\(id)"
        case .archived(let id, _, _): return "archived-\(id)"
        case .history(_, let url): return "history-\(url)"
        }
    }

    var title: String {
        switch self {
        case .tab(_, _, let title, _): return title
        case .open(let url): return url
        case .search(let query): return query
        case .addCode(let uri): return OTPAuth.parse(uri)?.label ?? "Verification code"
        case .space(_, let name): return name
        case .archived(_, let title, _): return title
        case .history(let title, let url): return title.isEmpty ? History.bare(url) : title
        }
    }

    var subtitle: String {
        switch self {
        case .tab(_, _, _, let url): return url
        case .open: return "Open address"
        case .search: return "Search with Google"
        case .addCode: return "Save this verification code"
        case .space: return "Switch to space"
        case .archived(_, _, let url): return "Archived · " + url
        case .history(_, let url): return History.bare(url)
        }
    }

    var symbol: String {
        switch self {
        case .tab: return "square.on.square"
        case .open: return "arrow.up.right"
        case .search: return "magnifyingglass"
        case .addCode: return "lock.rotation"
        case .space: return "square.stack"
        case .archived: return "archivebox"
        case .history: return "clock"
        }
    }
}

final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct CommandBarView: View {
    @ObservedObject var controller: BrowserController
    @FocusState private var focused: Bool

    // ⌘L opens on the page's address with all of it selected: typing
    // replaces it. (Every opening, not only the first, which onAppear is.)
    private func focusAndSelectAll() {
        focused = true
        DispatchQueue.main.async {
            guard let panel = controller.commandPanel else { return }
            if let editor = panel.firstResponder as? NSTextView {
                editor.selectAll(nil)
            } else {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                TextField(
                    "Search or enter address", text: $controller.commandQuery
                )
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($focused)
                .onSubmit { controller.runSelectedCommand() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if !controller.commandResults.isEmpty {
                Divider()
                // The panel sizes itself to this view, so the list needs a
                // height of its own: a scroll view would collapse to nothing.
                VStack(spacing: 2) {
                    ForEach(
                        Array(controller.commandResults.enumerated()),
                        id: \.element.id
                    ) { index, result in
                        row(result, selected: index == controller.commandSelection)
                            .onTapGesture { controller.runCommand(result) }
                    }
                }
                .padding(6)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
        .padding(12)
        // The card hangs from the top of a fixed-size panel; the rest of the
        // panel is empty and lets clicks through.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { focusAndSelectAll() }
        .onChange(of: controller.commandFocusToken) { _, _ in focusAndSelectAll() }
    }

    private func row(_ result: CommandResult, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.symbol)
                .font(.system(size: 12))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
    }
}
