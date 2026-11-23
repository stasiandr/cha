import SwiftUI

// Arc's sidebar, top to bottom: the window controls and navigation, the
// address pill, favourites shared by all spaces, then the space's own page
// (which slides sideways to the next space), and the bottom bar with the
// archive, one icon per space and "+".
struct SidebarView: View {
    @ObservedObject var controller: BrowserController
    @State private var hoveringChrome = false
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                navigationRow
                    .padding(.bottom, 1)
                AddressPill(controller: controller)
                    .padding(.bottom, 6)
                ExtensionsBar(controller: controller)
                    .padding(.bottom, 4)
                FavoritesGrid(controller: controller)
                main
                MiniPlayer(controller: controller)
                    .padding(.top, 6)
                MeetingCard(calendar: .shared) { controller.joinMeeting($0) }
                    .padding(.top, 6)
                BottomBar(controller: controller)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 8)
            .padding(.top, controller.isFullscreen ? 6 : 0)
            .padding(.bottom, 8)
            resizeHandle
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The sidebar runs up under the title bar: its first row shares the
        // line with the traffic lights, as in Arc.
        .ignoresSafeArea()
        .onHover { hoveringChrome = $0 }
    }

    @ViewBuilder
    private var main: some View {
        ZStack {
            switch controller.sidebarPage {
            case .tabs:
                SpacePager(controller: controller)
                    // To and from downloads the spaces move aside to the right,
                    // as when going to the space on the left.
                    .transition(
                        controller.slidingToDownloads ? .move(edge: .trailing) : .opacity)
            case .editSpace(let id, let isNew):
                SpaceEditorView(controller: controller, spaceID: id, isNew: isNew)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .downloads:
                // Downloads come in from the left, like a space before the
                // first one.
                DownloadsView(controller: controller)
                    .transition(.move(edge: .leading))
            }
        }
        .clipped()
    }

    // Dragging the right edge changes the sidebar width, as in Arc.
    private var resizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = controller.sidebarWidth
                        }
                        controller.setSidebarWidth(
                            (dragStartWidth ?? controller.sidebarWidth)
                                + value.translation.width)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }

    // Arc keeps the chrome quiet: the arrows fade in when the pointer is here.
    // One line with the traffic lights: they sit on the left, the sidebar
    // toggle right after them, the arrows and reload on the right.
    private var navigationRow: some View {
        HStack(spacing: 5) {
            if !controller.isFullscreen {
                // The toggle's centre lands 93 pt in, as in Arc (8 padding
                // + 66 + 5 spacing + half the button).
                Color.clear.frame(width: 66, height: 1)
            }
            ChromeButton(symbol: "sidebar.left", help: "Hide sidebar (⌘S)") {
                controller.toggleSidebar()
            }
            Spacer(minLength: 0)
            // A narrow sidebar drops the arrows rather than pushing the row
            // past its edges: the row needs 198 pt with them, 132 without.
            if controller.sidebarWidth >= 214 || controller.isFullscreen {
                ChromeButton(symbol: "chevron.left", enabled: controller.canGoBack, help: "Back") {
                    controller.goBack()
                }
                ChromeButton(
                    symbol: "chevron.right", enabled: controller.canGoForward, help: "Forward"
                ) {
                    controller.goForward()
                }
            }
            ChromeButton(symbol: "arrow.clockwise", help: "Reload") { controller.reload() }
        }
        // The traffic lights' line: their centres are 22 pt down.
        .frame(height: 44)
        .opacity(hoveringChrome ? 1 : 0.6)
        .animation(.easeOut(duration: 0.15), value: hoveringChrome)
    }
}

// MARK: - Shared styling

// Arc lifts the open tab onto a card: near-white in light mode, a soft glass
// in dark mode, so the title stays readable on either.
struct SidebarStyle {
    let dark: Bool
    func card(active: Bool, hovered: Bool) -> Color {
        if active { return dark ? .white.opacity(0.17) : .white.opacity(0.88) }
        if hovered { return dark ? .white.opacity(0.08) : .white.opacity(0.38) }
        return .clear
    }
    var tile: Color { dark ? .white.opacity(0.09) : .white.opacity(0.34) }
    var activeTile: Color { dark ? .white.opacity(0.22) : .white.opacity(0.9) }
    var pill: Color { dark ? .white.opacity(0.11) : .white.opacity(0.45) }
    var shadow: Color { .black.opacity(dark ? 0.25 : 0.10) }
}

struct ChromeButton: View {
    let symbol: String
    var enabled = true
    var help = ""
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.primary.opacity(hovered && enabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .onHover { hovered = $0 }
    }
}

struct TabIcon: View {
    @ObservedObject var controller: BrowserController
    let tab: TabData
    let size: CGFloat

    var body: some View {
        Group {
            if controller.loadingTabs.contains(tab.id) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(size / 22)
            } else if let favicon = controller.favicons[tab.id] {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct SpaceIcon: View {
    let space: SpaceData
    var size: CGFloat = 12

    var body: some View {
        if space.symbolIsEmoji {
            Text(space.symbol).font(.system(size: size + 1))
        } else {
            Image(systemName: space.symbol).font(.system(size: size, weight: .medium))
        }
    }
}

// Drag payloads: a tab's UUID, or "space:<UUID>" for a space icon.
enum DragPayload {
    static func tab(_ id: UUID) -> NSItemProvider {
        NSItemProvider(object: id.uuidString as NSString)
    }
    static func space(_ id: UUID) -> NSItemProvider {
        NSItemProvider(object: ("space:" + id.uuidString) as NSString)
    }
    static func tabID(_ items: [String]) -> UUID? {
        items.first.flatMap(UUID.init(uuidString:))
    }
    static func spaceID(_ items: [String]) -> UUID? {
        guard let item = items.first, item.hasPrefix("space:") else { return nil }
        return UUID(uuidString: String(item.dropFirst(6)))
    }
}

// MARK: - Address pill

// The host only, the way Arc shows it; clicking opens the command bar on the
// full address, and hovering offers to copy the link.
struct AddressPill: View {
    @ObservedObject var controller: BrowserController
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        let style = SidebarStyle(dark: scheme == .dark)
        let url = controller.addressText
        let insecure = url.hasPrefix("http://")
        HStack(spacing: 6) {
            if insecure {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .help("Not secure")
            }
            Text(label(url))
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(url.isEmpty || url == "about:blank" ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if hovered, !url.isEmpty, url != "about:blank" {
                Button {
                    controller.copyLink()
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy link (⇧⌘C)")
            }
        }
        .padding(.horizontal, 12.5)
        .frame(height: 36)
        .uiFrame("pill")
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(style.pill))
        .contentShape(Rectangle())
        .onTapGesture { controller.openCommandBar(mode: .current) }
        .onHover { hovered = $0 }
    }

    private func label(_ url: String) -> String {
        if url.isEmpty || url == "about:blank" { return "Search or enter address" }
        if NoteStore.id(in: url) != nil { return "Note" }
        if EaselStore.id(in: url) != nil { return "Easel" }
        if url.hasPrefix("data:") { return "data:" }
        if url.hasPrefix("chrome://") || url.hasPrefix("about:") { return url }
        return displayHost(url) ?? url
    }
}

// MARK: - Favourites

// Favourites are shared by every space and sit above them as a list of
// named rows, like the tabs below. The list takes drops, so dragging a tab up
// makes it a favourite; a line sets it off from the space.
struct FavoritesGrid: View {
    @ObservedObject var controller: BrowserController

    var body: some View {
        let favorites = controller.favorites
        if !favorites.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(favorites) { tab in
                    // The open favourite shows as open in whichever space.
                    TabRow(
                        controller: controller, space: controller.activeSpace, tab: tab,
                        isFavorite: true)
                }
                Rectangle()
                    .fill(.primary.opacity(0.12))
                    .frame(height: 1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let id = DragPayload.tabID(items) else { return false }
                controller.addToFavorites(id)
                return true
            }
        }
    }
}
