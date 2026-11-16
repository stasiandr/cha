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
                    .padding(.bottom, 10)
                AddressPill(controller: controller)
                    .padding(.bottom, 10)
                FavoritesGrid(controller: controller)
                main
                BottomBar(controller: controller)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 10)
            .padding(.top, controller.isFullscreen ? 8 : 2)
            .padding(.bottom, 8)
            resizeHandle
        }
        // The sidebar runs up under the title bar: its first row shares the
        // line with the traffic lights, as in Arc.
        .ignoresSafeArea()
        .onHover { hoveringChrome = $0 }
    }

    @ViewBuilder
    private var main: some View {
        switch controller.sidebarPage {
        case .tabs:
            SpacePager(controller: controller)
        case .editSpace(let id, let isNew):
            SpaceEditorView(controller: controller, spaceID: id, isNew: isNew)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .archive:
            ArchiveView(controller: controller)
        }
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
        HStack(spacing: 2) {
            if !controller.isFullscreen {
                Color.clear.frame(width: 64, height: 1)
            }
            ChromeButton(symbol: "sidebar.left", help: "Hide sidebar (⌘S)") {
                controller.toggleSidebar()
            }
            Spacer(minLength: 0)
            ChromeButton(symbol: "chevron.left", enabled: controller.canGoBack, help: "Back") {
                controller.goBack()
            }
            ChromeButton(
                symbol: "chevron.right", enabled: controller.canGoForward, help: "Forward"
            ) {
                controller.goForward()
            }
            ChromeButton(symbol: "arrow.clockwise", help: "Reload") { controller.reload() }
        }
        .frame(height: 28)
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
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
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
                .font(.system(size: 13))
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
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.pill))
        .contentShape(Rectangle())
        .onTapGesture { controller.openCommandBar(mode: .current) }
        .onHover { hovered = $0 }
    }

    private func label(_ url: String) -> String {
        if url.isEmpty || url == "about:blank" { return "Search or enter address" }
        if url.hasPrefix("data:") { return "data:" }
        if url.hasPrefix("chrome://") || url.hasPrefix("about:") { return url }
        return displayHost(url) ?? url
    }
}

// MARK: - Favourites

// Favourites are shared by every space and sit above them as tiles. The grid
// takes drops, so dragging a tab up makes it a favourite.
struct FavoritesGrid: View {
    @ObservedObject var controller: BrowserController
    @Environment(\.colorScheme) private var scheme
    @State private var targeted = false

    var body: some View {
        let favorites = controller.favorites
        if !favorites.isEmpty {
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 7), count: min(4, favorites.count))
            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(favorites) { tab in tile(tab) }
            }
            .padding(.bottom, 10)
            .dropDestination(for: String.self) { items, _ in
                guard let id = DragPayload.tabID(items) else { return false }
                controller.addToFavorites(id)
                return true
            } isTargeted: { targeted = $0 }
        }
    }

    private func tile(_ tab: TabData) -> some View {
        let style = SidebarStyle(dark: scheme == .dark)
        let isActive = controller.activeTabID == tab.id
        let loaded = controller.isLoaded(tab.id)
        return TabIcon(controller: controller, tab: tab, size: 18)
            .opacity(loaded || isActive ? 1 : 0.75)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isActive ? style.activeTile : style.tile)
                    .shadow(color: isActive ? style.shadow : .clear, radius: 3, y: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { controller.activateTab(tab.id) }
            .help(tab.displayTitle)
            .onDrag { DragPayload.tab(tab.id) }
            .dropDestination(for: String.self) { items, _ in
                guard let id = DragPayload.tabID(items) else { return false }
                controller.moveTab(id, before: tab.id)
                return true
            }
            .contextMenu {
                Button("Remove from Favorites") { controller.removeFromFavorites(tab.id) }
                Button("Copy Link") { controller.copyLink(tab.id) }
                if tab.hasLeftPinnedURL {
                    Button("Back to Pinned Address") { controller.resetToPinnedURL(tab.id) }
                }
                Divider()
                Button("Unload") { controller.unload(tab.id) }.disabled(!loaded)
            }
    }
}
