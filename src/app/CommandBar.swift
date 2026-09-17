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

    var id: String {
        switch self {
        case .tab(_, let tabID, _, _): return "tab-\(tabID)"
        case .open(let url): return "open-\(url)"
        case .search(let query): return "search-\(query)"
        }
    }

    var title: String {
        switch self {
        case .tab(_, _, let title, _): return title
        case .open(let url): return url
        case .search(let query): return query
        }
    }

    var subtitle: String {
        switch self {
        case .tab(_, _, _, let url): return url
        case .open: return "Open address"
        case .search: return "Search with Google"
        }
    }

    var symbol: String {
        switch self {
        case .tab: return "square.on.square"
        case .open: return "arrow.up.right"
        case .search: return "magnifyingglass"
        }
    }
}

final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct CommandBarView: View {
    @ObservedObject var controller: BrowserController
    @FocusState private var focused: Bool

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
        .onAppear { focused = true }
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
